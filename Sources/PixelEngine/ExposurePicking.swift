import Foundation
import CoreGraphics
import simd

extension EditParameters {
    /// Black Offset's range, in linear working-space units.
    public static let blackOffsetRange: ClosedRange<Float> = -0.05...0.05

    /// A stored Black Offset brought into range (0 for a broken value).
    public static func clampedBlackOffset(_ v: Float) -> Float {
        v.isFinite ? min(max(v, blackOffsetRange.lowerBound), blackOffsetRange.upperBound) : 0
    }
}

/// The Exposure eyedropper and Match by Histogram: an area's scene-linear
/// luminance before exposure, and the Exposure that brings it to a target.
///
/// The luminance is read from a small scene-linear analysis render (the
/// camera matrix applied, no tone curve, `RenderOutput.sceneLinear`) with
/// Exposure, Black Offset and the local adjustments taken out, so what is
/// measured is the light the photo starts from. The Exposure that brings a
/// luminance `patch` to `target` is log2(target / patch) stops.
public enum ExposurePicking {
    /// What the eyedropper brings the picked area to.
    public enum Target: Equatable, Sendable, Codable {
        /// 18% scene-linear grey, the photographer's middle grey.
        case middleGrey
        /// What the tone curve shows at half of the display's brightness:
        /// the edit's Mid Grey point.
        case displayHalf
        /// A scene-linear fraction, 0.005…1.
        case custom(Float)

        public var title: String {
            switch self {
            case .middleGrey: return "18% Grey"
            case .displayHalf: return "50% Display"
            case .custom(let v): return String(format: "Custom (%.1f%%)", v * 100)
            }
        }

        /// The target's scene-linear luminance for an edit whose Mid Grey
        /// is `greyPoint`.
        public func luminance(greyPoint: Float) -> Float {
            switch self {
            case .middleGrey: return 0.18
            case .displayHalf: return greyPoint
            case .custom(let v): return min(max(v.isFinite ? v : 0.18, 0.005), 1)
            }
        }
    }

    /// The analysis render's scale: a quarter of a quarter, like the
    /// Point Colour picker's.
    public static let analysisScale = RenderScale.binned(quads: 4)
    /// Below this the area is mostly noise and the answer means nothing.
    public static let darkestUsable: Float = 1e-5

    /// The Exposure (−5…+5, to a hundredth) that brings `patch` to
    /// `target`; nil when the patch is black or not a number.
    public static func exposure(patch: Float, target: Float) -> Float? {
        guard patch.isFinite, target.isFinite, patch > darkestUsable, target > 0 else { return nil }
        let ev = log2(target / patch)
        return (min(max(ev, -5), 5) * 100).rounded() / 100
    }

    /// The parameters the analysis renders with: the edit before exposure.
    static func analysisParameters(_ parameters: EditParameters) -> EditParameters {
        var p = parameters
        p.exposureEV = 0
        p.blackOffset = 0
        p.locals = []
        return p
    }

    /// The scene-linear Rec.2020 luminance of every pixel of a small
    /// analysis render, row-major, with its size.
    public static func analysisLuminances(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                                          parameters: EditParameters,
                                          scale: RenderScale = ExposurePicking.analysisScale) throws
        -> (width: Int, height: Int, luminances: [Float]) {
        let texture = try pipeline.render(session, scale: scale, parameters: analysisParameters(parameters),
                                          output: .sceneLinear)
        let px = try TextureReadback.float16Pixels(of: texture, gpu: gpu)
        var l: [Float] = []
        l.reserveCapacity(px.count / 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            l.append(0.2627 * Float(px[i]) + 0.6780 * Float(px[i + 1]) + 0.0593 * Float(px[i + 2]))
        }
        return (texture.width, texture.height, l)
    }

    /// The mean luminance of an area given as fractions of the frame
    /// (0…1 each way, as the Point Colour picker measures clicks). An area
    /// smaller than a 5×5 square of analysis pixels is grown to one round
    /// its centre, so a click reads a small patch, never one pixel. Nil
    /// off the frame.
    public static func meanLuminance(in area: CGRect, width: Int, height: Int, luminances: [Float]) -> Float? {
        guard width > 0, height > 0, luminances.count >= width * height else { return nil }
        guard (0...1).contains(area.midX), (0...1).contains(area.midY) else { return nil }
        var x0 = Int((area.minX * CGFloat(width)).rounded(.down)), x1 = Int((area.maxX * CGFloat(width)).rounded(.down))
        var y0 = Int((area.minY * CGFloat(height)).rounded(.down)), y1 = Int((area.maxY * CGFloat(height)).rounded(.down))
        if x1 - x0 < 4 { let c = (x0 + x1) / 2; x0 = c - 2; x1 = c + 2 }
        if y1 - y0 < 4 { let c = (y0 + y1) / 2; y0 = c - 2; y1 = c + 2 }
        x0 = max(x0, 0); y0 = max(y0, 0); x1 = min(x1, width - 1); y1 = min(y1, height - 1)
        guard x1 >= x0, y1 >= y0 else { return nil }
        var sum: Double = 0
        var n = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let v = luminances[y * width + x]
                guard v.isFinite else { continue }
                sum += Double(max(v, 0)); n += 1
            }
        }
        return n > 0 ? Float(sum / Double(n)) : nil
    }

    /// The luminance below which `percentile` (0…1) of the finite pixels
    /// fall; nil with none.
    public static func percentileLuminance(_ luminances: [Float], percentile: Float) -> Float? {
        let sorted = luminances.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let q = percentile.isFinite ? min(max(percentile, 0), 1) : 0.5
        let index = min(Int((q * Float(sorted.count - 1)).rounded()), sorted.count - 1)
        return max(sorted[index], 0)
    }

    /// Match by Histogram's measure of one photo: the luminance at
    /// `percentile` of a small analysis render of its edit before exposure.
    public static func percentileLuminance(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                                           parameters: EditParameters, percentile: Float) throws -> Float? {
        let analysis = try analysisLuminances(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters,
                                              scale: AutoAdjust.analysisScale)
        return percentileLuminance(analysis.luminances, percentile: percentile)
    }
}
