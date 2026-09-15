// Checking whether a bracket's frames line up, so v1 (which doesn't align
// them) can say when the result may show double edges.

import Accelerate
import Foundation

/// Finds the shift between two neighbouring frames by phase correlation,
/// ported from the Phase 0 alignment spike (~/latent-wt/spikes/vision,
/// TwoStage.swift), which found it reliable on real brackets 8 stops apart.
///
/// **Phase correlation.** Shifting an image doesn't change the strength of
/// its frequencies (the magnitudes of its Fourier transform), only their
/// phases, by an amount proportional to the shift. So divide one image's
/// spectrum by the other's, keep only the phase differences (every
/// magnitude set to 1) and transform back: what comes out is almost zero
/// everywhere except a sharp peak at the shift. Brightness differences
/// between the frames change magnitudes, not phases, which is why it copes
/// with exposure differences that defeat plain correlation.
///
/// **Input**, as the spike found works: each frame's brightness divided by
/// its exposure (so both describe the same scene light), clamped to the
/// range both frames record well (above the darker frame's noise, below
/// the brighter frame's clipping) and taken as log2, so a shadow edge
/// counts as much as a highlight edge.
enum HDRAlignmentCheck {
    /// The shift of `darker` relative to `brighter`, in the analysis
    /// frames' pixels (multiply by `span` for full resolution): where a
    /// feature at (x, y) in `brighter` is found in `darker`. `peak` is the
    /// correlation peak's height, about 1 for a perfect match and near 0
    /// for no match; nil when the frames are too small or too different to say.
    struct Shift: Equatable {
        let dx: Double
        let dy: Double
        let peak: Double
        var length: Double { (dx * dx + dy * dy).squareRoot() }
    }

    /// A peak lower than this means the frames share too little usable
    /// detail to judge, and no warning is given either way.
    static let minimumPeak = 0.02

    /// The two frames as the correlation compares them (see the type's notes).
    static func matchedLogLuminance(brighter: HDRAnalysisFrame, brighterEV: Double,
                                    darker: HDRAnalysisFrame, darkerEV: Double) -> ([Double], [Double]) {
        let count = brighter.width * brighter.height
        let gainA = pow(2, -brighterEV), gainB = pow(2, -darkerEV)
        let clipA = Double(brighter.channelClip.x + brighter.channelClip.y + brighter.channelClip.z)
        let high = log2(0.9 * clipA * gainA)
        let low = log2(0.01 * gainB)
        var a = [Double](repeating: 0, count: count), b = [Double](repeating: 0, count: count)
        guard high > low else { return (a, b) }
        let pa = brighter.pixels, pb = darker.pixels
        for i in 0..<count {
            // A clipped block sits at the top of the range. Each frame is
            // judged on its own clipping only: marking a block clipped in
            // both images whenever either frame clipped it would stamp the
            // same mask on both, a feature that doesn't move when the
            // scene does, and the correlation would find it at no shift.
            // (Where the brighter frame clipped, the darker frame's own
            // value is above the range and clamps to the top anyway.)
            let la = log2(max(Double(pa[i * 4] + pa[i * 4 + 1] + pa[i * 4 + 2]) * gainA, 1e-12))
            let lb = log2(max(Double(pb[i * 4] + pb[i * 4 + 1] + pb[i * 4 + 2]) * gainB, 1e-12))
            a[i] = pa[i * 4 + 3] > 0 ? high : min(max(la, low), high)
            b[i] = pb[i * 4 + 3] > 0 ? high : min(max(lb, low), high)
        }
        return (a, b)
    }

    /// Phase correlation of two same-sized images, with the peak located to
    /// a fraction of a pixel. Searches shifts up to a quarter of the image
    /// each way, far beyond what a tripod bracket moves.
    static func shift(_ a: [Double], _ b: [Double], width: Int, height: Int) -> Shift? {
        guard width >= 16, height >= 16, a.count == width * height, b.count == a.count else { return nil }
        var log2n = 4
        while (1 << log2n) < max(width, height) { log2n += 1 }
        guard log2n <= 12 else { return nil }
        let n = 1 << log2n
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetupD(setup) }

