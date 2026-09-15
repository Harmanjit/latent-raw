import Accelerate
import Foundation
import Metal
import PixelEngine
import simd

// What the aligner looks at: a frame reduced to a small pyramid of log
// scene-light images, with the pixels that can't be trusted marked.

/// How one frame was exposed, as alignment needs to know it.
///
/// Two frames of a bracket record the same scene at different brightness.
/// Dividing each by its `gain` puts both on the same scale, and each frame
/// is only trusted between its noise floor and its clipping point: a
/// shadow the dark frame buried in noise, or a sky the bright frame
/// clipped, looks nothing like the same place in the other frame.
public struct AlignmentExposure: Sendable, Equatable {
    /// How much light the frame gathered, relative to the scale frames are
    /// compared on: 2^relativeEV for an HDR bracket (1 for the brightest
    /// frame, 0.25 for one 2 stops darker), 1 for a panorama.
    public var gain: Double
    /// Per channel (red, green, blue) the value at which the sensor clips,
    /// in the input's units. A pixel with any channel at
    /// `AlignmentImage.saturationFraction` of its clip or above is clipped.
    public var channelClip: SIMD3<Float>
    /// The darkest value, in the input's units, that is clear of noise.
    public var noiseFloor: Double

    public init(gain: Double, channelClip: SIMD3<Float> = SIMD3(repeating: 1),
                noiseFloor: Double = AlignmentImage.defaultNoiseFloor) {
        self.gain = gain
        self.channelClip = channelClip
        self.noiseFloor = noiseFloor
    }

    /// The scene light (input value / gain) this frame records well.
    public var validRange: ClosedRange<Double> {
        let g = max(gain, 1e-30)
        let low = noiseFloor / g
        let high = Double(AlignmentImage.saturationFraction * channelClip.min()) / g
        return low...max(low, high)
    }
}

/// A frame prepared for `FrameAligner`: its luminance, divided by the
/// exposure gain, as a pyramid of log2 images, each half the size of the
/// one above, from at most 3200 px on the long edge down to about 400 px,
/// each with a mask of trustworthy pixels.
///
/// **Why log2.** An edge between a shadow and a highlight should count as
/// much as an edge between two highlights. In log units a stop is a stop
/// everywhere, and the brightness difference that is left after dividing
/// by the gain becomes a plain offset, which the aligner solves for.
///
/// **Why a pyramid.** The aligner refines its estimate from coarse to
/// fine: a 20 px shift at full size is 1 px at 400 px, where a few
/// iterations find it cheaply; each finer level then only adds precision.
///
/// **Why reduce with a Gaussian.** Shrinking without blurring first turns
/// fine detail (foliage, fabric) into false patterns that differ between
/// frames. Every level is a Gaussian-weighted mean of the linear light
/// (not of the log values, which would bias bright edges dark).
///
/// Memory: about 5 bytes a pixel at the finest level plus a third for the
/// coarser ones, 45 MB at 3200 x 2133.
public struct AlignmentImage: Sendable {
    /// One level of the pyramid.
    public struct Level: Sendable {
        public let width: Int
        public let height: Int
        /// This level's pixels per full-resolution pixel, across and down.
        public let scaleX: Double
        public let scaleY: Double
        /// log2(luminance / gain), row by row. Not clamped: `FrameAligner`
        /// clamps a pair to the range both frames share.
        public let logLuminance: [Float]
        /// 1 where no clipped pixel contributed noticeably, 0 elsewhere.
        public let valid: [UInt8]
    }

    /// The size of the frame the homographies refer to.
    public let fullWidth: Int
    public let fullHeight: Int
    public let exposure: AlignmentExposure
    /// Coarsest first; the last is the finest.
    public let levels: [Level]

    /// The finest level's long edge, at most: the spike found 3200 px gives
    /// corner errors under 0.1 px on 24 MP frames; finer adds time, not
    /// accuracy.
    public static let finestLongEdge = 3200
    /// Each coarser level halves the one above it while its long edge stays
    /// at least this: 3200, 1600, 800 and 400 px for a big frame.
    public static let coarsestLongEdge = 400
    /// A channel at this share of its clip level counts as clipped: just
    /// below it, as a photosite near saturation may already respond less
    /// than in proportion to the light.
    public static let saturationFraction: Float = 0.98
    /// 2^-11 of white: below it, a 12- or 14-bit sensor's read noise
    /// swamps the signal.
    public static let defaultNoiseFloor = 1.0 / 2048
    /// A reduced pixel whose Gaussian footprint is more than this share
    /// clipped is marked unusable. A clipped value is lower than the truth
    /// by an unknown amount, so a pixel with much clipping in it is biased;
    /// but at the coarse levels a footprint spans dozens of full-size
    /// pixels, and a stricter limit would mark almost all of a bright
    /// frame with scattered highlights unusable (seen on the Ihrke tripod
    /// bracket). 2% keeps the bias under a tenth of a stop for highlights
    /// up to 5 times their clip level, and the refinement's robust
    /// weighting discounts what's left.
    static let clippedShareLimit: Float = 0.02
    /// Log values for black pixels (log2 of 0 is minus infinity).
    static let smallestLuminance: Float = 1e-12

