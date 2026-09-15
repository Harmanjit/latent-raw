import SwiftUI
import RawCore
import ColorKit
import PixelEngine

extension EditorModel {
    // MARK: - Lens profile

    /// What the lens panel says about the open image.
    var lensProfileDescription: String {
        guard hasImage else { return "" }
        guard let c = session?.lensCorrection else {
            let lens = session?.file.summary.lens
            let spec = lens.map { l -> String in
                l.minFocal > 0 ? String(format: "%.0f-%.0fmm f/%.1f", l.minFocal, l.maxFocal,
                                        l.maxApertureAtMinFocal) : "unknown lens"
            } ?? "unknown lens"
            return "No profile found (\(spec)). Manual sliders still work."
        }
        var parts: [String] = []
        if c.distortion != nil { parts.append("distortion") }
        if c.tca != nil { parts.append("CA") }
        if c.vignetting != nil { parts.append("vignetting") }
        return "\(c.profileName) · \(parts.joined(separator: ", ")) · lensfun \(c.databaseVersion)"
    }
    var hasLensProfile: Bool { session?.lensCorrection != nil }

    // MARK: - White balance and resets

    /// The temperature slider works in negated mired rather than Kelvin, so
    /// its travel is perceptually even — see ColorKit for the reasoning.
    var temperatureSliderBinding: Binding<Float> {
        Binding(
            get: { ColorKit.sliderValue(forTemperature: self.parameters.whiteBalance.temperature) },
            set: { self.parameters.whiteBalance.temperature = ColorKit.temperature(forSliderValue: $0) }
        )
    }

    /// The slider's range, centred on this image's as-shot temperature so
    /// the starting point is always mid-travel and both directions shift by
    /// equal amounts.
    var temperatureSliderRange: ClosedRange<Float> {
        ColorKit.temperatureSliderRange(asShotTemperature: asShotWhiteBalance.temperature)
    }

    func resetWhiteBalance() {
        parameters.whiteBalance = asShotWhiteBalance
    }

    func resetAdjustments() {
        parameters = defaultParameters
    }

    /// Computes a starting point from the image and applies it. Exposure,
    /// contrast and white balance change; everything else stays.
    func autoAdjust() {
        guard let session, let pipeline, let gpuContext else { return }
        do {
            let suggestion = try AutoAdjust.suggest(for: session, pipeline: pipeline,
                                                    gpu: gpuContext, current: parameters)
            var next = parameters
            next.exposureEV = suggestion.exposureEV
            next.contrast = suggestion.contrast
            if let wb = suggestion.whiteBalance { next.whiteBalance = wb }
            parameters = next
        } catch {
            status = "Auto failed: \(error)"
        }
    }
}
