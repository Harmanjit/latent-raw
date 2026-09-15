import Accelerate
import Foundation
import simd

/// Refines a homography until the moving frame, warped by it, matches the
/// reference as closely as possible.
///
/// **What is minimised.** For every usable reference pixel p, the moving
/// frame is sampled where the homography sends p, and the difference
///
///     e(p) = alpha * moving(M p) + beta - reference(p)
///
/// is squared and summed. `alpha` and `beta` are a contrast and brightness
/// correction solved for alongside the geometry: the frames are log images
/// divided by their exposure, so what's left of an exposure mismatch is a
/// constant offset, and a mismatch left in the image would otherwise drag
/// the geometry to compensate. This is the idea behind ECC (the "enhanced
/// correlation coefficient" of Evangelidis and Psarakis, 2008): a match
/// score that ignores brightness and contrast. The Phase 0 spike measured
/// corner errors under 0.1 px with it, even 8 stops apart.
///
/// **How.** Gauss-Newton: near the answer, e changes almost linearly with
/// the ten parameters (eight of the homography, alpha and beta), so one
/// linear least-squares solve gives the step to take; repeat until the
/// step is tiny. The derivative of e by the homography's parameters is the
/// moving frame's gradient times how the sample point moves with each
/// parameter (the chain rule), precomputed gradients making it cheap.
///
/// **Conditioning.** Pixel coordinates run into the thousands while a
/// homography's perspective terms are around 1e-4, and a solve mixing them
/// loses precision. So the parameters are expressed in normalised
/// coordinates, centred on each image with its half-width as the unit.
enum ECCRefinement {
    struct Outcome {
        /// Reference level pixels -> moving level pixels.
        var referenceToMoving: simd_double3x3
        var alpha: Double
        var beta: Double
        /// The last step moved the corners less than the stopping step.
        var converged: Bool
        var iterations: Int
        /// Pixels in the last solve.
        var samples: Int
    }

    /// A step moving the corners less than this (level pixels) ends the
    /// refinement at the finest level...
    static let convergedStep = 0.002
    /// ...and this at the coarser ones, whose answer the next level refines
    /// anyway: polishing it further only costs iterations.
    static let coarseConvergedStep = 0.02
    /// Fewer usable samples than this and a solve isn't trusted.
    static let minimumSamples = 500

    /// Precomputed central-difference gradients of a masked plane, per
    /// index unit. NaN wherever a neighbour is NaN, and on the border.
    struct Gradients {
        let x: [Float]
        let y: [Float]

        init(_ plane: AlignmentPlane) {
            let w = plane.width, h = plane.height
            var gx = [Float](repeating: .nan, count: w * h), gy = [Float](repeating: .nan, count: w * h)
            plane.values.withUnsafeBufferPointer { src in
                gx.withUnsafeMutableBufferPointer { ox in
                    gy.withUnsafeMutableBufferPointer { oy in
                        let s = src.baseAddress!, px = ox.baseAddress!, py = oy.baseAddress!
                        let bands = AlignmentSampling.bandCount(rows: h)
                        AlignmentSampling.parallel(bands) { band in
                            for j in max(1, band * h / bands)..<min(h - 1, (band + 1) * h / bands) {
                                for i in 1..<(w - 1) {
                                    let k = j * w + i
                                    px[k] = 0.5 * (s[k + 1] - s[k - 1])
                                    py[k] = 0.5 * (s[k + w] - s[k - w])
                                }
                            }
                        }
                    }
                }
            }
            x = gx
            y = gy
        }
    }

    /// Maps pixel coordinates of a `width x height` image to normalised
    /// ones: centred, with half the width as the unit.
    static func normaliser(width: Int, height: Int) -> simd_double3x3 {
        let s = Double(width) / 2
        return simd_double3x3(rows: [SIMD3(1 / s, 0, -1), SIMD3(0, 1 / s, -Double(height) / Double(width)),
                                     SIMD3(0, 0, 1)])
    }

