import Foundation
import simd

/// A straight segment from `a` to `b`.
public struct LineSegment: Equatable, Sendable {
    public var a: SIMD2<Float>
    public var b: SIMD2<Float>

    public init(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        self.a = a
        self.b = b
    }

    public var length: Float { simd_distance(a, b) }
    public var midpoint: SIMD2<Float> { (a + b) / 2 }

    /// Direction in degrees, in (−90, 90]: 0 is horizontal, ±90 vertical.
    /// With y pointing down, a positive angle runs down to the right.
    public var angle: Float {
        let d = b - a
        var degrees = atan2(d.y, d.x) * 180 / .pi
        if degrees > 90 { degrees -= 180 }
        if degrees <= -90 { degrees += 180 }
        return degrees
    }

    /// The line through the segment as homogeneous coefficients (l · p = 0),
    /// scaled so its normal has unit length.
    var homogeneous: SIMD3<Float> {
        let l = simd_cross(SIMD3(a.x, a.y, 1), SIMD3(b.x, b.y, 1))
        let n = simd_length(SIMD2(l.x, l.y))
        return n > 0 ? l / n : l
    }

    /// The segment through a homography, endpoints divided through.
    public func transformed(by m: simd_float3x3) -> LineSegment {
        LineSegment(m.applied(to: a), m.applied(to: b))
    }
}

/// Finds straight edges in a picture: a small line-segment detector in the
/// manner of LSD (von Gioi et al.), on the CPU, for Upright and Auto
/// straighten. It runs on a render of about a thousand pixels on the long
/// edge, where it takes a few tens of milliseconds.
///
/// Each pixel's gradient gives the direction of the edge through it.
/// Starting from the strongest pixels, neighbours whose edge direction
/// agrees within `angleTolerance` are gathered into a region; a region
/// that is long and thin, and fills most of the rectangle around it, is
/// a straight edge, and its principal axis is the segment. Curves fail
/// the thinness test and texture fails the length test, so what survives
/// is the architecture, horizons and frames that Upright needs.
public enum LineDetector {
    public struct Options: Sendable {
        /// Weakest gradient (in 0…1 luminance per pixel) that can belong
        /// to an edge.
        public var minimumGradient: Float = 0.02
        /// How far, in degrees, a pixel's edge direction may differ from
        /// its region's.
        public var angleTolerance: Float = 22.5
        /// Shortest segment kept, as a fraction of the picture's short side.
        public var minimumLengthFraction: Float = 0.04
        /// Longest the region may be across, as a fraction of its length.
        public var maximumThinness: Float = 0.12
        /// How much of the segment's rectangle the region must fill.
        public var minimumDensity: Float = 0.45
        /// Segments touching the picture's border are skipped: that is
        /// usually the frame of the render, not a line in the scene.
        public var borderMargin: Int = 3

        public init() {}
    }

