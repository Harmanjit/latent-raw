import Foundation
import CoreGraphics
import simd

/// Detect Objects: turning a segmentation of the area around a Remove
/// brush (Segment Anything, run on a crop of the image by the app) into the
/// object outline the patch stores.
///
/// The segmentation is on the output grid (what the viewport shows, after
/// lens correction), while patches live on the raw grid; the outline is
/// therefore resampled cell by cell through the lens map, as the brush's
/// own points are.
public enum RemoveDetection {
    /// Cells along the stored outline's longer side.
    public static let storedSide = 256
    /// Past this fraction of the crop the model has taken the background,
    /// not the thing brushed.
    public static let maximumCropCoverage = 0.6

    /// Where to crop the image for the model, in output-normalized
    /// coordinates: the brushed area's box, grown by half its size and two
    /// brush widths, squared up so the model sees the object in proportion,
    /// at least `minimumSide` (normalized to the short side) and clamped to
    /// the image. `aspect` is the image's width over its height.
    public static func cropRect(path: [SIMD2<Float>], radius: Float, aspect: Float,
                                minimumSide: Float = 0.08) -> CGRect? {
        guard let first = path.first, aspect > 0, radius.isFinite else { return nil }
        var lo = first, hi = first
        for p in path { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        // Work in units of the image's height so the square is square.
        let scale = SIMD2<Float>(aspect, 1)
        lo *= scale; hi *= scale
        let r = radius * min(aspect, 1)
        lo -= r; hi += r
        let extent = hi - lo
        let grow = 0.5 * extent.max() + 2 * r
        let side = max(extent.max() + 2 * grow, minimumSide * min(aspect, 1))
        let centre = (lo + hi) / 2
        var a = centre - side / 2, b = centre + side / 2
        // Slide back onto the image, then clip what still overhangs.
        let bound = scale
        for axis in 0..<2 {
            if a[axis] < 0 { b[axis] -= a[axis]; a[axis] = 0 }
            if b[axis] > bound[axis] { a[axis] -= b[axis] - bound[axis]; b[axis] = bound[axis] }
            a[axis] = max(a[axis], 0)
        }
        a /= scale; b /= scale
        guard b.x > a.x, b.y > a.y else { return nil }
        return CGRect(x: CGFloat(a.x), y: CGFloat(a.y), width: CGFloat(b.x - a.x), height: CGFloat(b.y - a.y))
    }

    /// Up to `count` points spread evenly along `path` by length (its only
    /// point for a circle), the prompts that say "this object".
    public static func promptPoints(along path: [SIMD2<Float>], count: Int = 6) -> [SIMD2<Float>] {
        guard let first = path.first else { return [] }
        guard path.count > 1, count > 1 else { return [first] }
        var lengths: [Float] = [0]
        for i in 1..<path.count { lengths.append(lengths[i - 1] + simd_length(path[i] - path[i - 1])) }
        let total = lengths.last ?? 0
        guard total > 0 else { return [first] }
        return (0..<count).map { k in
            let d = total * Float(k) / Float(count - 1)
            var i = 1
            while i < path.count - 1, lengths[i] < d { i += 1 }
            let span = max(lengths[i] - lengths[i - 1], 1e-9)
            return path[i - 1] + (path[i] - path[i - 1]) * min(max((d - lengths[i - 1]) / span, 0), 1)
        }
    }

    /// The outline to store, or nil when the segmentation found nothing at
    /// the brush (or took most of the crop).
    ///
    /// - `mask`: the model's soft mask over `crop` (output-normalized).
    /// - `seeds`: the prompt points, output-normalized. Only the parts of
    ///   the mask joined to a seed are kept, so a second object the model
    ///   also lit up elsewhere in the crop is left alone.
    /// - `toOutput` / `toRaw`: the lens map each way, normalized.
    /// - `target`: the patch's target, raw-normalized; the outline is
    ///   stored relative to it.
    /// - `sensorSize`: for the dilation and the stored cell shape.
    ///
    /// The outline is grown by `dilation` of the sensor's short side (and
    /// at least two mask cells): an object's soft edge and its shadow or
    /// halo sit just outside what the model calls the object, and a fill
    /// that stops at the outline leaves them as a ghost.
    public static func objectMask(from mask: MaskBitmap, crop: CGRect, seeds: [SIMD2<Float>],
                                  toOutput: (SIMD2<Float>) -> SIMD2<Float>,
                                  toRaw: (SIMD2<Float>) -> SIMD2<Float>,
                                  target: SIMD2<Float>, sensorSize: CGSize,
                                  dilation: Float = 0.004) -> RemoveObjectMask? {
        let w = mask.width, h = mask.height
        guard w > 1, h > 1, crop.width > 0, crop.height > 0, sensorSize.width > 0, sensorSize.height > 0 else { return nil }
        let cropOrigin = SIMD2(Float(crop.minX), Float(crop.minY))
        let cropSize = SIMD2(Float(crop.width), Float(crop.height))
        func cell(_ p: SIMD2<Float>) -> SIMD2<Int> {
            let c = (p - cropOrigin) / cropSize * SIMD2(Float(w), Float(h))
            return SIMD2(Int(c.x.rounded(.down)), Int(c.y.rounded(.down)))
        }

        // The parts joined to a seed.
        var keep = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for seed in seeds {
            let c = cell(seed)
            guard c.x >= 0, c.y >= 0, c.x < w, c.y < h else { continue }
            let i = c.y * w + c.x
            if mask.data[i] > 127, !keep[i] { keep[i] = true; stack.append(i) }
        }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if !keep[j], mask.data[j] > 127 { keep[j] = true; stack.append(j) }
            }
        }
        let kept = keep.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard kept > 0, Double(kept) / Double(w * h) <= maximumCropCoverage else { return nil }

