import Foundation
import CoreGraphics
import PixelEngine

/// What the editor knows about the tone equalizer beyond the edit itself:
/// which tab the panel shows, whether its panel is open, Show Mask, and the
/// mask's histogram for the Advanced tab. Its own object so the editor
/// gains one stored property, and the panel observes it beside the editor.
@MainActor
final class ToneEqualizerState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case simple, advanced, masking
        var id: String { rawValue }
        var title: String {
            switch self {
            case .simple: return "Simple"
            case .advanced: return "Advanced"
            case .masking: return "Masking"
            }
        }
    }

    @Published var tab: Tab = .simple
    /// The panel is open: renders work out the mask even with every band
    /// at 0, so the histogram and the readout have something to show.
    @Published var expanded = false
    /// Show Mask: the mask in grey in place of the photo.
    @Published var showMask = false
    /// How much of the photo's mask falls at each EV over `histogramRange`
    /// (compensation applied), fullest bin 1; empty until a render made one.
    @Published var histogram: [Float] = []
    /// The mask's 5th and 95th percentiles, compensation applied, for the
    /// spread readout; nil until a render made the mask.
    @Published var spread: (low: Float, high: Float)?

    /// The mask and equalizer the histogram shown was worked out from.
    /// Renders follow every slider step while the panel is open; with the
    /// same mask and equalizer the histogram is not worked out again.
    var histogramSource: (mask: ToneEqualizerMaskSnapshot, equalizer: ToneEqualizer)?
    /// The mask's 5th and 95th percentiles before exposure, with the mask
    /// values they were read from. Sorting the 512-cell-wide mask took the
    /// main thread twice per render; now it happens once per new mask, on
    /// a background task (`percentileTask`), and the spread readout follows
    /// when it lands.
    var maskPercentiles: (values: [Float], low: Float?, high: Float?)?
    var percentileTask: Task<Void, Never>?

    /// The Advanced tab's horizontal axis, in EV.
    static let histogramRange: ClosedRange<Float> = -9.5...0.5
    static let histogramBins = 100
}

// The tone equalizer in the editor (docs/wiki/Develop.md, "Tone
// Equalizer"): the panel's actions, the mask's histogram after each
// render, and the on-image tool, which raises or lowers the band under the
// pointer by scrolling or by a vertical drag.
extension EditorModel {
    /// Whether renders for the screen should work out the mask.
    var toneEqualizerWantsMask: Bool {
        toneEqualizerState.expanded || toneEqualizerState.showMask || toneTool == .toneEqualizer
    }

    /// Sets one band's gain, clamped.
    func setToneEqualizerBand(_ index: Int, to value: Float) {
        guard ToneEqualizer.zones.indices.contains(index) else { return }
        let range = ToneEqualizer.gainRange
        var eq = parameters.toneEqualizer
        if eq.bands.count != ToneEqualizer.bandCount { eq = eq.sanitized }
        eq.bands[index] = min(max(value.isFinite ? value : 0, range.lowerBound), range.upperBound)
        parameters.toneEqualizer = eq
    }

    /// Every band back to 0 and the mask to its defaults.
    func resetToneEqualizer() {
        parameters.toneEqualizer = .neutral
    }

    /// Show Mask on or off.
    func setToneEqualizerShowsMask(_ on: Bool) {
        guard toneEqualizerState.showMask != on else { return }
        toneEqualizerState.showMask = on
        rerender()
    }

    /// The panel opened or closed: opening starts working out the mask.
    func setToneEqualizerExpanded(_ open: Bool) {
        guard toneEqualizerState.expanded != open else { return }
        let wanted = toneEqualizerWantsMask
        toneEqualizerState.expanded = open
        if toneEqualizerWantsMask != wanted, hasImage { rerender() }
    }

    /// The on-image tool, armed from the panel. Arming it disarms the other
    /// image tools, as the other targeted tools do.
    func setToneEqualizerTool(_ on: Bool) {
        let wanted = toneEqualizerWantsMask
        toneTool = on ? .toneEqualizer : (toneTool == .toneEqualizer ? .none : toneTool)
        if toneEqualizerWantsMask != wanted, hasImage { rerender() }
    }

    /// Fit Mask: the exposure and contrast compensation that spread the
    /// photo's mask over the bands.
    func fitToneEqualizerMask() {
        guard let snapshot = session?.toneEqualizerMask,
              let percentiles = toneEqualizerMaskPercentiles(snapshot) else {
            status = "The mask isn't ready yet; try again in a moment"
            return
        }
        let fit = ToneEqualizer.fittedCompensation(low: percentiles.low, high: percentiles.high)
        var eq = parameters.toneEqualizer
        eq.maskExposure = abs(fit.exposure) < 0.005 ? nil : fit.exposure
        eq.maskContrast = abs(fit.contrast) < 0.005 ? nil : fit.contrast
        parameters.toneEqualizer = eq
    }

