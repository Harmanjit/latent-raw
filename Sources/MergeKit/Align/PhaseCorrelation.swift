import Accelerate
import Foundation

/// The aligner's first guess: how far one frame is shifted from the other,
/// found by phase correlation.
///
/// **Phase correlation.** Shifting an image doesn't change the strength of
/// its frequencies (the magnitudes of its Fourier transform), only their
/// phases, by an amount proportional to the shift. So divide one image's
/// spectrum by the other's, keep only the phase differences (every
/// magnitude set to 1) and transform back: what comes out is almost zero
/// everywhere except a sharp peak at the shift. It finds shifts of any size
/// in one step, and brightness differences change magnitudes rather than
/// phases, so exposure differences don't fool it.
///
/// **Why several peaks.** The transform treats the image as repeating, so
/// a peak at (dx, dy) could equally mean (dx - n, dy) and so on; and with a
/// small overlap (a panorama) or repetitive detail the true peak isn't
/// always the tallest. The strongest few peaks and each of their
/// wrap-around readings are handed back; `FrameAligner` keeps the one whose
/// overlap actually matches best. HDRAlignmentCheck (HDR/) does a
/// single-peak version of this for v1's misalignment warning.
enum PhaseCorrelation {
    /// A possible shift, in the level's pixels: a feature at p in the
    /// reference appears at p + (dx, dy) in the moving frame.
    struct Candidate: Equatable {
        let dx: Double
        let dy: Double
        /// The correlation peak's height, about 1 for a perfect match.
        let peak: Double
    }

    /// Peaks closer than this (in pixels) to a stronger one are its shoulders.
    static let peakSeparation = 5

    /// The shift candidates between two same-sized clamped planes, strongest
    /// peak first, each peak in all its wrap-around readings that leave the
    /// images overlapping at all. Fractions of a pixel come from a parabola
    /// through each peak and its neighbours.
    static func candidates(reference a: AlignmentPlane, moving b: AlignmentPlane, peaks: Int = 5) -> [Candidate] {
        let width = max(a.width, b.width), height = max(a.height, b.height)
        guard a.width >= 16, a.height >= 16, b.width >= 16, b.height >= 16 else { return [] }
        var log2n = 4
        while (1 << log2n) < max(width, height) { log2n += 1 }
        guard log2n <= 12, let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let n = 1 << log2n

        var aReal = canvas(a, n: n), aImag = [Float](repeating: 0, count: n * n)
        var bReal = canvas(b, n: n), bImag = [Float](repeating: 0, count: n * n)
        transform(&aReal, &aImag, n: n, log2n: log2n, setup: setup, direction: FFTDirection(kFFTDirection_Forward))
        transform(&bReal, &bImag, n: n, log2n: log2n, setup: setup, direction: FFTDirection(kFFTDirection_Forward))

        // The cross-power spectrum B x conj(A), every magnitude set to 1:
        // re = bR aR + bI aI, im = bI aR - bR aI, each divided by |(re, im)|.
        let count = vDSP_Length(n * n)
        var real = [Float](repeating: 0, count: n * n), imag = [Float](repeating: 0, count: n * n)
        var scratch = [Float](repeating: 0, count: n * n)
        vDSP_vmul(bReal, 1, aReal, 1, &real, 1, count)
        vDSP_vmul(bImag, 1, aImag, 1, &scratch, 1, count)
        vDSP_vadd(real, 1, scratch, 1, &real, 1, count)
        vDSP_vmul(bImag, 1, aReal, 1, &imag, 1, count)
        vDSP_vmul(bReal, 1, aImag, 1, &scratch, 1, count)
        vDSP_vsub(scratch, 1, imag, 1, &imag, 1, count) // imag - scratch
        aReal = []; aImag = []; bReal = []; bImag = []
        var magnitude = [Float](repeating: 0, count: n * n)
        vDSP_vdist(real, 1, imag, 1, &magnitude, 1, count)
        // A zero magnitude (no signal at that frequency) stays zero.
        var tiny: Float = 1e-20
        vDSP_vthr(magnitude, 1, &tiny, &magnitude, 1, count)
        // (vDSP_vdiv(b, a) computes a / b.)
        vDSP_vdiv(magnitude, 1, real, 1, &real, 1, count)
        vDSP_vdiv(magnitude, 1, imag, 1, &imag, 1, count)
        scratch = []; magnitude = []
        transform(&real, &imag, n: n, log2n: log2n, setup: setup, direction: FFTDirection(kFFTDirection_Inverse))

        // The strongest local maxima (8 neighbours, wrapping around),
        // looked for only among values that could make the list.
        var best: [(x: Int, y: Int, v: Float)] = []
        var threshold = -Float.greatestFiniteMagnitude
        real.withUnsafeBufferPointer { buffer in
            let r = buffer.baseAddress!
            for y in 0..<n {
                let up = (y + n - 1) % n * n, here = y * n, down = (y + 1) % n * n
                for x in 0..<n {
                    let v = r[here + x]
                    if v <= threshold { continue }
                    let left = (x + n - 1) % n, right = (x + 1) % n
                    if r[up + left] > v || r[up + x] > v || r[up + right] > v || r[here + left] > v
                        || r[here + right] > v || r[down + left] > v || r[down + x] > v || r[down + right] > v {
                        continue
                    }
                    best.append((x, y, v))
                    best.sort { $0.v > $1.v }
                    if best.count > 4 * peaks {
                        best.removeLast()
                        threshold = best[best.count - 1].v
                    }
                }
            }
        }
        func value(_ x: Int, _ y: Int) -> Float { real[((y % n + n) % n) * n + (x % n + n) % n] }
        var chosen: [(x: Int, y: Int, v: Float)] = []
        for p in best where chosen.count < peaks {
            let far = chosen.allSatisfy { q in
                let ddx = min(abs(p.x - q.x), n - abs(p.x - q.x)), ddy = min(abs(p.y - q.y), n - abs(p.y - q.y))
                return ddx > peakSeparation || ddy > peakSeparation
            }
            if far { chosen.append(p) }
        }

        // A parabola through the peak and its two neighbours on each axis
        // puts the peak between pixels.
        func refine(_ minus: Float, _ centre: Float, _ plus: Float) -> Double {
            let curvature = Double(minus) - 2 * Double(centre) + Double(plus)
            guard curvature < -1e-12 else { return 0 }
            return max(-0.5, min(0.5, 0.5 * (Double(minus) - Double(plus)) / curvature))
        }
        var out: [Candidate] = []
        for p in chosen {
            let fx = refine(value(p.x - 1, p.y), p.v, value(p.x + 1, p.y))
            let fy = refine(value(p.x, p.y - 1), p.v, value(p.x, p.y + 1))
            for dy in [p.y, p.y - n] where abs(dy) < min(a.height, b.height) {
                for dx in [p.x, p.x - n] where abs(dx) < min(a.width, b.width) {
                    out.append(Candidate(dx: Double(dx) + fx, dy: Double(dy) + fy, peak: Double(p.v)))
                }
            }
        }
        return out
    }

