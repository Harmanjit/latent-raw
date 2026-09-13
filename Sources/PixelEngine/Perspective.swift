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
public struct PerspectiveCorrection: Equatable, Sendable {
    public var vertical: Float
    public var horizontal: Float

    public init(vertical: Float = 0, horizontal: Float = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public static let none = PerspectiveCorrection()
    public var isIdentity: Bool { vertical == 0 && horizontal == 0 }

    static let gain: Float = 0.5

    /// The matrix the kernel applies to (x, y, 1): output point in, source
    /// point out (after the homogeneous divide). Column-major for simd.
    public var inverseMatrix: simd_float3x3 {
        let h = -horizontal * Self.gain, v = -vertical * Self.gain
        // Rows: [1 0 0], [0 1 0], [h v 1]  → q.z = h·x + v·y + 1
        return simd_float3x3(columns: (SIMD3(1, 0, h), SIMD3(0, 1, v), SIMD3(0, 0, 1)))
    }

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
