import Foundation

// One pyramid level of one frame, as the aligner compares it with the
// other frame of a pair.

/// The log2 luminance range a pair of frames both record well: above the
/// darker frame's noise floor and below the brighter frame's clipping, on
/// the shared scale (each frame's luminance divided by its gain).
struct AlignmentPairRange {
    let low: Float
    let high: Float

    /// Frames sharing less than this many stops can't be compared.
    static let minimumStops: Float = 1

    init?(_ a: AlignmentExposure, _ b: AlignmentExposure) {
        let ra = a.validRange, rb = b.validRange
        let low = Float(log2(max(ra.lowerBound, rb.lowerBound)))
        let high = Float(log2(min(ra.upperBound, rb.upperBound)))
        guard low.isFinite, high.isFinite, high - low >= Self.minimumStops else { return nil }
        self.low = low
        self.high = high
    }
}

/// A level's log luminance mapped to 0...1 across a pair's shared range.
///
/// Two versions exist for different jobs:
/// - **Masked** (`masked`): pixels outside the shared range, or marked
///   clipped, are NaN. The refinement and the similarity score skip NaN,
///   so a pixel only one frame recorded well never counts.
/// - **Clamped** (`clamped`): every pixel finite, clipped ones at the top.
///   Phase correlation needs a complete image (a Fourier transform can't
///   skip pixels), and clamping, as the spike did, works.
struct AlignmentPlane {
    let width: Int
    let height: Int
    var values: [Float]

    /// Pixels this close to either end of the range (as a share of it)
    /// count as outside: a value clamped there says only "at least" or
    /// "at most", not where the scene really is.
    static let edgeMargin: Float = 0.002

    static func masked(_ level: AlignmentImage.Level, range: AlignmentPairRange) -> AlignmentPlane {
        make(level, range: range, clamped: false)
    }

    static func clamped(_ level: AlignmentImage.Level, range: AlignmentPairRange) -> AlignmentPlane {
        make(level, range: range, clamped: true)
    }

    private static func make(_ level: AlignmentImage.Level, range: AlignmentPairRange, clamped: Bool) -> AlignmentPlane {
        let count = level.width * level.height
        var values = [Float](repeating: 0, count: count)
        let low = range.low, span = range.high - range.low
        level.logLuminance.withUnsafeBufferPointer { logBuffer in
            level.valid.withUnsafeBufferPointer { validBuffer in
                values.withUnsafeMutableBufferPointer { outBuffer in
                    let logs = logBuffer.baseAddress!, valid = validBuffer.baseAddress!, out = outBuffer.baseAddress!
                    let margin = edgeMargin
                    let bands = AlignmentSampling.bandCount(rows: level.height)
                    AlignmentSampling.parallel(bands) { band in
                        for i in (band * count / bands)..<((band + 1) * count / bands) {
                            let v = (logs[i] - low) / span
                            if clamped {
                                out[i] = valid[i] == 0 ? 1 : min(max(v, 0), 1)
                            } else {
                                out[i] = valid[i] != 0 && v > margin && v < 1 - margin ? v : .nan
                            }
                        }
                    }
                }
            }
        }
        return AlignmentPlane(width: level.width, height: level.height, values: values)
    }
}
