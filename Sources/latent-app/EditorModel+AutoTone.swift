import SwiftUI
import PixelEngine

extension EditorModel {
    /// Shift-double-click on Highlights, Shadows, Whites or Blacks: sets
    /// that one slider from Auto's estimate for the photo as it is now
    /// (exposure, contrast and the other three sliders kept), as Lightroom
    /// does. One history step, like any slider change.
    func autoToneSlider(_ slider: AutoTone.Slider) {
        guard let session, let pipeline, let gpuContext else { return }
        do {
            let suggestion = try AutoTone.suggest(for: session, pipeline: pipeline, gpu: gpuContext,
                                                  parameters: parameters)
            let value = AutoTone.value(for: slider, in: suggestion, current: parameters.toneRanges)
            switch slider {
            case .highlights: parameters.toneRanges.highlights = value
            case .shadows: parameters.toneRanges.shadows = value
            case .whites: parameters.toneRanges.whites = value
            case .blacks: parameters.toneRanges.blacks = value
            }
        } catch {
            status = "Auto failed: \(error)"
        }
    }
}
