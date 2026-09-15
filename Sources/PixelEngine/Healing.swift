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
///
/// A patch can also be a brush stroke (`stroke`), for blemishes a circle
/// can't cover: a wire, a hair, a dust streak. The stroke is a path of
/// points drawn `radius` wide; its source is the same path moved by
/// `source - target`, so the whole length copies from one offset.
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
    /// A brush stroke's path, as offsets from `target` (normalized sensor
    /// coordinates, the first normally zero). Nil for a circle, and absent
    /// from the JSON then, so circles encode exactly as before strokes.
    public var stroke: [SIMD2<Float>]?

    public init(id: UUID = UUID(), target: SIMD2<Float>, source: SIMD2<Float>,
                radius: Float, feather: Float = 0.35, mode: Mode = .heal,
                stroke: [SIMD2<Float>]? = nil) {
        self.id = id
        self.target = target
        self.source = source
        self.radius = radius
        self.feather = feather
        self.mode = mode
        self.stroke = stroke
    }

    /// Patches per image; a stroke counts as one, however long.
    public static let maximumCount = 32
    /// Points per stroke once simplified (`simplifiedStroke`). A straight
    /// wire needs two; the limit only bites on a long scribble, which is
    /// simplified harder to fit.
    public static let maximumStrokePoints = 256

    /// Whether this patch is a brush stroke rather than a circle.
    public var isStroke: Bool { stroke != nil }

    /// The stroke's path (or the circle's centre) in normalized sensor
    /// coordinates, around the target or, with `atSource`, the source.
    public func pathPoints(atSource: Bool = false) -> [SIMD2<Float>] {
        let anchor = atSource ? source : target
        guard let stroke, !stroke.isEmpty else { return [anchor] }
        return stroke.map { anchor + $0 }
    }

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
        guard let stroke, !stroke.isEmpty else {
            return CGRect(x: CGFloat(c.x) * s.width - r, y: CGFloat(c.y) * s.height - r,
                          width: 2 * r, height: 2 * r)
        }
        // A stroke: the box of its path, `radius` wider on every side.
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for d in stroke { lo = simd_min(lo, c + d); hi = simd_max(hi, c + d) }
        return CGRect(x: CGFloat(lo.x) * s.width - r, y: CGFloat(lo.y) * s.height - r,
                      width: CGFloat(hi.x - lo.x) * s.width + 2 * r,
                      height: CGFloat(hi.y - lo.y) * s.height + 2 * r)
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
    /// that can change a pixel of `region` reads what the whole frame would
    /// give it: its source and, for a heal, the surroundings of both
    /// circles. A tile that only covers the visible area would otherwise
    /// have nothing to copy from.
    ///
    /// Patches apply in order, each reading the result of the ones before,
    /// so walking them last to first finds exactly those: a patch counts
    /// when its target touches `region` or what a later counted patch
    /// reads. A later patch whose target merely lies in an earlier one's
    /// read area can't change what that one read, and pulling it in would
    /// chain across the frame from spot to spot. Reads are clamped to the
    /// sensor, as the render's are, so a patch at the edge doesn't turn
    /// its off-sensor reach into extra tile width; `region` itself is kept
    /// as given.
    ///
    /// Outside `region` the tile can hold patches that don't count, with
    /// reads it never included; `isSelfContained` says when there are none.
    public static func regionIncludingSources(_ region: CGRect, patches: [HealPatch],
                                              sensorSize s: CGSize) -> CGRect {
        var needed = [region]
        for p in patches.reversed() {
            let target = p.targetBounds(sensorSize: s)
            guard needed.contains(where: { $0.intersects(target) }) else { continue }
            let margin = p.readRadiusPixels(sensorSize: s) - p.radiusPixels(sensorSize: s)
            if p.mode == .heal {
                needed.append(clampedToSensor(target.insetBy(dx: -margin, dy: -margin), s))
            }
            needed.append(clampedToSensor(p.sourceBounds(sensorSize: s).insetBy(dx: -margin, dy: -margin), s))
        }
        return needed.dropFirst().reduce(region) { $0.union($1) }
    }

    /// Whether every patch touching `region` reads only inside it, so the
    /// whole of a render of `region` heals as the whole frame does.
    public static func isSelfContained(_ region: CGRect, patches: [HealPatch], sensorSize s: CGSize) -> Bool {
        region.contains(regionIncludingSources(region, patches: patches, sensorSize: s))
    }

    /// The sensor pixels a read of `rect` touches once clamped to the
    /// edge: at least a one-pixel strip, even for a read wholly outside.
    private static func clampedToSensor(_ rect: CGRect, _ s: CGSize) -> CGRect {
        let x0 = min(max(rect.minX, 0), s.width - 1), y0 = min(max(rect.minY, 0), s.height - 1)
        let x1 = max(min(rect.maxX, s.width), x0 + 1), y1 = max(min(rect.maxY, s.height), y0 + 1)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
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
