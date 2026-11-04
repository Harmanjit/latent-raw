import Foundation
import ColorKit

/// A preset's Amount, as Lightroom's: 0% leaves the photo as it was, 100%
/// applies the preset as saved, 200% goes twice as far.
///
/// Only the slider values blend, from the photo's own value to the
/// preset's (and past it above 100%): exposure, contrast, the tone ranges,
/// presence, vibrance and saturation, HSL, the curves' points, split
/// toning's and colour grading's strengths, Calibration, sharpening and
/// noise reduction, the effects' amounts, white balance and a creative
/// profile's Amount. Everything else a preset carries (a switch, a choice,
/// a hue, a mask, a crop) is taken from the preset whole whenever the
/// Amount is above 0%, since half a Black & White switch or half a hue
/// means nothing.
public enum PresetAmount {
    public static let range: ClosedRange<Float> = 0...2
    public static let full: Float = 1

    /// Results past these are clamped, so 200% never asks the renderer for
    /// a value its slider can't show.
    static let unit: ClosedRange<Float> = -1...1
}

extension EditParameters {
    /// `self` (the photo with the preset applied in full) pulled back
    /// towards, or pushed away from, `base` (the photo before it) by
    /// `amount`.
    public func blended(from base: EditParameters, amount rawAmount: Float) -> EditParameters {
        let amount = rawAmount.isFinite ? min(max(rawAmount, PresetAmount.range.lowerBound),
                                              PresetAmount.range.upperBound) : PresetAmount.full
        if amount == PresetAmount.full { return self }
        if amount == 0 { return base }
        var out = self
        func mix(_ a: Float, _ b: Float, _ limits: ClosedRange<Float>? = nil) -> Float {
            let v = a + (b - a) * amount
            guard let limits else { return v }
            return min(max(v, limits.lowerBound), limits.upperBound)
        }
        func mix(_ a: [Float], _ b: [Float], _ limits: ClosedRange<Float>?) -> [Float] {
            guard a.count == b.count else { return b }
            return zip(a, b).map { mix($0, $1, limits) }
        }
        func mix(_ a: ToneCurve, _ b: ToneCurve) -> ToneCurve {
            guard a.points.count == b.points.count, a != b else { return b }
            let points = zip(a.points, b.points).map { p, q in
                SIMD2<Float>(mix(p.x, q.x, 0...1), mix(p.y, q.y, 0...1))
            }
            // Mixed x positions stay ordered when both curves' were.
            return ToneCurve(points: points)
        }
        let u = PresetAmount.unit

        // White balance: only between two concrete settings. As-shot
        // stored without its numbers (a stack decoded on its own) has
        // nothing to mix from, so the preset's is taken whole.
        if !base.whiteBalance.isAsShot, !whiteBalance.isAsShot, base.whiteBalance != whiteBalance {
            out.whiteBalance = ColorKit.WhiteBalance(
                temperature: mix(base.whiteBalance.temperature, whiteBalance.temperature,
                                 ColorKit.WhiteBalance.temperatureRange),
                tint: mix(base.whiteBalance.tint, whiteBalance.tint, ColorKit.WhiteBalance.tintRange))
        }
        // Tone.
        out.exposureEV = mix(base.exposureEV, exposureEV, -5...5)
        out.contrast = mix(base.contrast, contrast, 0.5...3)
        out.toneRanges = ToneRanges(highlights: mix(base.toneRanges.highlights, toneRanges.highlights, u),
                                    shadows: mix(base.toneRanges.shadows, toneRanges.shadows, u),
                                    whites: mix(base.toneRanges.whites, toneRanges.whites, u),
                                    blacks: mix(base.toneRanges.blacks, toneRanges.blacks, u))
        // Presence and colour.
        out.texture = mix(base.texture, texture, u)
        out.clarity = mix(base.clarity, clarity, u)
        out.dehaze = mix(base.dehaze, dehaze, u)
        out.vibrance = mix(base.vibrance, vibrance, u)
        out.colour.saturation = mix(base.colour.saturation, colour.saturation, u)
        out.hsl.hue = mix(base.hsl.hue, hsl.hue, u)
        out.hsl.saturation = mix(base.hsl.saturation, hsl.saturation, u)
        out.hsl.luminance = mix(base.hsl.luminance, hsl.luminance, u)
        // Curves.
        out.toneCurve = mix(base.toneCurve, toneCurve)
        out.channelCurves = RGBCurves(red: mix(base.channelCurves.red, channelCurves.red),
                                      green: mix(base.channelCurves.green, channelCurves.green),
                                      blue: mix(base.channelCurves.blue, channelCurves.blue))
        out.curveSaturation = mix(base.curveSaturation, curveSaturation, u)
        // Split toning and colour grading: strengths, not hues.
        out.splitToning.shadowSaturation = mix(base.splitToning.shadowSaturation, splitToning.shadowSaturation, 0...1)
        out.splitToning.highlightSaturation = mix(base.splitToning.highlightSaturation,
                                                  splitToning.highlightSaturation, 0...1)
        out.colour.grading.midtones.saturation = mix(base.colour.grading.midtones.saturation,
                                                     colour.grading.midtones.saturation, 0...1)
        out.colour.grading.global.saturation = mix(base.colour.grading.global.saturation,
                                                   colour.grading.global.saturation, 0...1)
        out.colour.grading.midtones.luminance = mix(base.colour.grading.midtones.luminance,
                                                    colour.grading.midtones.luminance, u)
        out.colour.grading.global.luminance = mix(base.colour.grading.global.luminance,
                                                  colour.grading.global.luminance, u)
        out.colour.grading.shadowLuminance = mix(base.colour.grading.shadowLuminance,
                                                 colour.grading.shadowLuminance, u)
        out.colour.grading.highlightLuminance = mix(base.colour.grading.highlightLuminance,
                                                    colour.grading.highlightLuminance, u)
        // Calibration: every slider is an offset from the camera's colour.
        let c0 = base.colour.calibration, c1 = colour.calibration
        out.colour.calibration.shadowTint = mix(c0.shadowTint, c1.shadowTint, u)
        out.colour.calibration.redHue = mix(c0.redHue, c1.redHue, u)
        out.colour.calibration.redSaturation = mix(c0.redSaturation, c1.redSaturation, u)
        out.colour.calibration.greenHue = mix(c0.greenHue, c1.greenHue, u)
        out.colour.calibration.greenSaturation = mix(c0.greenSaturation, c1.greenSaturation, u)
        out.colour.calibration.blueHue = mix(c0.blueHue, c1.blueHue, u)
        out.colour.calibration.blueSaturation = mix(c0.blueSaturation, c1.blueSaturation, u)
        // Detail.
        out.sharpenAmount = mix(base.sharpenAmount, sharpenAmount, 0...2)
        out.denoiseLuminance = mix(base.denoiseLuminance, denoiseLuminance, 0...1)
        out.denoiseColor = mix(base.denoiseColor, denoiseColor, 0...1)
        // Effects.
        out.grain.amount = mix(base.grain.amount, grain.amount, 0...1)
        out.postCropVignette.amount = mix(base.postCropVignette.amount, postCropVignette.amount, u)
        // A creative profile's Amount, when the preset keeps the profile.
        if let p = profile, p.id == base.profile?.id {
            let a0 = base.profile?.amount ?? 1, a1 = p.amount ?? 1
            let a = max(mix(a0, a1), 0)
            out.profile?.amount = abs(a - 1) < 0.0005 ? nil : a
        }
        return out
    }
}

