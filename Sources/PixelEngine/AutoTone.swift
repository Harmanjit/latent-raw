import Foundation
import Metal
import simd

/// The rest of Auto: Highlights, Shadows, Whites, Blacks, Vibrance and
/// Saturation, after `AutoAdjust` has chosen exposure, contrast and white
/// balance. Classic estimates again, nothing learned.
///
/// Everything is judged on the tone scale the tone ranges themselves work
/// on, t = contrast × log2(Y / mid grey) (ToneRanges.swift), where the SDR
/// tone map puts a tone at 1 / (1 + 2^−t) of white. So a target is a
/// place on screen, whatever the contrast and grey point are.
///
/// - **Whites and Blacks** place the image's end points: the brightest
///   0.2% of pixels at t = 5 (about 99% on the sRGB scale, bright but not
///   clipped) and the darkest 0.2% at t = −8.5 (about 4%, dark but not
///   crushed). Each is solved exactly with `ToneRanges.remap`, so the
///   slider lands where the render will put those tones.
/// - **Highlights and Shadows** answer the scene's range: a bright upper
///   tenth (past t = 2.5) is pulled down, a dark lower tenth (below
///   t = −2.5) is lifted, by up to 0.5 each. A flat scene gets neither.
/// - **Vibrance and Saturation** lift muted pictures a little and leave
///   colourful ones alone, from the midtones' average HSV saturation.
///
/// Shift-double-clicking one of the four tone range sliders sets just that
/// slider from the same estimate (`value(for:)`).
public enum AutoTone {
    public struct Suggestion: Sendable, Equatable {
        public var toneRanges: ToneRanges
        public var vibrance: Float
        public var saturation: Float
        /// The image's end points in t (the darkest and brightest 0.2%),
        /// nil when there was too little to measure. Kept so Whites and
        /// Blacks can be solved again against the sliders as they are.
        public var blackPoint: Float?
        public var whitePoint: Float?

        public init(toneRanges: ToneRanges = .neutral, vibrance: Float = 0, saturation: Float = 0,
                    blackPoint: Float? = nil, whitePoint: Float? = nil) {
            self.toneRanges = toneRanges; self.vibrance = vibrance; self.saturation = saturation
            self.blackPoint = blackPoint; self.whitePoint = whitePoint
        }
    }

    /// One of the four tone range sliders.
    public enum Slider: Sendable, CaseIterable {
        case highlights, shadows, whites, blacks
    }

    /// Where the end points go, in t.
    static let whitesTarget: Float = 5
    static let blacksTarget: Float = -8.5
    /// Which pixels count as the end points: the brightest and darkest 0.2%.
    static let endPercentile: Float = 0.002
    /// How far Auto moves any one tone range slider.
    static let limit: Float = 0.7

    // MARK: - From samples (pure, for the tests)

    /// The four tone range sliders for an image whose scene-linear
    /// luminances (exposure applied, tone ranges not) are `luminances`.
    public static func toneRanges(luminances: [Float], contrast: Float, greyPoint: Float) -> ToneRanges {
        measure(luminances: luminances, contrast: contrast, greyPoint: greyPoint).ranges
    }

    /// The four sliders, and the end points they were solved for.
    static func measure(luminances: [Float], contrast: Float,
                        greyPoint: Float) -> (ranges: ToneRanges, black: Float?, white: Float?) {
        let ts = luminances.compactMap { y -> Float? in
            guard y.isFinite, y > 0 else { return nil }
            return contrast * log2(max(y, 1e-7) / max(greyPoint, 1e-6))
        }.sorted()
        guard ts.count >= 16 else { return (.neutral, nil, nil) }
        func percentile(_ p: Float) -> Float { ts[min(max(Int(Float(ts.count - 1) * p), 0), ts.count - 1)] }

        var ranges = ToneRanges.neutral
        ranges.highlights = rounded(-min(max((percentile(0.9) - 2.5) / 4, 0), 0.5))
        ranges.shadows = rounded(min(max((-2.5 - percentile(0.1)) / 4, 0), 0.5))
        // Blacks then Whites, in the order the render applies them; neither
        // band reaches the other's end point, so the two solve independently.
        let black = percentile(endPercentile), white = percentile(1 - endPercentile)
        ranges.blacks = solve(ranges, \.blacks, tone: black, target: blacksTarget)
        ranges.whites = solve(ranges, \.whites, tone: white, target: whitesTarget)
        return (ranges, black, white)
    }