    /// How many pixels to step over in each direction so a solve sees
    /// about 600,000 samples: more adds time without adding accuracy (the
    /// spike used about 760,000 at 3200 px).
    static func sampleStep(width: Int, height: Int) -> Int {
        max(1, Int((Double(width * height) / 600_000).squareRoot().rounded()))
    }

    /// Refines `start` (reference level pixels -> moving level pixels).
    ///
    /// - Parameters:
    ///   - reference, moving: masked planes (NaN where unusable).
    ///   - gradients: `moving`'s gradients.
    ///   - robust: down-weight pixels that disagree far more than most
    ///     (a moving branch, a person walking), so they pull the fit less.
    ///   - stopStep: a step moving the corners less than this many level
    ///     pixels ends the refinement.
    static func refine(reference a: AlignmentPlane, moving b: AlignmentPlane, gradients: Gradients,
                       start: simd_double3x3, alpha startAlpha: Double, beta startBeta: Double,
                       maxIterations: Int, robust: Bool, stopStep: Double = convergedStep) -> Outcome {
        let na = normaliser(width: a.width, height: a.height), nb = normaliser(width: b.width, height: b.height)
        var g = Homography.normalised(nb * start * na.inverse)
        var alpha = startAlpha, beta = startBeta
        var outcome = Outcome(referenceToMoving: start, alpha: alpha, beta: beta, converged: false, iterations: 0,
                              samples: 0)
        let step = sampleStep(width: a.width, height: a.height)
        let aspect = Double(a.height) / Double(a.width)
        var robustLimit = Double.infinity

        for iteration in 0..<maxIterations {
            guard let sums = accumulate(a, b, gradients, g: g, alpha: alpha, beta: beta, step: step,
                                        limit: robustLimit) else { break }
            outcome.samples = Int(sums.samples)
            guard outcome.samples >= minimumSamples, let delta = solve(sums.normal, sums.rhs.map { -$0 }, 10) else { break }

            // The rows of the normalised homography, updated by the step.
            let r0 = g.transpose[0], r1 = g.transpose[1], r2 = g.transpose[2]
            let updated = simd_double3x3(rows: [SIMD3(r0.x + delta[0], r0.y + delta[1], r0.z + delta[2]),
                                                SIMD3(r1.x + delta[3], r1.y + delta[4], r1.z + delta[5]),
                                                SIMD3(r2.x + delta[6], r2.y + delta[7], 1)])
            guard Homography.isUsable(updated), (alpha + delta[8]).isFinite, (beta + delta[9]).isFinite else { break }
            // How far the step moved the corners, in moving level pixels.
            let movedPixels = cornerStep(g, updated, aspect: aspect) * Double(b.width) / 2
            g = updated
            alpha += delta[8]
            beta += delta[9]
            outcome.iterations = iteration + 1
            outcome.referenceToMoving = Homography.normalised(nb.inverse * g * na)
            outcome.alpha = alpha
            outcome.beta = beta
            if robust {
                // Huber's limit: 1.345 times the noise level keeps 95% of
                // plain least squares' precision when nothing moved. The
                // mean |e| times 1.2533 estimates that level for Gaussian
                // noise, and is less swayed by a few gross mismatches than
                // the root mean square would be.
                robustLimit = 1.345 * 1.2533 * sums.absoluteSum / sums.samples
            }
            if movedPixels < stopStep {
                outcome.converged = true
                break
            }
        }
        return outcome
    }