        // Grow by the dilation, in cells, with a two-pass chamfer distance.
        let cellPixels = Float(crop.width) * Float(sensorSize.width) / Float(w)
        let grow = max(2, dilation * Float(min(sensorSize.width, sensorSize.height)) / max(cellPixels, 1e-6))
        var distance = keep.map { $0 ? Float(0) : Float.infinity }
        let diagonal = Float(2).squareRoot()
        for y in 0..<h { for x in 0..<w {
            var d = distance[y * w + x]
            if x > 0 { d = min(d, distance[y * w + x - 1] + 1) }
            if y > 0 {
                d = min(d, distance[(y - 1) * w + x] + 1)
                if x > 0 { d = min(d, distance[(y - 1) * w + x - 1] + diagonal) }
                if x < w - 1 { d = min(d, distance[(y - 1) * w + x + 1] + diagonal) }
            }
            distance[y * w + x] = d
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            var d = distance[y * w + x]
            if x < w - 1 { d = min(d, distance[y * w + x + 1] + 1) }
            if y < h - 1 {
                d = min(d, distance[(y + 1) * w + x] + 1)
                if x < w - 1 { d = min(d, distance[(y + 1) * w + x + 1] + diagonal) }
                if x > 0 { d = min(d, distance[(y + 1) * w + x - 1] + diagonal) }
            }
            distance[y * w + x] = d
        } }
        let grown = distance.map { $0 <= grow }

        // Its box on the output grid, then on the raw grid through the
        // lens map (corners and edge midpoints, a cell spare).
        var lo = SIMD2(Int.max, Int.max), hi = SIMD2(Int.min, Int.min)
        for y in 0..<h { for x in 0..<w where grown[y * w + x] {
            lo = simd_min(lo, SIMD2(x, y)); hi = simd_max(hi, SIMD2(x, y))
        } }
        let cellSize = cropSize / SIMD2(Float(w), Float(h))
        let outLo = cropOrigin + SIMD2<Float>(lo) * cellSize - cellSize
        let outHi = cropOrigin + SIMD2<Float>(hi &+ 1) * cellSize + cellSize
        let mid = (outLo + outHi) / 2
        let probes = [outLo, outHi, SIMD2(outLo.x, outHi.y), SIMD2(outHi.x, outLo.y),
                      SIMD2(mid.x, outLo.y), SIMD2(mid.x, outHi.y), SIMD2(outLo.x, mid.y), SIMD2(outHi.x, mid.y)].map(toRaw)
        var rawLo = probes[0], rawHi = probes[0]
        for p in probes { rawLo = simd_min(rawLo, p); rawHi = simd_max(rawHi, p) }
        let rawSize = rawHi - rawLo
        guard rawSize.x > 0, rawSize.y > 0, rawSize.x <= 1, rawSize.y <= 1 else { return nil }

        // Stored cells, square in sensor pixels, the longer side `storedSide`.
        let pixels = rawSize * SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let side = Float(storedSide) / pixels.max()
        let sw = max(1, min(storedSide, Int((pixels.x * side).rounded()))),
            sh = max(1, min(storedSide, Int((pixels.y * side).rounded())))
        var cells = [Bool](repeating: false, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw {
            let raw = rawLo + (SIMD2(Float(x), Float(y)) + 0.5) / SIMD2(Float(sw), Float(sh)) * rawSize
            let c = cell(toOutput(raw))
            if c.x >= 0, c.y >= 0, c.x < w, c.y < h { cells[y * sw + x] = grown[c.y * w + c.x] }
        } }
        guard cells.contains(true) else { return nil }
        return RemoveObjectMask(cells: cells, width: sw, height: sh, origin: rawLo - target, size: rawSize)
    }
}