    public var finest: Level { levels[levels.count - 1] }

    /// Bytes the pyramid holds.
    public var byteCount: Int {
        levels.reduce(0) { $0 + $1.width * $1.height * 5 }
    }

    // MARK: - Building

    /// From a luminance plane on the CPU.
    ///
    /// - Parameters:
    ///   - luminance: `width x height` values, row by row, in the units of
    ///     `exposure` (linear, black subtracted). Use (R + 2G + B) / 4 of
    ///     camera RGB at unit white balance for consistency with the other
    ///     builders.
    ///   - clippedShare: per pixel, the share (0...1) of it that was
    ///     clipped; nil to judge clipping from `luminance` alone against the
    ///     lowest channel clip.
    ///   - fullWidth, fullHeight: the frame's full-resolution size, when
    ///     `luminance` is already reduced (a 2 x 2 binned frame of a
    ///     6000 x 4000 sensor is 3000 x 2000 with a full size of 6000 x 4000).
    ///     Nil means the plane is full size.
    public init(luminance: [Float], clippedShare: [Float]? = nil, width: Int, height: Int,
                fullWidth: Int? = nil, fullHeight: Int? = nil, exposure: AlignmentExposure) {
        precondition(width > 0 && height > 0 && luminance.count == width * height, "luminance must be width x height")
        precondition(clippedShare.map { $0.count == luminance.count } ?? true, "clippedShare must match luminance")
        let clipped = clippedShare ?? {
            let limit = AlignmentImage.saturationFraction * exposure.channelClip.min()
            var marks = [Float](repeating: 0, count: luminance.count)
            luminance.withUnsafeBufferPointer { lum in
                marks.withUnsafeMutableBufferPointer { out in
                    let l = lum.baseAddress!, o = out.baseAddress!
                    for i in 0..<lum.count where l[i] >= limit { o[i] = 1 }
                }
            }
            return marks
        }()
        self.init(reducedFrom: [luminance, clipped], width: width, height: height,
                  fullWidth: fullWidth ?? width, fullHeight: fullHeight ?? height, exposure: exposure)
    }

