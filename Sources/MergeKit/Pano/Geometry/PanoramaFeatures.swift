import Accelerate
import Foundation
import simd

// The panorama registration's fallback: find distinctive corners in two
// photos, match them by the look of their surroundings, and keep the
// matches one camera rotation explains.

/// Corners and their descriptors in one thumbnail.
struct PanoramaFeatureSet: Sendable {
    /// Where each corner is, in full-resolution pixels (top-left origin).
    var points: [SIMD2<Double>]
    /// `descriptorLength` Float32 per corner, zero mean and unit length, so
    /// the dot product of two is their normalised cross-correlation.
    var descriptors: [Float]

    var count: Int { points.count }
}

/// A corner matcher for photos that turned between shots, on the CPU with
/// Accelerate.
///
/// **Why a fallback is needed.** `FrameAligner` refines one starting guess
/// by following the image's gradients, and its guess comes from phase
/// correlation, which assumes the frames only shifted. Between panorama
/// frames the camera turned by 15-20°: the overlap is also stretched by
/// perspective, has parallax (the camera turns about the photographer, not
/// its lens), and may be mostly smooth sky, so the guess can be too far
/// off to refine. Corners don't need a guess: each is compared with every
/// corner of the other photo.
///
/// **The steps.**
/// 1. **Corners** (Harris): points where the log image changes strongly in
///    two directions, the ones a small patch can be found again by. Picked
///    across a grid so a detailed foreground doesn't take them all.
/// 2. **Descriptors:** an 8 x 8 sample of the log image around each corner,
///    blurred, minus its mean, divided by its length. Log values make a
///    stop brighter a plain offset, which the mean removes, so photos taken
///    at different exposures still match.
/// 3. **Matching:** every pair's correlation at once (one matrix product);
///    a match must be each other's best, and clearly better than the
///    second best (the ratio test), which throws out repetitive detail.
/// 4. **RANSAC:** a camera that turns about its lens moves every point by
///    one rotation R: the ray through a pixel of the first photo, turned by
///    R, is the ray through the matching pixel of the second. Two matches
///    fix R; many random pairs are tried and the R most matches agree with
///    (within a few pixels) wins, then is fitted again to all of them.
///    Wrong matches (people who moved, clouds, repeated rocks) disagree and
///    are left out.
enum PanoramaFeatures {
    /// Samples per side of a descriptor, `descriptorStride` texels apart.
    static let descriptorSide = 8
    static let descriptorStride = 2
    static var descriptorLength: Int { descriptorSide * descriptorSide }
    /// Texels from a corner to the edge of its descriptor's footprint.
    static var footprintRadius: Int { (descriptorSide * descriptorStride) / 2 + 1 }
    /// The grid corners are picked across, and the most per cell.
    static let gridCells = 12
    static let cornersPerCell = 5
    /// The ratio test: the best match's distance must be under this share
    /// of the second best's.
    static let ratio: Float = 0.85
    /// Luminance below which log values are mostly noise (2^-11 of white,
    /// as `AlignmentImage.defaultNoiseFloor`), divided by the frame's gain.
    static let noiseFloor: Float = 1.0 / 2048

    // MARK: - Corners and descriptors

    /// The corners of `thumbnail`, whose luminance is divided by `gain`
    /// first (so frames at different exposures share one noise floor).
    static func detect(_ thumbnail: PanoramaThumbnail, gain: Double) -> PanoramaFeatureSet {
        let w = thumbnail.width, h = thumbnail.height
        let count = w * h
        let luminance = thumbnail.luminance
        let floor = noiseFloor
        let invGain = Float(1 / max(gain, 1e-12))
        var log = [Float](repeating: 0, count: count)
        var usable = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let l = luminance[i] * invGain
            log[i] = log2(max(l, floor))
            usable[i] = thumbnail.isUsable(i) && l > floor
        }
        // Detail finer than about a texel is noise and demosaic texture.
        let smooth = blur(log, width: w, height: h, sigma: 1.0)
        let descriptorSource = blur(log, width: w, height: h, sigma: Float(descriptorStride) * 0.6)

