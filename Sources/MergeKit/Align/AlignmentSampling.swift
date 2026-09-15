import Accelerate
import Foundation

// The CPU sampling the aligner is built on: Gaussian-prefiltered
// reductions of a frame, by any factor and by exactly half.
//
// The loops here and in the aligner run over millions of pixels, and
// tests run unoptimised builds, where every Swift array access and
// function call is expensive. So the heavy loops work through raw
// pointers with their helpers written out inline, and whatever Accelerate
// can do in one call, it does.

enum AlignmentSampling {
    /// Runs `body` for `count` jobs on all cores.
    ///
    /// Every caller's jobs read shared inputs and write only their own
    /// rows (or their own slot of a results array), through raw pointers.
    /// That is safe, but the compiler can't see it for pointers, so the
    /// promise is made once, here, rather than at every call.
    static func parallel(_ count: Int, _ body: (Int) -> Void) {
        withoutActuallyEscaping(body) { body in
            nonisolated(unsafe) let job = body
            DispatchQueue.concurrentPerform(iterations: count) { job($0) }
        }
    }

    /// How many horizontal bands to split `rows` rows into: a few per core,
    /// so a slow band doesn't hold everything up, but never empty ones.
    static func bandCount(rows: Int) -> Int {
        max(1, min(rows, ProcessInfo.processInfo.activeProcessorCount * 4))
    }

    // MARK: - Reduction by any factor

    /// The Gaussian taps of a 1-D reduction from `source` to `output`
    /// samples: for each output sample, the first source index and `taps`
    /// normalised weights. The window is slid to lie inside the image
    /// (zero weights fill the part that moved off the edge), so the loops
    /// never test bounds.
    private struct Taps {
        let taps: Int
        var first: [Int]
        var weights: [Float]

        init(source: Int, output: Int) {
            let factor = Double(output) / Double(source)
            let sigma = 0.5 / factor
            let radius = Int((3 * sigma).rounded(.up))
            taps = min(2 * radius + 2, source)
            first = [Int](repeating: 0, count: output)
            weights = [Float](repeating: 0, count: output * taps)
            for i in 0..<output {
                // The output sample's centre in source index coordinates
                // (source pixel centres on integers).
                let centre = (Double(i) + 0.5) / factor - 0.5
                let start = min(max(Int(centre.rounded(.down)) - radius, 0), source - taps)
                first[i] = start
                var local = [Double](repeating: 0, count: taps)
                for k in 0..<taps {
                    let d = Double(start + k) - centre
                    local[k] = abs(d) <= Double(radius) + 1 ? exp(-d * d / (2 * sigma * sigma)) : 0
                }
                // Renormalised, so the window running off the edge doesn't darken it.
                let sum = local.reduce(0, +)
                for k in 0..<taps { weights[i * taps + k] = sum > 0 ? Float(local[k] / sum) : 0 }
            }
        }
    }

