// Working out how much light each frame of a bracket gathered, from its
// EXIF and from its pixels.

import Accelerate
import Foundation
import PixelEngine

/// One frame's reduced image, as the analysis measures it
/// (`HDRMergeKernels.analysisImage`): the mean of each block of photosites
/// at unit white balance in normalised units, and the share of the block
/// that was clipped.
struct HDRAnalysisFrame {
    let width: Int
    let height: Int
    /// Photosites per side of each block, so shifts can be turned back
    /// into full-resolution pixels.
    let span: Int
    /// Four Float32 per block: red, green, blue, clipped share.
    let pixels: [Float]
    /// Where each colour clips, in the same units (`HDRFrameLevels.channelClip`).
    let channelClip: SIMD3<Float>

    init(_ image: HDRMergeKernels.AnalysisImage, levels: HDRFrameLevels) {
        width = image.width
        height = image.height
        span = image.span
        pixels = image.pixels
        channelClip = levels.channelClip
    }

    init(width: Int, height: Int, span: Int, pixels: [Float], channelClip: SIMD3<Float>) {
        self.width = width; self.height = height; self.span = span
        self.pixels = pixels; self.channelClip = channelClip
    }

    /// The share of photosites clipped: the mean of the blocks' shares.
    var clippedFraction: Double {
        guard width * height > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<(width * height) { sum += Double(pixels[i * 4 + 3]) }
        return sum / Double(width * height)
    }

    /// The share of blocks so dark that read noise swamps them: every
    /// colour below 2^-10 of white, about 15 counts on a 14-bit sensor.
    var crushedFraction: Double {
        guard width * height > 0 else { return 0 }
        let floor = HDRExposure.crushedLevel
        var crushed = 0
        for i in 0..<(width * height)
        where pixels[i * 4] < floor && pixels[i * 4 + 1] < floor && pixels[i * 4 + 2] < floor {
            crushed += 1
        }
        return Double(crushed) / Double(width * height)
    }
}

/// The exposure arithmetic, apart from any GPU or file, so tests can feed
/// it numbers directly.
enum HDRExposure {
    /// Fewer usable blocks than this and a pair's measurement isn't trusted
    /// (docs/PhotoMerge.md section 3).
    static let minimumSamples = 5000
    /// A measurement further than this from the EXIF is taken to be wrong
    /// (a scene with too little overlap in its usable tones), so EXIF wins.
    static let maximumDisagreementStops = 1.0
    /// A frame whose measured exposure is further than this from its EXIF
    /// gets `HDRMergeWarning.exposureMetadataDisagrees`.
    static let warningDisagreementStops = 0.25
    /// Brackets whose EXIF exposures all lie within this range can't be merged.
    static let sameExposureStops = 0.3
    /// Below this range the merge gains little (`smallExposureRange`).
    static let smallRangeStops = 1.0
    static let crushedLevel: Float = 1.0 / 1024

    /// EXIF's exposure as a number proportional to the light recorded:
    /// shutter x ISO / aperture². A missing ISO or aperture counts as 100
    /// or f/1, which cancels out when every frame lacks it (a manual lens
    /// records no aperture). nil without a shutter speed.
    static func exifExposure(shutter: Double, iso: Double, aperture: Double) -> Double? {
        guard shutter.isFinite, shutter > 0 else { return nil }
        let iso = iso.isFinite && iso > 0 ? iso : 100
        let aperture = aperture.isFinite && aperture > 0 ? aperture : 1
        return shutter * iso / (aperture * aperture)
    }

    /// How many stops more light `brighter` gathered than `darker`, measured
    /// from the pixels: the median of log2(brighter / darker) over blocks
    /// that are
    /// - unclipped in both frames (no clipped photosite in either block),
    /// - mid-tone: every colour below 75% of its clip level in the brighter
    ///   frame, so noise pushing a photosite over clipping can't bias the
    ///   blocks that remain, and bright enough in the darker frame (the sum
    ///   of its colours at least 1% of white) that noise is small,
    /// - flat: brightness changes by under 0.2 stops across the block's
    ///   neighbours in the brighter frame, so an edge that moved by a
    ///   fraction of a pixel between frames can't count.
    ///
    /// The median rather than the mean, because the blocks that slip
    /// through these tests (a moving leaf, a sparkle) are outliers. Each
    /// colour's black level was already subtracted separately, so the ratio
    /// has no offset left to fit. Returns the stops and the number of blocks
    /// used; nil stops when none qualified.
    static func measuredStops(brighter: HDRAnalysisFrame, darker: HDRAnalysisFrame) -> (stops: Double?, samples: Int) {
        let w = brighter.width, h = brighter.height
        guard w == darker.width, h == darker.height, w >= 3, h >= 3 else { return (nil, 0) }
        let a = brighter.pixels, b = darker.pixels
        let highlight = brighter.channelClip * 0.75
        let darkFloor: Float = 0.01
        let flatness: Float = 0.2

        // Brightness of the brighter frame in stops, for the flatness test.
        var logA = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            logA[i] = log2(max(a[i * 4] + a[i * 4 + 1] + a[i * 4 + 2], 1e-6))
        }

        var samples: [Float] = []
        samples.reserveCapacity(w * h / 2)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x, p = i * 4
                guard a[p + 3] == 0, b[p + 3] == 0 else { continue }
                guard a[p] < highlight.x, a[p + 1] < highlight.y, a[p + 2] < highlight.z else { continue }
                let sumA = a[p] + a[p + 1] + a[p + 2]
                let sumB = b[p] + b[p + 1] + b[p + 2]
                guard sumB >= darkFloor, sumA > 0 else { continue }
                guard abs(logA[i + 1] - logA[i - 1]) < flatness, abs(logA[i + w] - logA[i - w]) < flatness else { continue }
                samples.append(log2(sumA / sumB))
            }
        }
        guard !samples.isEmpty else { return (nil, 0) }
        vDSP_vsort(&samples, vDSP_Length(samples.count), 1)
        let middle = samples.count / 2
        let median = samples.count % 2 == 1 ? samples[middle] : (samples[middle - 1] + samples[middle]) / 2
        return (Double(median), samples.count)
    }

    /// The stops between two neighbouring frames the merge should use: the
    /// measurement when it is trustworthy, the EXIF otherwise.
    static func pairStops(measured: Double?, samples: Int, exif: Double) -> (stops: Double, usedMeasurement: Bool) {
        guard let measured, samples >= minimumSamples, abs(measured - exif) <= maximumDisagreementStops else {
            return (exif, false)
        }
        return (measured, true)
    }

    /// The reference frame: the one with the least of its picture lost to
    /// clipping or noise, so the merge opens looking like the frame that
    /// shows the most. Ties go to the frame nearest the middle of the bracket.
    static func referenceIndex(clipped: [Double], crushed: [Double]) -> Int {
        guard !clipped.isEmpty else { return 0 }
        let middle = Double(clipped.count - 1) / 2
        return clipped.indices.min { i, j in
            let si = clipped[i] + crushed[i], sj = clipped[j] + crushed[j]
            if abs(si - sj) > 1e-9 { return si < sj }
            return abs(Double(i) - middle) < abs(Double(j) - middle)
        } ?? 0
    }
}