    /// After the preview renders: the histogram and spread from the mask
    /// the render left on the session, while the panel is open.
    func toneEqualizerRenderDidFinish() {
        let state = toneEqualizerState
        guard state.expanded, let snapshot = session?.toneEqualizerMask else {
            if !state.histogram.isEmpty, session?.toneEqualizerMask == nil { state.histogram = []; state.spread = nil }
            return
        }
        let eq = parameters.toneEqualizer
        if state.histogram.isEmpty || state.histogramSource?.mask != snapshot || state.histogramSource?.equalizer != eq {
            let values = snapshot.compensatedValues(eq)
            let histogram = HistogramCalculator.normalizedHistogram(of: values, range: ToneEqualizerState.histogramRange,
                                                                    bins: ToneEqualizerState.histogramBins)
            if state.histogram != histogram { state.histogram = histogram }
            state.histogramSource = (snapshot, eq)
        }
        if let kept = state.maskPercentiles, kept.values == snapshot.values {
            showToneEqualizerSpread(low: kept.low, high: kept.high)
            return
        }
        // A new mask: its percentiles are worked out away from the main
        // thread, and shown if the mask is still the same when they land.
        state.percentileTask?.cancel()
        let values = snapshot.values
        state.percentileTask = Task { [weak self] in
            let percentiles = await Task.detached(priority: .userInitiated) {
                snapshot.valuePercentiles([0.05, 0.95])
            }.value
            guard !Task.isCancelled, let self, self.session?.toneEqualizerMask?.values == values else { return }
            let state = self.toneEqualizerState
            state.maskPercentiles = (values, percentiles[0], percentiles[1])
            state.percentileTask = nil
            self.showToneEqualizerSpread(low: percentiles[0], high: percentiles[1])
        }
    }

    /// The mask's 5th and 95th percentiles with exposure applied (Fit
    /// Mask's input): the kept ones when the mask is the one they were
    /// read from, else worked out now.
    private func toneEqualizerMaskPercentiles(_ snapshot: ToneEqualizerMaskSnapshot) -> (low: Float, high: Float)? {
        if let kept = toneEqualizerState.maskPercentiles, kept.values == snapshot.values {
            guard let low = kept.low, let high = kept.high else { return nil }
            return (low + snapshot.exposureEV, high + snapshot.exposureEV)
        }
        let percentiles = snapshot.percentiles([0.05, 0.95])
        guard let low = percentiles[0], let high = percentiles[1] else { return nil }
        return (low, high)
    }

    /// The spread readout from the mask's percentiles before exposure:
    /// the current render's exposure and compensation applied.
    private func showToneEqualizerSpread(low: Float?, high: Float?) {
        let state = toneEqualizerState
        guard let low, let high, let snapshot = session?.toneEqualizerMask else { return }
        let eq = parameters.toneEqualizer
        let spread = (eq.compensated(low + snapshot.exposureEV), eq.compensated(high + snapshot.exposureEV))
        if state.spread?.low != spread.0 || state.spread?.high != spread.1 { state.spread = spread }
    }

    /// The mask under a screen point, compensation applied; nil off the
    /// picture or before a render made the mask.
    func toneEqualizerMaskEV(atScreen screen: CGPoint) -> Float? {
        guard hasImage, toneEqualizerWantsMask || parameters.toneEqualizer.isActive,
              let snapshot = session?.toneEqualizerMask,
              let raw = snapshot.maskEV(atNormalized: sensorNormalized(screen)) else { return nil }
        return parameters.toneEqualizer.compensated(raw)
    }

    // MARK: - On the image

    /// A vertical drag with the tool armed starts: the band under the
    /// pointer, from its current gain.
    func toneEqualizerDragBegan(at screen: CGPoint) {
        guard let m = toneEqualizerMaskEV(atScreen: screen) else {
            status = "The mask isn't ready yet; try again in a moment"
            return
        }
        let band = ToneEqualizer.band(atMaskEV: m)
        let start = parameters.toneEqualizer.sanitized.bands[band]
        toneToolDrag = ToneToolDrag(origin: screen, target: .toneEqualizerBand(band, start: start))
    }

    /// Scrolling with the tool armed: the band under the pointer moves by
    /// `amount` EV. A scroll gesture settles into one undo step when it
    /// ends; a mouse wheel's notches settle a moment after the last.
    func toneEqualizerScrolled(by amount: Float, at screen: CGPoint, gestureEnded: Bool) {
        guard toneTool == .toneEqualizer else { return }
        guard amount != 0, let m = toneEqualizerMaskEV(atScreen: screen) else {
            if gestureEnded { flushPendingSave() }
            return
        }
        let band = ToneEqualizer.band(atMaskEV: m)
        let current = parameters.toneEqualizer.sanitized.bands[band]
        setToneEqualizerBand(band, to: current + amount)
        status = String(format: "Tone Equalizer: %+.0f EV band %+.2f EV", ToneEqualizer.zones[band],
                        parameters.toneEqualizer.sanitized.bands[band])
        if gestureEnded { flushPendingSave() }
    }
}
