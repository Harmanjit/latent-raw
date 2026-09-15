import Foundation
import CoreGraphics
import simd

/// The geometry of brush-stroke spot removal: turning a painted path into
/// a stored stroke, choosing its source, hit testing it, and cutting it
/// into the short pieces the GPU heals one at a time (HealStage).
extension HealPatch {
    /// A stroke patch from a painted `path` (normalized sensor coordinates,
    /// in the order painted), simplified to at most `maximumStrokePoints`,
    /// with its source placed beside it by `automaticStrokeOffset`.
    public static func stroke(path: [SIMD2<Float>], radius: Float, feather: Float, mode: Mode,
                              sensorSize s: CGSize, id: UUID = UUID()) -> HealPatch? {
        let points = simplifiedStroke(path, radius: radius, sensorSize: s)
        guard let first = points.first else { return nil }
        let offset = automaticStrokeOffset(points, radius: radius, sensorSize: s)
        return HealPatch(id: id, target: first, source: first + offset, radius: radius,
                         feather: feather, mode: mode, stroke: points.map { $0 - first })
    }

    /// The path with points closer than a tenth of the radius to the line
    /// through their neighbours dropped (Ramer-Douglas-Peucker), which the
    /// eye can't tell apart at the stroke's width, then simplified harder
    /// until at most `limit` remain.
    public static func simplifiedStroke(_ path: [SIMD2<Float>], radius: Float, sensorSize s: CGSize,
                                        limit: Int = maximumStrokePoints) -> [SIMD2<Float>] {
        let scale = SIMD2(Float(s.width), Float(s.height))
        guard path.count > 2, scale.x > 0, scale.y > 0 else { return path }
        let pixels = path.map { $0 * scale }
        var tolerance = max(0.1 * radius * min(scale.x, scale.y), 0.5)
        while true {
            var keep = [Bool](repeating: false, count: pixels.count)
            keep[0] = true
            keep[pixels.count - 1] = true
            var spans = [(0, pixels.count - 1)]
            while let (a, b) = spans.popLast() {
                guard b > a + 1 else { continue }
                var worst = 0, worstDistance: Float = 0
                for i in (a + 1)..<b {
                    let d = segmentDistance(pixels[i], pixels[a], pixels[b])
                    if d > worstDistance { worstDistance = d; worst = i }
                }
                if worstDistance > tolerance {
                    keep[worst] = true
                    spans.append((a, worst))
                    spans.append((worst, b))
                }
            }
            let kept = path.indices.filter { keep[$0] }.map { path[$0] }
            if kept.count <= max(limit, 2) { return kept }
            tolerance *= 1.5
        }
    }

    /// Where a stroke's source goes, as an offset from its target: across
    /// the stroke rather than along it (along a wire, the source would be
    /// more wire), a clear gap past its width, on the side that stays on
    /// the sensor.
    public static func automaticStrokeOffset(_ points: [SIMD2<Float>], radius: Float,
                                             sensorSize s: CGSize) -> SIMD2<Float> {
        let scale = SIMD2(Float(s.width), Float(s.height))
        guard !points.isEmpty, scale.x > 0, scale.y > 0 else { return .zero }
        let r = radius * min(scale.x, scale.y)
        let pixels = points.map { $0 * scale }
        // The principal direction of the points (a single point: sideways).
        let mean = pixels.reduce(SIMD2<Float>.zero, +) / Float(pixels.count)
        var sxx: Float = 0, sxy: Float = 0, syy: Float = 0
        for p in pixels {
            let d = p - mean
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let along = sxx + syy > 1e-6 ? SIMD2(cos(angle), sin(angle)) : SIMD2<Float>(1, 0)
        let across = SIMD2(-along.y, along.x)
        // The stroke's whole extent across that direction, so a wavy hair
        // clears itself, plus one and a half widths: the two outlines are
        // then a radius apart at their closest.
        let acrossExtent = pixels.map { simd_dot($0 - mean, across) }
        let distance = (acrossExtent.max() ?? 0) - (acrossExtent.min() ?? 0) + 3 * r
        let lo = pixels.reduce(SIMD2(repeating: Float.infinity)) { simd_min($0, $1) } - r
        let hi = pixels.reduce(SIMD2(repeating: -Float.infinity)) { simd_max($0, $1) } + r
        // Each side scored by how far its box would stick off the sensor.
        func overhang(_ shift: SIMD2<Float>) -> Float {
            let a = lo + shift, b = hi + shift
            return max(0, -a.x) + max(0, -a.y) + max(0, b.x - scale.x) + max(0, b.y - scale.y)
        }
        let candidates = [across, -across].map { $0 * distance }
        let chosen = candidates.min { overhang($0) < overhang($1) } ?? candidates[0]
        return chosen / scale
    }

    /// Distance in sensor pixels from `p` (normalized) to the patch's
    /// target or source outline's centre line: the circle's centre, or the
    /// nearest point of the stroke's path.
    public func distancePixels(from p: SIMD2<Float>, atSource: Bool = false, sensorSize s: CGSize) -> Float {
        let scale = SIMD2(Float(s.width), Float(s.height))
        let q = p * scale
        let path = pathPoints(atSource: atSource).map { $0 * scale }
        guard path.count > 1 else { return simd_length(q - path[0]) }
        var best = Float.infinity
        for i in 1..<path.count { best = min(best, Self.segmentDistance(q, path[i - 1], path[i])) }
        return best
    }

    /// Distance from `p` to the segment from `a` to `b`.
    static func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-12 else { return simd_length(p - a) }
        let t = simd_clamp(simd_dot(p - a, ab) / lengthSquared, 0, 1)
        return simd_length(p - (a + t * ab))
    }

    /// The stroke's path in texture pixels cut into segments no longer than
    /// twice the radius, so each piece's surroundings grid stays about the
    /// size of a circle's. A long stroke would otherwise need one grid as
    /// big as its bounding box, which for a wire across the frame is most
    /// of the frame. Capped at `maximumPieces` by lengthening the pieces.
    static func strokeSegments(_ path: [SIMD2<Float>], radius: Float,
                               maximumPieces: Int = 512) -> [(SIMD2<Float>, SIMD2<Float>)] {
        guard let first = path.first else { return [] }
        guard path.count > 1 else { return [(first, first)] }
        var total: Float = 0
        for i in 1..<path.count { total += simd_length(path[i] - path[i - 1]) }
        let longest = max(2 * radius, 1, total / Float(maximumPieces))
        var segments: [(SIMD2<Float>, SIMD2<Float>)] = []
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let parts = max(1, Int((simd_length(b - a) / longest).rounded(.up)))
            for k in 0..<parts {
                segments.append((a + (b - a) * (Float(k) / Float(parts)), a + (b - a) * (Float(k + 1) / Float(parts))))
            }
        }
        return segments
    }
}