extension EditStack {
    /// The groups whose values `EditParameters.blended` mixes. Masks,
    /// crops, retouching and lens switches are taken whole.
    public static let blendableGroups: Set<EditGroup> = [.whiteBalance, .tone, .presence, .toneCurve, .colour,
                                                         .splitToning, .calibration, .detail, .effects, .profile]

    /// This stack with `preset`'s `groups` applied at `amount`. At 100% it
    /// is exactly `merged(with:groups:)`; otherwise the blendable groups
    /// are mixed from this stack's values, and everything else is still
    /// replaced whole. `defaults` fills in what either stack leaves out,
    /// as for `parameters(defaults:)`.
    public func applying(_ preset: EditStack, groups: Set<EditGroup>, amount: Float,
                         defaults: EditParameters = EditParameters()) -> EditStack {
        let full = merged(with: preset, groups: groups)
        guard amount != PresetAmount.full else { return full }
        let mixedGroups = groups.intersection(Self.blendableGroups)
        guard !mixedGroups.isEmpty else { return full }
        let blended = full.parameters(defaults: defaults).blended(from: parameters(defaults: defaults), amount: amount)
        // Only the mixed groups come from the rebuilt stack, so geometry,
        // its frame and the lens provenance stay exactly as merged.
        return full.merged(with: EditStack(parameters: blended), groups: mixedGroups)
    }
}