        // A Tukey window (flat, with a 10% cosine taper at each side) stops
        // the image's own edges, which don't move with the scene, from
        // becoming the strongest feature.
        func taper(_ i: Int, _ length: Int) -> Double {
            let t = Double(i) / Double(max(1, length - 1)), edge = 0.1
            if t < edge { return 0.5 - 0.5 * cos(.pi * t / edge) }
            if t > 1 - edge { return 0.5 - 0.5 * cos(.pi * (1 - t) / edge) }
            return 1
        }
        let rowWeights = (0..<height).map { taper($0, height) }
        let columnWeights = (0..<width).map { taper($0, width) }

        // The image, mean removed and windowed, in the corner of an n x n canvas.
        func canvas(_ image: [Double]) -> [Double] {
            var mean = 0.0
            vDSP_meanvD(image, 1, &mean, vDSP_Length(image.count))
            var out = [Double](repeating: 0, count: n * n)
            for y in 0..<height {
                let wy = rowWeights[y]
                for x in 0..<width {
                    out[y * n + x] = (image[y * width + x] - mean) * wy * columnWeights[x]
                }
            }
            return out
        }

        // The 2-D transform as 1-D transforms of every row, then every
        // column, as the spike did: it found vDSP's 2-D routine gave wrong peaks.
        func transform(_ real: inout [Double], _ imaginary: inout [Double], _ direction: FFTDirection) {
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    guard let reBase = re.baseAddress, let imBase = im.baseAddress else { return }
                    for row in 0..<n {
                        var split = DSPDoubleSplitComplex(realp: reBase + row * n, imagp: imBase + row * n)
                        vDSP_fft_zipD(setup, &split, 1, vDSP_Length(log2n), direction)
                    }
                    for column in 0..<n {
                        var split = DSPDoubleSplitComplex(realp: reBase + column, imagp: imBase + column)
                        vDSP_fft_zipD(setup, &split, vDSP_Stride(n), vDSP_Length(log2n), direction)
                    }
                }
            }
        }

        var aReal = canvas(a), aImag = [Double](repeating: 0, count: n * n)
        var bReal = canvas(b), bImag = [Double](repeating: 0, count: n * n)
        transform(&aReal, &aImag, FFTDirection(kFFTDirection_Forward))
        transform(&bReal, &bImag, FFTDirection(kFFTDirection_Forward))

        // The cross-power spectrum B x conj(A), every magnitude set to 1.
        var real = [Double](repeating: 0, count: n * n), imag = [Double](repeating: 0, count: n * n)
        for k in 0..<(n * n) {
            let re = bReal[k] * aReal[k] + bImag[k] * aImag[k]
            let im = bImag[k] * aReal[k] - bReal[k] * aImag[k]
            let magnitude = (re * re + im * im).squareRoot()
            guard magnitude > 1e-12 else { continue }
            real[k] = re / magnitude
            imag[k] = im / magnitude
        }
        transform(&real, &imag, FFTDirection(kFFTDirection_Inverse))

        // The strongest value within the search window; shifts wrap around,
        // so row n - 1 is a shift of -1.
        let reach = n / 4
        var best = -Double.infinity, bestX = 0, bestY = 0
        for dy in -reach...reach {
            let row = (dy + n) % n
            for dx in -reach...reach {
                let v = real[row * n + (dx + n) % n]
                if v > best { best = v; bestX = dx; bestY = dy }
            }
        }
        func value(_ dx: Int, _ dy: Int) -> Double { real[((dy + n) % n) * n + (dx + n) % n] }
        // A parabola through the peak and its two neighbours on each axis
        // puts the peak between pixels.
        func refine(_ minus: Double, _ centre: Double, _ plus: Double) -> Double {
            let curvature = minus - 2 * centre + plus
            guard curvature < -1e-12 else { return 0 }
            return max(-0.5, min(0.5, 0.5 * (minus - plus) / curvature))
        }
        let fx = refine(value(bestX - 1, bestY), best, value(bestX + 1, bestY))
        let fy = refine(value(bestX, bestY - 1), best, value(bestX, bestY + 1))

        // vDSP's transforms aren't normalised: forward then inverse scales
        // by n on each axis, so a perfect match's peak is n².
        let peak = best / Double(n * n)
        return Shift(dx: Double(bestX) + fx, dy: Double(bestY) + fy, peak: peak)
    }
}
