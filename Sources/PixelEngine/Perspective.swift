import Foundation
import CoreGraphics
import simd

/// Keystone correction: a homography that makes converging verticals
/// (or horizontals) parallel again, applied in the lens stage as part of
/// its one resampling pass, in the undistorted frame.
///
/// Coordinates are centred on the sensor and normalized by half the
/// short side, so the same slider value means the same correction on a
/// preview and at full resolution. `vertical` > 0 widens the top of the
/// frame (a building shot from below, leaning back); `horizontal` > 0
/// widens the left. Each slider runs −1…1, mapped to a divisor change of
/// at most half, which is more than any real photograph needs.
///
/// The Transform panel adds to the two keystone sliders: Rotate, Aspect,
/// Scale, X and Y Offset, Flip Horizontal and Vertical, and an Upright
/// correction found from the lines in the picture (Upright.swift). All of
/// them compose into the one homography the lens stage already applies,
/// so they cost no extra pass. Each new field defaults to "no change",
/// and with every one at its default `inverseMatrix` is exactly the
/// keystone-only matrix it always was, so existing edits render as before.
public struct PerspectiveCorrection: Equatable, Sendable {
    public var vertical: Float
    public var horizontal: Float
    /// Degrees, −10…10; positive turns the picture clockwise, as the crop's
    /// straighten angle does.
    public var rotate: Float = 0
    /// −1…1; positive stretches the picture wider and shorter, negative
    /// narrower and taller, keeping its area.
    public var aspect: Float = 0
    /// 0.5…1.5, about the centre; 1 is unchanged.
    public var scale: Float = 1
    /// −1…1, a fraction of half the short side; positive moves the picture
    /// right (X) or down (Y).
    public var offsetX: Float = 0
    public var offsetY: Float = 0
    /// Mirror the picture left-to-right or top-to-bottom.
    public var flipHorizontal = false
    public var flipVertical = false
    /// Upright: the mode the user chose and the correction it found.
    public var upright: UprightCorrection?
    /// Keep the crop inside the picture whenever a transform changes.
    /// A tool setting, so it changes nothing about the render.
    public var constrainCrop = false

    public init(vertical: Float = 0, horizontal: Float = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public static let none = PerspectiveCorrection()

    /// True when the render is unchanged: no keystone, no transform, and
    /// no Upright correction in effect.
    public var isIdentity: Bool {
        vertical == 0 && horizontal == 0 && !hasTransform && uprightInverse == nil
    }

    /// True when there is nothing worth storing: identity, and no Upright
    /// mode or Constrain Crop chosen either.
    public var isNeutral: Bool { isIdentity && upright == nil && !constrainCrop }

    /// Any of the Transform panel's sliders or flips away from default.
    var hasTransform: Bool {
        rotate != 0 || aspect != 0 || scale != 1 || offsetX != 0 || offsetY != 0
            || flipHorizontal || flipVertical
    }

    static let gain: Float = 0.5

    /// The Upright correction's own output-to-source matrix, when it found one.
    var uprightInverse: simd_float3x3? {
        guard let m = upright?.matrix, m.count == 9, m.allSatisfy(\.isFinite) else { return nil }
        return simd_float3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
    }

    /// The matrix the kernel applies to (x, y, 1): output point in, source
    /// point out (after the homogeneous divide). Column-major for simd.
    ///
    /// Forward, a source point goes through Upright, then the flips, then
    /// the keystone, then Rotate, Aspect and Scale, then the offset; so the
    /// sliders act on the picture as it looks after Upright and a flip.
    /// This is the inverse of that chain, composed in reverse.
    public var inverseMatrix: simd_float3x3 {
        let h = -horizontal * Self.gain, v = -vertical * Self.gain
        // Rows: [1 0 0], [0 1 0], [h v 1]  → q.z = h·x + v·y + 1
        let keystone = simd_float3x3(columns: (SIMD3(1, 0, h), SIMD3(0, 1, v), SIMD3(0, 0, 1)))
        let upright = uprightInverse
        guard hasTransform || upright != nil else { return keystone }
        let flip = simd_float3x3(diagonal: SIMD3(flipHorizontal ? -1 : 1, flipVertical ? -1 : 1, 1))
        let radians = -rotate * .pi / 180
        let c = cos(radians), s = sin(radians)
        let unrotate = simd_float3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
        let stretch = pow(2, aspect / 2)
        let safeScale = max(scale, 0.05)
        let unscale = simd_float3x3(diagonal: SIMD3(1 / (stretch * safeScale), stretch / safeScale, 1))
        let unshift = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-offsetX, -offsetY, 1)))
        return (upright ?? matrix_identity_float3x3) * flip * keystone * unrotate * unscale * unshift
    }

    /// The forward map: source point in, output point out. Used to draw
    /// Upright's guides where they now sit on the picture.
    public var forwardMatrix: simd_float3x3 { inverseMatrix.inverse }

    /// Where an output sensor pixel is read from in the uncorrected image.
    /// Pure-Swift twin of the kernel's arithmetic, for tests and for
    /// widening tiles so the source is on hand.
    public func sourcePoint(forSensorPoint p: CGPoint, sensorSize s: CGSize) -> CGPoint {
        let halfShort = Float(min(s.width, s.height)) / 2
        let centre = SIMD2(Float(s.width) / 2, Float(s.height) / 2)
        let n = (SIMD2(Float(p.x), Float(p.y)) - centre) / halfShort
        let q = inverseMatrix * SIMD3(n.x, n.y, 1)
        let out = SIMD2(q.x, q.y) / max(q.z, 1e-4) * halfShort + centre
        return CGPoint(x: CGFloat(out.x), y: CGFloat(out.y))
    }

    /// Bounding box of the source pixels a sensor rectangle needs.
    public func sourceRect(forSensorRect r: CGRect, sensorSize s: CGSize) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                   CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
            .map { sourcePoint(forSensorPoint: $0, sensorSize: s) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .union(r)
    }
}