    /// The plane, mean removed and windowed, in the top-left corner of an
    /// n x n canvas. The window (flat, with a 10% cosine taper at each
    /// side) stops the image's own edges, which don't move with the scene,
    /// from becoming the strongest feature.
    private static func canvas(_ plane: AlignmentPlane, n: Int) -> [Float] {
        func taper(_ i: Int, _ length: Int) -> Float {
            let t = Float(i) / Float(max(1, length - 1)), edge: Float = 0.1
            if t < edge { return 0.5 - 0.5 * cos(.pi * t / edge) }
            if t > 1 - edge { return 0.5 - 0.5 * cos(.pi * (1 - t) / edge) }
            return 1
        }
        var mean: Float = 0
        vDSP_meanv(plane.values, 1, &mean, vDSP_Length(plane.values.count))
        let columns = (0..<plane.width).map { taper($0, plane.width) }
        var out = [Float](repeating: 0, count: n * n)
        for y in 0..<plane.height {
            let wy = taper(y, plane.height)
            for x in 0..<plane.width {
                out[y * n + x] = (plane.values[y * plane.width + x] - mean) * wy * columns[x]
            }
        }
        return out
    }

    /// The 2-D transform, in place. vDSP scales the inverse by 1 / n², so
    /// forward then inverse gives back the input, and a perfect match's
    /// correlation peak is 1.
    private static func transform(_ real: inout [Float], _ imaginary: inout [Float], n: Int, log2n: Int,
                                  setup: FFTSetup, direction: FFTDirection) {
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                guard let reBase = re.baseAddress, let imBase = im.baseAddress else { return }
                var split = DSPSplitComplex(realp: reBase, imagp: imBase)
                // Stride 1 along a row; 0 lets vDSP use n between rows.
                vDSP_fft2d_zip(setup, &split, 1, 0, vDSP_Length(log2n), vDSP_Length(log2n), direction)
            }
        }
    }
}
