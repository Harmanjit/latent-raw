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
    /// The share of the photo each of the nine bands reads (0…1, summing
    /// to 1), drawn behind the Simple tab's sliders; empty until a render
    /// made the mask.
    @Published var bandShares: [Float] = []

    /// The latest mask's statistics, built off the main thread once per
    /// new mask (`ToneEqualizerMaskStats`); the histogram, the spread and
    /// the band shares are derived from it for the current compensation.
    var stats: ToneEqualizerMaskStats?
    /// The snapshot generation `stats` was built from.
    var statsGeneration: Int?
    /// The exposure of the latest mask snapshot, added when deriving.
    var statsExposureEV: Float = 0
    /// A statistics build is running; renders meanwhile only note that a
    /// newer mask is waiting, so a burst of renders costs one build at a
    /// time and the newest mask is always built last (the throttle).
    var statsBuildInFlight = false

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
              let low = snapshot.percentile(0.05), let high = snapshot.percentile(0.95) else {
            status = "The mask isn't ready yet; try again in a moment"
            return
        }
        let fit = ToneEqualizer.fittedCompensation(low: low, high: high)
        var eq = parameters.toneEqualizer
        eq.maskExposure = abs(fit.exposure) < 0.005 ? nil : fit.exposure
        eq.maskContrast = abs(fit.contrast) < 0.005 ? nil : fit.contrast
        parameters.toneEqualizer = eq
    }

    /// Auto Align: the mask exposure and contrast compensation that put the
    /// photo's darkest tones on the −8 EV band and its brightest on the
    /// 0 EV band (`ToneEqualizer.autoAlignedCompensation`).
    func autoAlignToneEqualizer() {
        let state = toneEqualizerState
        guard let snapshot = session?.toneEqualizerMask else {
            status = "The mask isn't ready yet; try again in a moment"
            return
        }
        if state.stats == nil || state.statsGeneration != snapshot.generation {
            // The panel's statistics lag the mask: build them now (a click,
            // not a drag, so one pass over the mask here is fine).
            state.stats = ToneEqualizerMaskStats(snapshot: snapshot)
            state.statsGeneration = snapshot.generation
        }
        state.statsExposureEV = snapshot.exposureEV
        guard let stats = state.stats else { return }
        applyToneEqualizerAutoAlign(stats: stats, exposureEV: snapshot.exposureEV)
    }

    /// Auto Align from given statistics (the testable half of
    /// `autoAlignToneEqualizer`): sets the compensation, bands untouched.
    func applyToneEqualizerAutoAlign(stats: ToneEqualizerMaskStats, exposureEV: Float) {
        guard let fit = ToneEqualizer.autoAlignedCompensation(stats: stats, exposureEV: exposureEV) else {
            status = "The mask isn't ready yet; try again in a moment"
            return
        }
        parameters.toneEqualizer = parameters.toneEqualizer.withCompensation(exposure: fit.exposure,
                                                                              contrast: fit.contrast)
    }

    /// After the preview renders, while the panel is open: starts building
    /// the new mask's statistics in the background when the mask changed,
    /// and redraws the histogram, spread and band shares for the current
    /// compensation from the statistics it has.
    func toneEqualizerRenderDidFinish() {
        let state = toneEqualizerState
        guard state.expanded, let snapshot = session?.toneEqualizerMask else {
            if session?.toneEqualizerMask == nil, state.stats != nil || !state.histogram.isEmpty {
                state.stats = nil; state.statsGeneration = nil
                state.histogram = []; state.spread = nil; state.bandShares = []
            }
            return
        }
        state.statsExposureEV = snapshot.exposureEV
        if state.statsGeneration != snapshot.generation { buildToneEqualizerStats() }
        refreshToneEqualizerHistogram()
    }

    /// Builds the latest mask's statistics off the main thread, one build
    /// at a time; when it lands and the mask has moved on meanwhile, builds
    /// again for the newest.
    private func buildToneEqualizerStats() {
        let state = toneEqualizerState
        guard !state.statsBuildInFlight, let snapshot = session?.toneEqualizerMask else { return }
        state.statsBuildInFlight = true
        let values = snapshot.values, generation = snapshot.generation
        Task { [weak self] in
            let stats = await Task.detached(priority: .utility) { ToneEqualizerMaskStats(values: values) }.value
            guard let self else { return }
            let state = self.toneEqualizerState
            state.statsBuildInFlight = false
            guard let latest = self.session?.toneEqualizerMask else { return }
            if latest.generation == generation {
                state.stats = stats
                state.statsGeneration = generation
                state.statsExposureEV = latest.exposureEV
                self.refreshToneEqualizerHistogram()
            } else if state.expanded {
                self.buildToneEqualizerStats()
            }
        }
    }

    /// The histogram, spread and band shares for the current exposure and
    /// compensation, from the statistics: a few thousand operations, so
    /// cheap enough for every render while a slider is dragged.
    func refreshToneEqualizerHistogram() {
        let state = toneEqualizerState
        guard let stats = state.stats else { return }
        let eq = parameters.toneEqualizer
        let ev = state.statsExposureEV
        let histogram = stats.histogram(equalizer: eq, exposureEV: ev, range: ToneEqualizerState.histogramRange,
                                        bins: ToneEqualizerState.histogramBins)
        if state.histogram != histogram { state.histogram = histogram }
        let shares = stats.bandShares(equalizer: eq, exposureEV: ev)
        if state.bandShares != shares { state.bandShares = shares }
        if let low = stats.percentile(0.05, exposureEV: ev), let high = stats.percentile(0.95, exposureEV: ev) {
            let spread = (eq.compensated(low), eq.compensated(high))
            if state.spread?.low != spread.0 || state.spread?.high != spread.1 { state.spread = spread }
        }
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
