import Foundation
import Metal
import simd
import ColorKit

/// A starting point for an edit, computed from the image itself.
///
/// Three classic estimates, nothing learned:
///
/// - **Exposure**: place the scene's geometric-mean brightness on mid
///   grey, then back off if that would push the brightest half-percent of
///   pixels far past white. The geometric mean (mean of log brightness) is
///   the right average for photographs because perception is logarithmic
///   and it isn't dragged around by a few very bright pixels.
/// - **Contrast**: from the spread of log brightness. A flat, hazy scene
///   spans few stops and gets more contrast; a high-range scene gets less
///   so it fits the curve without crushing.
/// - **White balance**: grey-world on the midtones, in *camera* space —
///   assume the average midtone colour ought to be neutral, and pick the
///   temperature and tint that make it so. Crude but usually close; it's
///   why it's an "Auto" button and not the default.
///
/// All of it reads a small analysis render, so it costs a few ms.
public enum AutoAdjust {
    public struct Suggestion: Sendable, Equatable {
        public var exposureEV: Float
        public var contrast: Float
        public var whiteBalance: ColorKit.WhiteBalance?
    }

    /// Analysis resolution: a few hundred thousand pixels is plenty.
    static let analysisScale = RenderScale.binned(quads: 4)

    public static func suggest(for session: ImageSession,
                               pipeline: RenderPipeline,
                               gpu: GPUContext,
                               current: EditParameters) throws -> Suggestion {
        // Exposure and contrast are judged with exposure reset to zero so
        // the estimate is absolute, not relative to whatever the slider
        // happens to be at now.
        var base = current
        base.exposureEV = 0
        let linear = try pipeline.render(session, scale: analysisScale, parameters: base,
                                         output: .sceneLinear)
        let pixels = try TextureReadback.float16Pixels(of: linear, gpu: gpu)

        // Rec.2020 luminance weights (the working space).
        var logs: [Float] = []
        logs.reserveCapacity(pixels.count / 4)
        var luminances: [Float] = []
        luminances.reserveCapacity(pixels.count / 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let y = 0.2627 * Float(pixels[i]) + 0.6780 * Float(pixels[i + 1]) + 0.0593 * Float(pixels[i + 2])
            luminances.append(y)
            if y > 1e-4 { logs.append(log2(y)) }
        }
        guard !logs.isEmpty else {
            return Suggestion(exposureEV: 0, contrast: current.contrast, whiteBalance: nil)
        }

        // Exposure: geometric mean to grey, with a highlight guard.
        let meanLog = logs.reduce(0, +) / Float(logs.count)
        var ev = log2(current.greyPoint) - meanLog
        let sorted = luminances.sorted()
        let p995 = sorted[Int(Float(sorted.count - 1) * 0.995)]
        let highlightCeiling: Float = 8 * current.greyPoint   // ~3 stops over grey
        if p995 * pow(2, ev) > highlightCeiling {
            ev = log2(highlightCeiling / max(p995, 1e-6))
        }
        ev = min(max(ev, -3), 3)

        // Contrast: standard deviation of log brightness. ~2.2 stops is a
        // typical scene at the default 1.5; scale gently around that.
        let variance = logs.reduce(0) { $0 + ($1 - meanLog) * ($1 - meanLog) } / Float(logs.count)
        let spread = max(sqrt(variance), 0.3)
        let contrast = min(max(1.5 * pow(2.2 / spread, 0.5), 1.0), 2.2)

        // White balance: grey-world over the midtones in camera space.
        let whiteBalance = try greyWorld(session: session, pipeline: pipeline, gpu: gpu,
                                         parameters: base)

        return Suggestion(exposureEV: ev, contrast: contrast, whiteBalance: whiteBalance)
    }

    /// Estimates the illuminant by assuming the midtones average to
    /// neutral, in the camera's own colour space where the white balance
    /// multipliers act. Returns nil when the camera has no colour profile
    /// (temperature and tint are only meaningful through one).
    static func greyWorld(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                          parameters: EditParameters) throws -> ColorKit.WhiteBalance? {
        guard let profile = session.profile else { return nil }
        let camera = try pipeline.renderCameraRGB(session, scale: analysisScale, parameters: parameters)
        let pixels = try TextureReadback.float16Pixels(of: camera, gpu: gpu)

        // Midtones by green (the best-sampled channel): between the 25th
        // and 85th percentiles, which skips shadows (noise, no colour
        // information) and highlights (clipped, wrong colour).
        var greens: [Float] = []
        greens.reserveCapacity(pixels.count / 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { greens.append(Float(pixels[i + 1])) }
        let sortedGreens = greens.sorted()
        let low = sortedGreens[Int(Float(sortedGreens.count - 1) * 0.25)]
        let high = sortedGreens[Int(Float(sortedGreens.count - 1) * 0.85)]

        var sum = SIMD3<Double>(0, 0, 0)
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let g = Float(pixels[i + 1])
            guard g >= low, g <= high, g > 1e-4 else { continue }
            sum += SIMD3<Double>(Double(pixels[i]), Double(g), Double(pixels[i + 2]))
            count += 1
        }
        guard count > 100, sum.x > 0, sum.z > 0 else { return nil }
        let mean = sum / Double(count)

        // The image was rendered with `parameters.whiteBalance` already
        // applied; the residual cast is mean.r/mean.g and mean.b/mean.g.
        // Correct it partially: full grey-world overshoots on scenes that
        // genuinely are one colour (a sunset, a lawn).
        let damping: Float = 0.7
        let rFactor = pow(Float(mean.y / mean.x), damping)
        let bFactor = pow(Float(mean.y / mean.z), damping)
        let current = session.multipliers(for: parameters.whiteBalance)
        let corrected = SIMD4<Float>(current.x * rFactor, current.y, current.z * bFactor, current.w)
        return profile.whiteBalance(fromMultipliers: corrected)
    }
}
