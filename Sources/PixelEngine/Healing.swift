import Foundation
import CoreGraphics
import simd

/// One spot-removal patch: pixels inside the `source` circle are copied
/// over the `target` circle, with a feathered edge.
///
/// Coordinates are normalized sensor coordinates like the masks, and the
/// patch is applied in camera-linear space before lens correction, so it
/// is unaffected by rotation, crop, zoom or colour edits. `clone` copies
/// pixels exactly; `heal` also multiplies them by a smooth ratio field,
/// the target's surroundings over the source's, so tone and colour follow
/// what is around the target on every side (a gradient or a horizon
/// included) while the texture is the source's. That hides the seam the
/// way a Poisson blend would, at the cost of a few small blurs. Patches
/// apply in order, each reading the result of the ones before.
public struct HealPatch: Equatable, Sendable, Codable, Identifiable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case heal, clone
    }

    public var id: UUID
    public var target: SIMD2<Float>
    public var source: SIMD2<Float>
    /// Fraction of the sensor's short side.
    public var radius: Float
    /// 0 (hard edge) … 1 (fades from the centre).
    public var feather: Float
    public var mode: Mode

    public init(id: UUID = UUID(), target: SIMD2<Float>, source: SIMD2<Float>,
                radius: Float, feather: Float = 0.35, mode: Mode = .heal) {
        self.id = id
        self.target = target
        self.source = source
        self.radius = radius
        self.feather = feather
        self.mode = mode
    }

    /// The GPU-side array is fixed; more patches would need a buffer.
    public static let maximumCount = 32

    public func radiusPixels(sensorSize s: CGSize) -> CGFloat {
        CGFloat(radius) * min(s.width, s.height)
    }

    /// Sensor-pixel bounding boxes of the two circles.
    public func targetBounds(sensorSize s: CGSize) -> CGRect {
        circleBounds(target, sensorSize: s)
    }
    public func sourceBounds(sensorSize s: CGSize) -> CGRect {
        circleBounds(source, sensorSize: s)
    }

    private func circleBounds(_ c: SIMD2<Float>, sensorSize s: CGSize) -> CGRect {
        let r = radiusPixels(sensorSize: s)
        return CGRect(x: CGFloat(c.x) * s.width - r, y: CGFloat(c.y) * s.height - r,
                      width: 2 * r, height: 2 * r)
    }

    /// How far from its centres the patch reads, in sensor pixels at full
    /// resolution: the source circle (and a pixel for filtering) for a
    /// clone, the blurred surroundings for a heal.
    public func readRadiusPixels(sensorSize s: CGSize) -> CGFloat {
        let r = radiusPixels(sensorSize: s)
        switch mode {
        case .clone: return r + 2
        case .heal: return max(r + 2, CGFloat(HealFieldLayout(radius: Float(r)).reach))
        }
    }

    /// The sensor region a render of `region` must include so every patch
    /// whose target it touches can also read its source and, for a heal,
    /// the surroundings of both circles. A tile that only covers the
    /// visible area would otherwise have nothing to copy from. Patches
    /// read the ones before them, so the region grows until no further
    /// patch is touched. Not clipped to the sensor; the render clamps.
    public static func regionIncludingSources(_ region: CGRect, patches: [HealPatch],
                                              sensorSize s: CGSize) -> CGRect {
        var out = region
        var included = [Bool](repeating: false, count: patches.count)
        var grew = true
        while grew {
            grew = false
            for (i, p) in patches.enumerated() where !included[i] && p.targetBounds(sensorSize: s).intersects(out) {
                included[i] = true
                grew = true
                let margin = p.readRadiusPixels(sensorSize: s) - p.radiusPixels(sensorSize: s)
                if p.mode == .heal {
                    out = out.union(p.targetBounds(sensorSize: s).insetBy(dx: -margin, dy: -margin))
                }
                out = out.union(p.sourceBounds(sensorSize: s).insetBy(dx: -margin, dy: -margin))
            }
        }
        return out
    }
}

/// Mirror of `HealPatchGPU` in Heal.metal.
struct HealPatchGPU {
    var geometry: SIMD4<Float>   // target.xy, source.xy (normalized sensor)
    var params: SIMD4<Float>     // radius (fraction of short side), feather, mode (0 heal, 1 clone), 0

    init(_ p: HealPatch) {
        geometry = SIMD4(p.target.x, p.target.y, p.source.x, p.source.y)
        params = SIMD4(p.radius, p.feather, p.mode == .clone ? 1 : 0, 0)
    }
}