    /// Vibrance and Saturation from the midtones' mean HSV saturation
    /// (0 grey … 1 pure colour): a muted picture (below about 0.35) gets
    /// up to 0.25 vibrance and a touch of saturation.
    public static func presence(colourfulness: Float) -> (vibrance: Float, saturation: Float) {
        guard colourfulness.isFinite else { return (0, 0) }
        let vibrance = min(max((0.35 - colourfulness) * 1.0, 0), 0.25)
        let saturation = min(max((0.2 - colourfulness) * 0.5, 0), 0.05)
        return (rounded(vibrance), rounded(saturation))
    }

    /// The amount of `slider` that takes `tone` to `target`, given the
    /// sliders applied before it. `remap` rises with the amount (every
    /// band's weight is positive), so bisection finds it.
    static func solve(_ base: ToneRanges, _ slider: WritableKeyPath<ToneRanges, Float>,
                      tone: Float, target: Float) -> Float {
        func remapped(_ amount: Float) -> Float {
            var r = base; r[keyPath: slider] = amount
            return r.remap(tone)
        }
        var lo = -limit, hi = limit
        if remapped(lo) >= target { return lo }
        if remapped(hi) <= target { return hi }
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if remapped(mid) < target { lo = mid } else { hi = mid }
        }
        return rounded((lo + hi) / 2)
    }

    private static func rounded(_ v: Float) -> Float { (v * 100).rounded() / 100 }

    // MARK: - From the image

    /// Reads a small scene-linear render of the image as `parameters`
    /// would show it (Auto's exposure and contrast already in them), with
    /// the tone ranges reset so the estimate is absolute.
    public static func suggest(for session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                               parameters: EditParameters) throws -> Suggestion {
        var base = parameters
        base.toneRanges = .neutral
        let linear = try pipeline.render(session, scale: AutoAdjust.analysisScale, parameters: base,
                                         output: .sceneLinear)
        let pixels = try TextureReadback.float16Pixels(of: linear, gpu: gpu)

        var luminances: [Float] = []
        luminances.reserveCapacity(pixels.count / 4)
        var saturationSum: Float = 0, saturationCount = 0
        let midLow = parameters.greyPoint / 16, midHigh = parameters.greyPoint * 4
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
            let y = 0.2627 * rgb.x + 0.6780 * rgb.y + 0.0593 * rgb.z
            luminances.append(y)
            if y >= midLow, y <= midHigh {
                let mx = max(rgb.x, max(rgb.y, rgb.z)), mn = max(min(rgb.x, min(rgb.y, rgb.z)), 0)
                if mx > 1e-5 { saturationSum += (mx - mn) / mx; saturationCount += 1 }
            }
        }
        let measured = measure(luminances: luminances, contrast: parameters.contrast,
                               greyPoint: parameters.greyPoint)
        let presence = saturationCount > 100 ? self.presence(colourfulness: saturationSum / Float(saturationCount))
                                             : (vibrance: Float(0), saturation: Float(0))
        return Suggestion(toneRanges: measured.ranges, vibrance: presence.vibrance,
                          saturation: presence.saturation, blackPoint: measured.black, whitePoint: measured.white)
    }

    /// One slider's auto value, for Shift-double-click, with the other
    /// three left as they are in `current`. Highlights and Shadows take
    /// the estimate; Whites and Blacks are solved again on top of the
    /// sliders already set, so the end point still lands on its target.
    public static func value(for slider: Slider, in suggestion: Suggestion, current: ToneRanges) -> Float {
        switch slider {
        case .highlights: return suggestion.toneRanges.highlights
        case .shadows: return suggestion.toneRanges.shadows
        case .whites:
            guard let white = suggestion.whitePoint else { return suggestion.toneRanges.whites }
            var base = current; base.whites = 0
            return solve(base, \.whites, tone: white, target: whitesTarget)
        case .blacks:
            guard let black = suggestion.blackPoint else { return suggestion.toneRanges.blacks }
            var base = current; base.blacks = 0; base.whites = 0
            return solve(base, \.blacks, tone: black, target: blacksTarget)
        }
    }
}