    /// Segments in `luminance` (row-major, `width` × `height`, 0…1), in
    /// pixel coordinates (pixel centres at +0.5), longest first.
    public static func segments(luminance: [Float], width: Int, height: Int,
                                options: Options = Options()) -> [LineSegment] {
        guard width >= 8, height >= 8, luminance.count == width * height else { return [] }
        let count = width * height
        var magnitude = [Float](repeating: 0, count: count)
        var direction = [Float](repeating: 0, count: count)   // edge (level-line) angle, radians
        // LSD's 2×2 gradient: it is centred on the corner shared by the four
        // pixels, so its direction carries no half-pixel bias.
        luminance.withUnsafeBufferPointer { l in
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let i = y * width + x
                    let a = l[i], b = l[i + 1], c = l[i + width], d = l[i + width + 1]
                    let gx = (b + d - a - c) / 2
                    let gy = (c + d - a - b) / 2
                    magnitude[i] = (gx * gx + gy * gy).squareRoot()
                    direction[i] = atan2(gx, -gy)
                }
            }
        }

        // Strongest pixels first, in 1024 buckets: the order only needs to
        // be roughly right, as LSD's own pseudo-ordering is.
        let top = magnitude.max() ?? 0
        guard top > options.minimumGradient else { return [] }
        let buckets = 1024
        var bucketed = [[Int32]](repeating: [], count: buckets)
        for i in 0..<count where magnitude[i] > options.minimumGradient {
            let b = min(buckets - 1, Int(magnitude[i] / top * Float(buckets - 1)))
            bucketed[b].append(Int32(i))
        }

        var used = [Bool](repeating: false, count: count)
        let tolerance = options.angleTolerance * .pi / 180
        let minimumLength = options.minimumLengthFraction * Float(min(width, height))
        var found: [LineSegment] = []
        var region: [Int32] = []
        region.reserveCapacity(4096)

        func angleDifference(_ a: Float, _ b: Float) -> Float {
            var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d = 2 * .pi - d }
            return d
        }

        for bucket in stride(from: buckets - 1, through: 0, by: -1) {
            for seed in bucketed[bucket] where !used[Int(seed)] {
                // Grow the region: neighbours aligned with its running direction.
                region.removeAll(keepingCapacity: true)
                region.append(seed)
                used[Int(seed)] = true
                var sumCos = cos(direction[Int(seed)]), sumSin = sin(direction[Int(seed)])
                var regionAngle = direction[Int(seed)]
                var next = 0
                while next < region.count {
                    let p = Int(region[next]); next += 1
                    let px = p % width, py = p / width
                    for dy in -1...1 {
                        let ny = py + dy
                        guard ny >= 0, ny < height - 1 else { continue }
                        for dx in -1...1 {
                            let nx = px + dx
                            guard nx >= 0, nx < width - 1, dx != 0 || dy != 0 else { continue }
                            let n = ny * width + nx
                            guard !used[n], magnitude[n] > options.minimumGradient,
                                  angleDifference(direction[n], regionAngle) < tolerance else { continue }
                            used[n] = true
                            region.append(Int32(n))
                            sumCos += cos(direction[n]); sumSin += sin(direction[n])
                            regionAngle = atan2(sumSin, sumCos)
                        }
                    }
                }
                guard Float(region.count) >= minimumLength * 0.5,
                      let segment = fit(region, width: width, magnitude: magnitude, options: options,
                                        minimumLength: minimumLength) else { continue }
                // Not hugging the picture's border.
                let margin = Float(options.borderMargin)
                let maxX = Float(width) - margin, maxY = Float(height) - margin
                let onBorder = [segment.a, segment.b].allSatisfy { $0.x < margin || $0.x > maxX }
                    || [segment.a, segment.b].allSatisfy { $0.y < margin || $0.y > maxY }
                if !onBorder { found.append(segment) }
            }
        }
        return merged(found, gap: Float(min(width, height)) * 0.03).sorted { $0.length > $1.length }
    }

    /// Joins pieces of one edge: a shallow line on a pixel grid breaks
    /// where its staircase steps, and a pole behind a branch is two
    /// pieces. Two segments are joined when they point the same way
    /// (within a degree), lie on one line (within 1.5 pixels) and the
    /// gap between them is under `gap` pixels.
    static func merged(_ segments: [LineSegment], gap: Float) -> [LineSegment] {
        var pool = segments.sorted { $0.length > $1.length }
        var i = 0
        while i < pool.count {
            var j = i + 1
            while j < pool.count {
                if let joined = join(pool[i], pool[j], gap: gap) {
                    // The longer piece grew: look again at everything after it.
                    pool[i] = joined
                    pool.remove(at: j)
                    j = i + 1
                } else {
                    j += 1
                }
            }
            i += 1
        }
        return pool
    }

    static func join(_ a: LineSegment, _ b: LineSegment, gap: Float) -> LineSegment? {
        var difference = abs(a.angle - b.angle)
        if difference > 90 { difference = 180 - difference }
        guard difference < 1 else { return nil }
        let u = simd_normalize(a.b - a.a), n = SIMD2(-u.y, u.x)
        guard abs(simd_dot(b.a - a.a, n)) < 1.5, abs(simd_dot(b.b - a.a, n)) < 1.5 else { return nil }
        let tb = [simd_dot(b.a - a.a, u), simd_dot(b.b - a.a, u)]
        let lengthA = a.length
        let lo = min(0, tb.min()!), hi = max(lengthA, tb.max()!)
        // The gap is what the two leave uncovered between them.
        let covered = lengthA + abs(tb[1] - tb[0])
        guard (hi - lo) - covered < gap else { return nil }
        return LineSegment(a.a + u * lo, a.a + u * hi)
    }

    /// The segment a region of pixels describes, when it is straight
    /// enough: its principal axis by gradient-weighted moments, the
    /// extent along it, and checks on width and fill.
    private static func fit(_ region: [Int32], width: Int, magnitude: [Float], options: Options,
                            minimumLength: Float) -> LineSegment? {
        var w: Float = 0, cx: Float = 0, cy: Float = 0
        for p in region {
            let i = Int(p), m = magnitude[i]
            // The 2×2 gradient sits on the corner between pixels.
            cx += m * (Float(i % width) + 1); cy += m * (Float(i / width) + 1); w += m
        }
        guard w > 0 else { return nil }
        cx /= w; cy /= w
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
        for p in region {
            let i = Int(p), m = magnitude[i]
            let dx = Float(i % width) + 1 - cx, dy = Float(i / width) + 1 - cy
            sxx += m * dx * dx; syy += m * dy * dy; sxy += m * dx * dy
        }
        // Principal axis of the 2×2 moment matrix.
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let axis = SIMD2(cos(theta), sin(theta)), normal = SIMD2(-axis.y, axis.x)
        var lo: Float = .infinity, hi: Float = -.infinity, nlo: Float = .infinity, nhi: Float = -.infinity
        for p in region {
            let i = Int(p)
            let d = SIMD2(Float(i % width) + 1 - cx, Float(i / width) + 1 - cy)
            let along = simd_dot(d, axis), across = simd_dot(d, normal)
            lo = min(lo, along); hi = max(hi, along)
            nlo = min(nlo, across); nhi = max(nhi, across)
        }
        let length = hi - lo + 1, thickness = nhi - nlo + 1
        guard length >= minimumLength,
              thickness <= max(3, length * options.maximumThinness),
              Float(region.count) / (length * thickness) >= options.minimumDensity else { return nil }
        let centre = SIMD2(cx, cy)
        return LineSegment(centre + axis * lo, centre + axis * hi)
    }

    /// Rec. 709 luminance of 8-bit RGBA pixels (row-major, `bytesPerRow`
    /// apart), still in their transfer curve: edges are found as the eye
    /// sees them.
    public static func luminance(rgba: UnsafeRawBufferPointer, width: Int, height: Int,
                                 bytesPerRow: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                let r = Float(rgba[o]), g = Float(rgba[o + 1]), b = Float(rgba[o + 2])
                out[y * width + x] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            }
        }
        return out
    }
}