    /// `planes` (each `width x height`, row by row) reduced to
    /// `outWidth x outHeight` through a Gaussian of half an output pixel:
    /// each output sample is the weighted mean of the source around its
    /// centre, (i + 0.5) / factor. Separable, so rows first, then columns.
    /// Returns the planes unchanged when the size doesn't shrink.
    static func reduce(_ planes: [[Float]], width: Int, height: Int, outWidth: Int, outHeight: Int) -> [[Float]] {
        guard outWidth < width || outHeight < height else { return planes }
        let across = Taps(source: width, output: outWidth)
        let down = Taps(source: height, output: outHeight)
        return planes.map { plane in
            // Rows: width x height -> outWidth x height.
            var rows = [Float](repeating: 0, count: outWidth * height)
            plane.withUnsafeBufferPointer { src in
                rows.withUnsafeMutableBufferPointer { dst in
                    across.first.withUnsafeBufferPointer { firstBuffer in
                        across.weights.withUnsafeBufferPointer { weightBuffer in
                            let s = src.baseAddress!, d = dst.baseAddress!
                            let first = firstBuffer.baseAddress!, weights = weightBuffer.baseAddress!
                            let taps = vDSP_Length(across.taps), tapCount = across.taps
                            let bands = bandCount(rows: height)
                            parallel(bands) { band in
                                for y in (band * height / bands)..<((band + 1) * height / bands) {
                                    let row = s + y * width, out = d + y * outWidth
                                    for i in 0..<outWidth {
                                        vDSP_dotpr(row + first[i], 1, weights + i * tapCount, 1, out + i, taps)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Columns: outWidth x height -> outWidth x outHeight, each output
            // row a weighted sum of whole source rows.
            var out = [Float](repeating: 0, count: outWidth * outHeight)
            rows.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    down.first.withUnsafeBufferPointer { firstBuffer in
                        down.weights.withUnsafeBufferPointer { weightBuffer in
                            let s = src.baseAddress!, d = dst.baseAddress!
                            let first = firstBuffer.baseAddress!, weights = weightBuffer.baseAddress!
                            let taps = down.taps, length = vDSP_Length(outWidth)
                            let bands = bandCount(rows: outHeight)
                            parallel(bands) { band in
                                for j in (band * outHeight / bands)..<((band + 1) * outHeight / bands) {
                                    let target = d + j * outWidth
                                    for k in 0..<taps {
                                        var w = weights[j * taps + k]
                                        guard w != 0 else { continue }
                                        vDSP_vsma(s + (first[j] + k) * outWidth, 1, &w, target, 1, target, 1, length)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return out
        }
    }

    // MARK: - Halving

    /// `plane` halved on each axis: each output pixel is the mean of a 2 x 2
    /// block, then a small Gaussian (sigma 0.41 output pixels) adds enough
    /// blur for the two together to act like a Gaussian of half an output
    /// pixel, the prefilter `reduce` uses. Output pixel i's centre is
    /// exactly source position 2i + 1, so the level's scale is exactly half
    /// the one above it; an odd last row or column is dropped.
    static func halve(_ plane: [Float], width: Int, height: Int) -> [Float] {
        let ow = width / 2, oh = height / 2
        precondition(ow >= 3 && oh >= 3, "too small to halve")
        var box = [Float](repeating: 0, count: ow * oh)
        plane.withUnsafeBufferPointer { src in
            box.withUnsafeMutableBufferPointer { dst in
                let s = src.baseAddress!, d = dst.baseAddress!
                let bands = bandCount(rows: oh)
                parallel(bands) { band in
                    var quarter: Float = 0.25
                    var pairs = [Float](repeating: 0, count: 2 * ow)
                    pairs.withUnsafeMutableBufferPointer { pairBuffer in
                        let p = pairBuffer.baseAddress!
                        for j in (band * oh / bands)..<((band + 1) * oh / bands) {
                            let out = d + j * ow
                            // The block's two rows added, then its two columns.
                            vDSP_vadd(s + 2 * j * width, 1, s + (2 * j + 1) * width, 1, p, 1, vDSP_Length(2 * ow))
                            vDSP_vadd(p, 2, p + 1, 2, out, 1, vDSP_Length(ow))
                            vDSP_vsmul(out, 1, &quarter, out, 1, vDSP_Length(ow))
                        }
                    }
                }
            }
        }
        // A box one output pixel wide has a variance of 1/12 pixel²; this
        // Gaussian brings the total to 0.5² (sqrt(0.25 - 1/12) = 0.408).
        let sigma: Float = 0.408
        var kernel = (-2...2).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var out = [Float](repeating: 0, count: ow * oh)
        box.withUnsafeMutableBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var source = vImage_Buffer(data: src.baseAddress!, height: vImagePixelCount(oh),
                                           width: vImagePixelCount(ow), rowBytes: ow * 4)
                var destination = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(oh),
                                                width: vImagePixelCount(ow), rowBytes: ow * 4)
                let error = vImageSepConvolve_PlanarF(&source, &destination, nil, 0, 0, kernel, 5, kernel, 5, 0, 0,
                                                      vImage_Flags(kvImageEdgeExtend))
                precondition(error == kvImageNoError, "vImageSepConvolve_PlanarF failed: \(error)")
            }
        }
        return out
    }
}