    /// The normal equations of one Gauss-Newton step: JᵀWJ (10 x 10, row
    /// by row), JᵀWe, the sample count and the sum of |e|. Nil when there
    /// is nothing to sum.
    ///
    /// Each image row's samples are gathered into columns first, one per
    /// parameter, and the sums of products come from Accelerate's dot
    /// products: 65 calls per row instead of 55 multiply-adds per sample.
    private static func accumulate(_ a: AlignmentPlane, _ b: AlignmentPlane, _ gradients: Gradients,
                                   g: simd_double3x3, alpha: Double, beta: Double, step: Int, limit: Double)
    -> (normal: [Double], rhs: [Double], samples: Double, absoluteSum: Double)? {
        let rows = (a.height + step - 1) / step
        let bands = AlignmentSampling.bandCount(rows: rows)
        // Per band: 100 (normal matrix), 10 (right-hand side), samples, sum |e|.
        let stride = 112
        var sums = [Double](repeating: 0, count: bands * stride)
        let m = g.transpose
        let (h0, h1, h2) = (m[0].x, m[0].y, m[0].z)
        let (h3, h4, h5) = (m[1].x, m[1].y, m[1].z)
        let (h6, h7) = (m[2].x, m[2].y)
        let aw = a.width, bw = b.width
        let sa = Double(aw) / 2, sb = Double(bw) / 2
        let aOffsetY = Double(a.height) / Double(aw), bOffsetY = Double(b.height) / Double(bw)
        // Samples stay a pixel inside the moving plane, so the bilinear
        // sample's neighbours all exist.
        let maxX = Double(bw) - 2.001, maxY = Double(b.height) - 2.001
        let capacity = aw / step + 1
        a.values.withUnsafeBufferPointer { aBuffer in
            b.values.withUnsafeBufferPointer { bBuffer in
                gradients.x.withUnsafeBufferPointer { gxBuffer in
                    gradients.y.withUnsafeBufferPointer { gyBuffer in
                        sums.withUnsafeMutableBufferPointer { sumsBuffer in
                            let ap = aBuffer.baseAddress!, bp = bBuffer.baseAddress!
                            let gxp = gxBuffer.baseAddress!, gyp = gyBuffer.baseAddress!
                            let all = sumsBuffer.baseAddress!
                            AlignmentSampling.parallel(bands) { band in
                                let out = all + band * stride
                                // Columns 0-9: the Jacobian's entries; 10: the error.
                                // Both scaled by the square root of the sample's weight.
                                let columns = UnsafeMutablePointer<Double>.allocate(capacity: capacity * 11)
                                defer { columns.deallocate() }
                                var samples = 0.0, absoluteSum = 0.0
                                for r in (band * rows / bands)..<((band + 1) * rows / bands) {
                                    let j = r * step
                                    let v = (Double(j) + 0.5) / sa - aOffsetY
                                    var n = 0
                                    var i = 0
                                    while i < aw {
                                        let va = ap[j * aw + i]
                                        let u = (Double(i) + 0.5) / sa - 1
                                        i += step
                                        if va.isNaN { continue }
                                        let z = h6 * u + h7 * v + 1
                                        if !(z > 1e-6) { continue }
                                        let qx = (h0 * u + h1 * v + h2) / z, qy = (h3 * u + h4 * v + h5) / z
                                        let bx = (qx + 1) * sb - 0.5, by = (qy + bOffsetY) * sb - 0.5
                                        if !(bx >= 1 && by >= 1 && bx < maxX && by < maxY) { continue }
                                        // Bilinear samples of the moving plane and its gradients.
                                        let ix = Int(bx), iy = Int(by)
                                        let fx = Float(bx - Double(ix)), fy = Float(by - Double(iy))
                                        let k = iy * bw + ix
                                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
                                        let w01 = (1 - fx) * fy, w11 = fx * fy
                                        let vb = w00 * bp[k] + w10 * bp[k + 1] + w01 * bp[k + bw] + w11 * bp[k + bw + 1]
                                        if vb.isNaN { continue }
                                        let gx = w00 * gxp[k] + w10 * gxp[k + 1] + w01 * gxp[k + bw] + w11 * gxp[k + bw + 1]
                                        let gy = w00 * gyp[k] + w10 * gyp[k + 1] + w01 * gyp[k + bw] + w11 * gyp[k + bw + 1]
                                        if gx.isNaN || gy.isNaN { continue }
                                        let e = alpha * Double(vb) + beta - Double(va)
                                        // Huber weighting: full weight up to the limit, then
                                        // falling as 1/|e|, so a gross mismatch counts like a
                                        // merely large one.
                                        let magnitude = abs(e)
                                        let root = magnitude <= limit ? 1 : (limit / magnitude).squareRoot()
                                        let gxa = alpha * Double(gx) * sb / z * root
                                        let gya = alpha * Double(gy) * sb / z * root
                                        let perspective = -(gxa * qx + gya * qy)
                                        columns[n] = gxa * u
                                        columns[capacity + n] = gxa * v
                                        columns[2 * capacity + n] = gxa
                                        columns[3 * capacity + n] = gya * u
                                        columns[4 * capacity + n] = gya * v
                                        columns[5 * capacity + n] = gya
                                        columns[6 * capacity + n] = perspective * u
                                        columns[7 * capacity + n] = perspective * v
                                        columns[8 * capacity + n] = Double(vb) * root
                                        columns[9 * capacity + n] = root
                                        columns[10 * capacity + n] = e * root
                                        n += 1
                                        absoluteSum += magnitude
                                    }
                                    guard n > 0 else { continue }
                                    samples += Double(n)
                                    let length = vDSP_Length(n)
                                    var product = 0.0
                                    for p in 0..<10 {
                                        for q in p..<10 {
                                            vDSP_dotprD(columns + p * capacity, 1, columns + q * capacity, 1, &product, length)
                                            out[p * 10 + q] += product
                                        }
                                        vDSP_dotprD(columns + p * capacity, 1, columns + 10 * capacity, 1, &product, length)
                                        out[100 + p] += product
                                    }
                                }
                                out[110] = samples
                                out[111] = absoluteSum
                            }
                        }
                    }
                }
            }
        }
        var normal = [Double](repeating: 0, count: 100), rhs = [Double](repeating: 0, count: 10)
        var samples = 0.0, absoluteSum = 0.0
        for band in 0..<bands {
            let base = band * stride
            for p in 0..<10 {
                for q in p..<10 { normal[p * 10 + q] += sums[base + p * 10 + q] }
                rhs[p] += sums[base + 100 + p]
            }
            samples += sums[base + 110]
            absoluteSum += sums[base + 111]
        }
        guard samples > 0 else { return nil }
        for p in 0..<10 { for q in 0..<p { normal[p * 10 + q] = normal[q * 10 + p] } }
        return (normal, rhs, samples, absoluteSum)
    }