    /// From interleaved RGBA on the CPU (camera RGB at unit white balance,
    /// black subtracted, 4 Float32 per pixel). A pixel is clipped when any
    /// channel reaches `saturationFraction` of its clip; with
    /// `alphaIsClippedShare`, alpha is also read as the share of the pixel
    /// that was clipped (as in `HDRMergeKernels.AnalysisImage`).
    public init(rgba: [Float], width: Int, height: Int, alphaIsClippedShare: Bool,
                fullWidth: Int? = nil, fullHeight: Int? = nil, exposure: AlignmentExposure) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4, "rgba must be width x height x 4")
        let clip = exposure.channelClip * AlignmentImage.saturationFraction
        let (clipR, clipG, clipB) = (clip.x, clip.y, clip.z)
        var luminance = [Float](repeating: 0, count: width * height)
        var clipped = [Float](repeating: 0, count: width * height)
        rgba.withUnsafeBufferPointer { source in
            luminance.withUnsafeMutableBufferPointer { lum in
                clipped.withUnsafeMutableBufferPointer { clip in
                    let p = source.baseAddress!, l = lum.baseAddress!, c = clip.baseAddress!
                    let count = width * height
                    let bands = AlignmentSampling.bandCount(rows: height)
                    AlignmentSampling.parallel(bands) { band in
                        for i in (band * count / bands)..<((band + 1) * count / bands) {
                            let r = p[4 * i], g = p[4 * i + 1], b = p[4 * i + 2]
                            l[i] = 0.25 * r + 0.5 * g + 0.25 * b
                            if r >= clipR || g >= clipG || b >= clipB {
                                c[i] = 1
                            } else if alphaIsClippedShare {
                                c[i] = min(max(p[4 * i + 3], 0), 1)
                            }
                        }
                    }
                }
            }
        }
        self.init(reducedFrom: [luminance, clipped], width: width, height: height,
                  fullWidth: fullWidth ?? width, fullHeight: fullHeight ?? height, exposure: exposure)
    }

    /// From the HDR merge's reduced analysis frame (`HDRMergeKernels.analysisImage`):
    /// block means at unit white balance, alpha the clipped share. A span
    /// of 2 gives each Bayer quad's colour without demosaicing, a good
    /// input for alignment.
    public init(analysis: HDRMergeKernels.AnalysisImage, fullWidth: Int, fullHeight: Int,
                exposure: AlignmentExposure) {
        self.init(rgba: analysis.pixels, width: analysis.width, height: analysis.height, alphaIsClippedShare: true,
                  fullWidth: fullWidth, fullHeight: fullHeight, exposure: exposure)
    }

    /// From a GPU texture (rgba16Float or rgba32Float camera RGB, black
    /// subtracted): the finest level is reduced on the GPU, so a 45 MP
    /// frame never has to be read back, and the coarser levels on the CPU.
    ///
    /// - Parameters:
    ///   - clipMask: optional one-channel texture of the same size; above 0
    ///     marks a clipped pixel (the HDR merge's per-photosite clip mask).
    ///   - channelScale: multiplies each channel first, such as the inverse
    ///     white balance for a demosaiced frame that still carries it.
    ///     `exposure.channelClip` is in the units after this scale.
    ///   - fullWidth, fullHeight: nil when `texture` is full size.
    public static func make(texture: MTLTexture, clipMask: MTLTexture? = nil,
                            channelScale: SIMD3<Float> = SIMD3(repeating: 1),
                            fullWidth: Int? = nil, fullHeight: Int? = nil,
                            exposure: AlignmentExposure, gpu: GPUContext) throws -> AlignmentImage {
        let (w, h) = finestSize(width: texture.width, height: texture.height)
        let reduced = try MergeWarpKernels.alignmentReduction(
            of: texture, clipMask: clipMask, channelScale: channelScale,
            channelClip: exposure.channelClip * saturationFraction, width: w, height: h, gpu: gpu)
        return AlignmentImage(reducedFrom: [reduced.luminance, reduced.clippedShare], width: w, height: h,
                              fullWidth: fullWidth ?? texture.width, fullHeight: fullHeight ?? texture.height,
                              exposure: exposure)
    }

    /// The finest level's size for a `width x height` input: the long edge
    /// capped at 3200, the aspect ratio kept.
    static func finestSize(width: Int, height: Int) -> (Int, Int) {
        size(width: width, height: height, longEdge: min(finestLongEdge, max(width, height)))
    }

    static func size(width: Int, height: Int, longEdge: Int) -> (Int, Int) {
        let f = Double(longEdge) / Double(max(width, height))
        return (max(1, Int((Double(width) * f).rounded())), max(1, Int((Double(height) * f).rounded())))
    }

    init(fullWidth: Int, fullHeight: Int, exposure: AlignmentExposure, levels: [Level]) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.exposure = exposure
        self.levels = levels
    }

    /// Builds the pyramid from linear planes [luminance, clipped share]:
    /// reduced to the finest level (long edge at most 3200), then halved
    /// while the long edge stays at least `coarsestLongEdge`, and finally
    /// turned into log values and masks.
    init(reducedFrom planes: [[Float]], width: Int, height: Int, fullWidth: Int, fullHeight: Int,
         exposure: AlignmentExposure) {
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.exposure = exposure

        var (w, h) = Self.finestSize(width: width, height: height)
        var current = AlignmentSampling.reduce(planes, width: width, height: height, outWidth: w, outHeight: h)
        var scaleX = Double(w) / Double(fullWidth), scaleY = Double(h) / Double(fullHeight)
        var linear: [(width: Int, height: Int, scaleX: Double, scaleY: Double, planes: [[Float]])] = [
            (w, h, scaleX, scaleY, current),
        ]
        while max(w, h) / 2 >= Self.coarsestLongEdge, min(w, h) / 2 >= 8 {
            current = current.map { AlignmentSampling.halve($0, width: w, height: h) }
            (w, h) = (w / 2, h / 2)
            (scaleX, scaleY) = (scaleX / 2, scaleY / 2)
            linear.append((w, h, scaleX, scaleY, current))
        }

        var gain = Float(exposure.gain)
        var smallest = Self.smallestLuminance
        let limit = Self.clippedShareLimit
        levels = linear.reversed().map { level in
            let count = level.width * level.height
            // log2(max(luminance / gain, smallest)), vectorised.
            var logs = [Float](repeating: 0, count: count)
            vDSP_vsdiv(level.planes[0], 1, &gain, &logs, 1, vDSP_Length(count))
            vDSP_vthr(logs, 1, &smallest, &logs, 1, vDSP_Length(count))
            var n = Int32(count)
            logs.withUnsafeMutableBufferPointer { vvlog2f($0.baseAddress!, $0.baseAddress!, &n) }
            var valid = [UInt8](repeating: 0, count: count)
            level.planes[0].withUnsafeBufferPointer { lum in
                level.planes[1].withUnsafeBufferPointer { clip in
                    valid.withUnsafeMutableBufferPointer { ok in
                        let l = lum.baseAddress!, c = clip.baseAddress!, o = ok.baseAddress!
                        for i in 0..<count where c[i] <= limit && l[i].isFinite { o[i] = 1 }
                    }
                }
            }
            return Level(width: level.width, height: level.height, scaleX: level.scaleX, scaleY: level.scaleY,
                         logLuminance: logs, valid: valid)
        }
    }
}