        // Harris: the structure tensor's smallest change, cheaply.
        var ixx = [Float](repeating: 0, count: count), iyy = ixx, ixy = ixx
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = 0.5 * (smooth[i + 1] - smooth[i - 1]), gy = 0.5 * (smooth[i + w] - smooth[i - w])
                ixx[i] = gx * gx; iyy[i] = gy * gy; ixy[i] = gx * gy
            }
        }
        ixx = blur(ixx, width: w, height: h, sigma: 2)
        iyy = blur(iyy, width: w, height: h, sigma: 2)
        ixy = blur(ixy, width: w, height: h, sigma: 2)
        var response = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let trace = ixx[i] + iyy[i]
            response[i] = ixx[i] * iyy[i] - ixy[i] * ixy[i] - 0.04 * trace * trace
        }

        // A corner's footprint must be entirely usable photo: a patch that
        // runs into clipping or off the lens-corrected edge looks different
        // in the other frame.
        let r = footprintRadius
        var clear = [Bool](repeating: false, count: count)
        do {
            // Unusable texels grown by the footprint radius, rows then columns.
            var rows = [Int](repeating: 0, count: count)
            for y in 0..<h {
                var lastBad = -1_000_000
                for x in 0..<w { if !usable[y * w + x] { lastBad = x }; rows[y * w + x] = x - lastBad }
                lastBad = 1_000_000
                for x in stride(from: w - 1, through: 0, by: -1) {
                    if !usable[y * w + x] { lastBad = x }
                    rows[y * w + x] = min(rows[y * w + x], lastBad - x)
                }
            }
            for x in 0..<w {
                for y in r..<max(r, h - r) {
                    var ok = x >= r && x < w - r
                    if ok {
                        for dy in -r...r where rows[(y + dy) * w + x] <= r { ok = false; break }
                    }
                    clear[y * w + x] = ok
                }
            }
        }

        // The strongest local maxima in each grid cell.
        let peak = response.max() ?? 0
        let threshold = max(peak * 1e-4, 1e-10)
        var chosen: [(x: Int, y: Int)] = []
        let cellW = max(1, (w + gridCells - 1) / gridCells), cellH = max(1, (h + gridCells - 1) / gridCells)
        for cy in 0..<gridCells {
            for cx in 0..<gridCells {
                var candidates: [(Float, Int, Int)] = []
                for y in (cy * cellH)..<min(h, (cy + 1) * cellH) {
                    for x in (cx * cellW)..<min(w, (cx + 1) * cellW) {
                        let i = y * w + x
                        let v = response[i]
                        guard v > threshold, clear[i], x > 1, y > 1, x < w - 2, y < h - 2 else { continue }
                        var isMax = true
                        for dy in -2...2 where isMax {
                            for dx in -2...2 where (dx != 0 || dy != 0) && response[i + dy * w + dx] > v {
                                isMax = false
                                break
                            }
                        }
                        if isMax { candidates.append((v, x, y)) }
                    }
                }
                candidates.sort { $0.0 > $1.0 }
                chosen += candidates.prefix(cornersPerCell).map { ($0.1, $0.2) }
            }
        }

        var points: [SIMD2<Double>] = []
        var descriptors: [Float] = []
        let side = descriptorSide, stride = descriptorStride
        let half = Float(side - 1) * Float(stride) / 2
        let span = Double(thumbnail.span)
        var patch = [Float](repeating: 0, count: side * side)
        for corner in chosen {
            // Samples centred on the corner texel, bilinear between texels.
            var sum: Float = 0
            for sy in 0..<side {
                for sx in 0..<side {
                    let px = Float(corner.x) - half + Float(sx * stride)
                    let py = Float(corner.y) - half + Float(sy * stride)
                    let ix = Int(px.rounded(.down)), iy = Int(py.rounded(.down))
                    let fx = px - Float(ix), fy = py - Float(iy)
                    let x0 = min(max(ix, 0), w - 1), x1 = min(max(ix + 1, 0), w - 1)
                    let y0 = min(max(iy, 0), h - 1), y1 = min(max(iy + 1, 0), h - 1)
                    let v = (1 - fx) * (1 - fy) * descriptorSource[y0 * w + x0] + fx * (1 - fy) * descriptorSource[y0 * w + x1]
                        + (1 - fx) * fy * descriptorSource[y1 * w + x0] + fx * fy * descriptorSource[y1 * w + x1]
                    patch[sy * side + sx] = v
                    sum += v
                }
            }
            let mean = sum / Float(side * side)
            var length: Float = 0
            for k in patch.indices { patch[k] -= mean; length += patch[k] * patch[k] }
            length = length.squareRoot()
            // A patch with almost no contrast (smooth sky) can't be told
            // from its neighbours: a twentieth of a stop, root-mean-square.
            guard length / Float(side) > 0.05 else { continue }
            for k in patch.indices { patch[k] /= length }
            descriptors += patch
            points.append(SIMD2((Double(corner.x) + 0.5) * span, (Double(corner.y) + 0.5) * span))
        }
        return PanoramaFeatureSet(points: points, descriptors: descriptors)
    }

    /// `plane` blurred by a Gaussian of `sigma` texels, edges repeated.
    static func blur(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        for k in kernel.indices { kernel[k] /= total }
        var input = plane
        var middle = [Float](repeating: 0, count: plane.count)
        var output = [Float](repeating: 0, count: plane.count)
        let flags = vImage_Flags(kvImageEdgeExtend)
        input.withUnsafeMutableBufferPointer { src in
            middle.withUnsafeMutableBufferPointer { mid in
                output.withUnsafeMutableBufferPointer { dst in
                    var source = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(height),
                                               width: vImagePixelCount(width), rowBytes: width * 4)
                    var between = vImage_Buffer(data: mid.baseAddress, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width * 4)
                    var destination = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width), rowBytes: width * 4)
                    kernel.withUnsafeBufferPointer { k in
                        _ = vImageConvolve_PlanarF(&source, &between, nil, 0, 0, k.baseAddress!, 1,
                                                   UInt32(kernel.count), 0, flags)
                        _ = vImageConvolve_PlanarF(&between, &destination, nil, 0, 0, k.baseAddress!,
                                                   UInt32(kernel.count), 1, 0, flags)
                    }
                }
            }
        }
        return output
    }

    // MARK: - Matching

    /// Pairs (index in `a`, index in `b`) that are each other's best match
    /// and pass the ratio test.
    static func match(_ a: PanoramaFeatureSet, _ b: PanoramaFeatureSet) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n >= 2, m >= 2 else { return [] }
        let d = descriptorLength
        // Every correlation: a (n x d) times b transposed (d x m).
        var scores = [Float](repeating: 0, count: n * m)
        var transposed = [Float](repeating: 0, count: d * m)
        vDSP_mtrans(b.descriptors, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(m))
        vDSP_mmul(a.descriptors, 1, transposed, 1, &scores, 1, vDSP_Length(n), vDSP_Length(m), vDSP_Length(d))
        // Squared distance between unit vectors is 2 - 2 x correlation.
        var bestInB = [(index: Int, first: Float, second: Float)](repeating: (-1, 4, 4), count: n)
        var bestInA = [(index: Int, first: Float)](repeating: (-1, 4), count: m)
        for i in 0..<n {
            for j in 0..<m {
                let distance = 2 - 2 * scores[i * m + j]
                if distance < bestInB[i].first {
                    bestInB[i] = (j, distance, bestInB[i].first)
                } else if distance < bestInB[i].second {
                    bestInB[i].second = distance
                }
                if distance < bestInA[j].first { bestInA[j] = (i, distance) }
            }
        }
        var pairs: [(Int, Int)] = []
        let ratioSquared = ratio * ratio
        for i in 0..<n {
            let best = bestInB[i]
            guard best.index >= 0, bestInA[best.index].index == i,
                  best.first < ratioSquared * best.second else { continue }
            pairs.append((i, best.index))
        }
        return pairs
    }

    // MARK: - RANSAC for a rotation

    /// What RANSAC found: the rotation taking rays of the first photo to
    /// rays of the second, and the matches it explains.
    struct RotationFit {
        var rotation: simd_double3x3
        /// Indices into the matches handed in.
        var inliers: [Int]
        /// Root-mean-square distance of the inliers from where the rotation
        /// puts them, in full-resolution pixels.
        var rmsError: Double
    }

    /// The rotation most matches agree with, for two photos of focal length
    /// `focal` (full-resolution pixels) with principal points `centreA` and
    /// `centreB`.
    ///
    /// - Parameter tolerance: how far (full-resolution pixels) a match may
    ///   land from where a rotation puts it and still agree.
    static func fitRotation(pointsA: [SIMD2<Double>], pointsB: [SIMD2<Double>], focal: Double,
                            centreA: SIMD2<Double>, centreB: SIMD2<Double>, tolerance: Double,
                            iterations: Int = 1000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> RotationFit? {
        let count = pointsA.count
        guard count >= 2 else { return nil }
        func ray(_ p: SIMD2<Double>, _ c: SIMD2<Double>) -> SIMD3<Double> {
            simd_normalize(SIMD3((p.x - c.x) / focal, (p.y - c.y) / focal, 1))
        }
        let raysA = pointsA.map { ray($0, centreA) }, raysB = pointsB.map { ray($0, centreB) }
        func errors(_ r: simd_double3x3) -> [Double] {
            (0..<count).map { k in
                let q = r * raysA[k]
                guard q.z > 1e-6 else { return .infinity }
                return simd_distance(SIMD2(focal * q.x / q.z, focal * q.y / q.z) + centreB, pointsB[k])
            }
        }
        var generator = PanoramaRandom(seed: seed)
        var best: (rotation: simd_double3x3, inliers: [Int])?
        for _ in 0..<iterations {
            let i = Int(generator.next() % UInt64(count))
            var j = Int(generator.next() % UInt64(count - 1))
            if j >= i { j += 1 }
            // Two rays pointing almost the same way fix no rotation about them.
            guard simd_dot(raysA[i], raysA[j]) < 0.99995 else { continue }
            let r = PanoramaRotation.fit(from: [raysA[i], raysA[j]], to: [raysB[i], raysB[j]])
            let e = errors(r)
            let inliers = e.indices.filter { e[$0] < tolerance }
            if inliers.count > (best?.inliers.count ?? 1) { best = (r, inliers) }
        }
        guard var found = best else { return nil }
        // Refit to every inlier, and take the matches the refit agrees with.
        for _ in 0..<3 {
            let r = PanoramaRotation.fit(from: found.inliers.map { raysA[$0] }, to: found.inliers.map { raysB[$0] })
            let e = errors(r)
            let inliers = e.indices.filter { e[$0] < tolerance }
            guard inliers.count >= found.inliers.count else { break }
            found = (r, inliers)
        }
        let e = errors(found.rotation)
        let rms = (found.inliers.map { e[$0] * e[$0] }.reduce(0, +) / Double(max(found.inliers.count, 1))).squareRoot()
        return RotationFit(rotation: found.rotation, inliers: found.inliers, rmsError: rms)
    }
}

/// A small, fast, reproducible random number generator (Steele, Lea and
/// Flood's SplitMix64), so RANSAC finds the same answer every run.
struct PanoramaRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