    /// How far two normalised-coordinate homographies put the reference's
    /// corners apart, in the moving frame's normalised units (half-widths).
    private static func cornerStep(_ a: simd_double3x3, _ b: simd_double3x3, aspect: Double) -> Double {
        var worst = 0.0
        for corner in [SIMD2(-1.0, -aspect), SIMD2(1.0, -aspect), SIMD2(-1.0, aspect), SIMD2(1.0, aspect)] {
            worst = max(worst, simd_distance(Homography.apply(a, corner), Homography.apply(b, corner)))
        }
        return worst
    }

    /// Solves the n x n system m x = v by Gaussian elimination with partial
    /// pivoting; nil when it is singular.
    static func solve(_ m: [Double], _ v: [Double], _ n: Int) -> [Double]? {
        var a = m, b = v
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<n where abs(a[r * n + c]) > abs(a[p * n + c]) { p = r }
            guard abs(a[p * n + c]) > 1e-12 else { return nil }
            if p != c {
                for k in 0..<n { a.swapAt(c * n + k, p * n + k) }
                b.swapAt(c, p)
            }
            for r in (c + 1)..<n {
                let f = a[r * n + c] / a[c * n + c]
                if f == 0 { continue }
                for k in c..<n { a[r * n + k] -= f * a[c * n + k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n { s -= a[r * n + k] * x[k] }
            x[r] = s / a[r * n + r]
        }
        guard x.allSatisfy(\.isFinite) else { return nil }
        return x
    }
}
