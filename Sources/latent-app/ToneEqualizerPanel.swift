import SwiftUI
import PixelEngine

/// The Tone Equalizer (docs/wiki/Develop.md, "Tone Equalizer"), the content
/// of `DisclosureGroup("Tone Equalizer")`: three tabs, as darktable's.
/// Simple has the nine bands as vertical sliders; Advanced draws the same
/// nine values as a curve over the histogram of the mask, with nodes to
/// drag and the mask's spread; Masking sets how the mask is made. Show
/// Mask, the on-image tool and Reset sit under every tab.
struct ToneEqualizerSection: View {
    @Bindable var model: EditorModel
    @ObservedObject var state: ToneEqualizerState

    init(model: EditorModel) {
        self.model = model
        self.state = model.toneEqualizerState
    }

    private var equalizer: ToneEqualizer { model.parameter(\.toneEqualizer.sanitized) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tone Equalizer view", selection: $state.tab) {
                ForEach(ToneEqualizerState.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch state.tab {
            case .simple: simple
            case .advanced: advanced
            case .masking: masking
            }

            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { model.toneTool == .toneEqualizer },
                                     set: { model.setToneEqualizerTool($0) })) {
                    Label("On Image", systemImage: "scope")
                }
                .toggleStyle(.button)
                .help("Then scroll, or drag up or down, on the photo to raise or lower the band of the tone under the pointer")
                .accessibilityLabel("Tone equalizer on-image adjustment")
                Toggle("Show Mask", isOn: Binding(get: { state.showMask }, set: { model.setToneEqualizerShowsMask($0) }))
                    .toggleStyle(.button)
                    .help("Show the mask the bands are read from, in grey: black at −8 EV, white at 0 EV; the photo is not changed")
                    .accessibilityHint("Shows the tone equalizer's mask in place of the photo")
                Spacer()
                Button("Reset") { model.resetToneEqualizer() }
                    .disabled(equalizer.isNeutral)
                    .help("Every band back to 0 and the mask settings to their defaults")
            }
            .controlSize(.small)
        }
        .disabled(!model.hasImage)
    }

    // MARK: - Simple

    private var simple: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<ToneEqualizer.bandCount, id: \.self) { i in
                    ToneEqualizerBandSlider(value: band(i), zone: ToneEqualizer.zones[i])
                        .frame(maxWidth: .infinity)
                }
            }
            .background(ToneEqualizerBandShares(shares: state.bandShares).padding(.vertical, 14))
            Text("Each slider raises or lowers the parts of the photo whose smoothed brightness is near its stop, −8 EV (deep shadow) to 0 EV (white); the grey bars behind them show how much of the photo each one moves. Double-click a slider to reset it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                autoAlignButton
            }
        }
    }

    private func band(_ i: Int) -> Binding<Float> {
        Binding(get: { equalizer.bands[i] }, set: { model.setToneEqualizerBand(i, to: $0) })
    }

    // MARK: - Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToneEqualizerCurve(equalizer: equalizer, histogram: state.histogram,
                               setBand: { model.setToneEqualizerBand($0, to: $1) })
                .frame(height: 150)
            spreadText
            HStack {
                Spacer()
                autoAlignButton
                fitButton
            }
        }
    }

    @ViewBuilder
    private var spreadText: some View {
        if let spread = state.spread {
            let width = spread.high - spread.low
            Text(String(format: "Mask histogram spread %.1f EV (%@ to %@)", width,
                        Self.ev(spread.low), Self.ev(spread.high)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Where the middle 90% of the photo's mask lies, compensation included. The bands reach from −8 to 0 EV; a mask spread across most of that range gives each band its own part of the photo")
        } else {
            Text("The mask histogram appears once the photo has rendered")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var fitButton: some View {
        Button("Fit Mask") { model.fitToneEqualizerMask() }
            .controlSize(.small)
            .help("Sets the mask's exposure and contrast compensation so the photo's tones spread across the bands")
    }

    private var autoAlignButton: some View {
        Button("Auto Align") { model.autoAlignToneEqualizer() }
            .controlSize(.small)
            .help("Sets the mask's exposure and contrast compensation so the nine bands span the photo's tonal range: its darkest tones on the −8 EV band, its brightest on the 0 EV band")
    }

    static func ev(_ v: Float) -> String {
        String(format: "%+.1f", v).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    // MARK: - Masking

    private var masking: some View {
        VStack(alignment: .leading, spacing: 10) {
            maskRow("Mask Exposure", value: Binding(
                get: { equalizer.exposureCompensation },
                set: { v in model.parameters.toneEqualizer.maskExposure = abs(v) < 0.005 ? nil : v }),
                range: ToneEqualizer.maskExposureRange, format: "%+.2f EV", defaultValue: 0,
                hint: "Slides the mask up or down the bands, so the photo's tones land where you want them")
            maskRow("Mask Contrast", value: Binding(
                get: { equalizer.contrastCompensation },
                set: { v in model.parameters.toneEqualizer.maskContrast = abs(v) < 0.005 ? nil : v }),
                range: ToneEqualizer.maskContrastRange, format: "%+.2f", defaultValue: 0,
                hint: "Stretches the mask about −4 EV so it covers more bands (+), or squeezes it (−)")
            maskRow("Smoothing", value: Binding(
                get: { equalizer.smoothingAmount },
                set: { v in model.parameters.toneEqualizer.smoothing = v == ToneEqualizer.defaultSmoothing ? nil : v }),
                range: 0...1, format: "%.2f", defaultValue: ToneEqualizer.defaultSmoothing,
                hint: "How large an area the mask averages over: more keeps more local contrast inside each region")
            maskRow("Edge Refinement", value: Binding(
                get: { equalizer.edgeRefinementAmount },
                set: { v in model.parameters.toneEqualizer.edgeRefinement = v == ToneEqualizer.defaultEdgeRefinement ? nil : v }),
                range: 0...1, format: "%.2f", defaultValue: ToneEqualizer.defaultEdgeRefinement,
                hint: "How closely the mask follows edges: more stops a change spilling across an edge as a halo")
            spreadText
            HStack {
                Spacer()
                autoAlignButton
                fitButton
            }
        }
    }

    private func maskRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, format: String,
                         defaultValue: Float, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: range, format: SliderValueFormat(printf: format), label: title)
            }
            ResettableSlider(value: value, in: range, label: title, format: SliderValueFormat(printf: format)) {
                value.wrappedValue = defaultValue
            }
            .help(hint + ". Double-click to reset")
        }
    }
}

/// One band of the Simple tab: a vertical slider, the gain above it and
/// the band's stop below. Double-click resets it to 0.
struct ToneEqualizerBandSlider: View {
    @Binding var value: Float
    let zone: Float

    /// The slider's track height; the mask strip passes a shorter one.
    var height: CGFloat = 120

    private static let range = ToneEqualizer.gainRange

    var body: some View {
        VStack(spacing: 3) {
            Text(String(format: value == 0 ? "0" : "%+.1f", value).replacingOccurrences(of: "-", with: "\u{2212}"))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)
            GeometryReader { geo in
                let midX = geo.size.width / 2
                ZStack {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 4)
                    Rectangle().fill(Color.secondary.opacity(0.6))
                        .frame(width: 12, height: 1)
                        .position(x: midX, y: geo.size.height / 2)
                    Path { p in
                        p.move(to: CGPoint(x: midX, y: geo.size.height / 2))
                        p.addLine(to: CGPoint(x: midX, y: y(for: value, height: geo.size.height)))
                    }
                    .stroke(Color.accentColor, lineWidth: 4)
                    Circle().fill(Color.accentColor)
                        .frame(width: 11, height: 11)
                        .position(x: midX, y: y(for: value, height: geo.size.height))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    value = Self.value(at: g.location.y, height: geo.size.height)
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            }
            .frame(height: height)
            Text(zone == 0 ? "0" : String(format: "%.0f", zone).replacingOccurrences(of: "-", with: "\u{2212}"))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(String(format: "The %.0f EV band: drag up to brighten, down to darken. Double-click to reset", zone))
        .accessibilityElement()
        .accessibilityLabel(String(format: "%.0f EV band", zone))
        .accessibilityValue(String(format: "%+.1f EV", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.1, Self.range.upperBound)
            case .decrement: value = max(value - 0.1, Self.range.lowerBound)
            @unknown default: break
            }
        }
    }

    private func y(for v: Float, height: CGFloat) -> CGFloat {
        let t = CGFloat((v - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound))
        return height * (1 - t)
    }

    static func value(at y: CGFloat, height: CGFloat) -> Float {
        guard height > 0 else { return 0 }
        let t = Float(1 - min(max(y / height, 0), 1))
        let v = range.lowerBound + t * (range.upperBound - range.lowerBound)
        // Snap to 0 near the middle, and to tenths elsewhere.
        let rounded = (v * 10).rounded() / 10
        return abs(rounded) < 0.05 ? 0 : rounded
    }
}

/// Behind the Simple tab's sliders: one grey bar per band, as tall as the
/// share of the photo that band reads (the tallest band full height), so
/// it shows at a glance which sliders have something to move. Updated
/// after renders from the mask's statistics (`ToneEqualizerState`).
struct ToneEqualizerBandShares: View {
    let shares: [Float]

    /// Each bar's height as a fraction of the full height: shares scaled
    /// so the largest is 1; zeros when there is nothing to show.
    static func heights(_ shares: [Float]) -> [CGFloat] {
        let peak = shares.max() ?? 0
        guard peak > 0 else { return shares.map { _ in 0 } }
        return shares.map { CGFloat(max($0, 0) / peak) }
    }

    var body: some View {
        GeometryReader { geo in
            let heights = Self.heights(shares)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(heights.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: geo.size.height * heights[i])
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.2), value: shares)
    }
}

/// The Advanced tab: the gain curve the nine bands make, over the mask's
/// histogram, with a node per band to drag up or down.
struct ToneEqualizerCurve: View {
    let equalizer: ToneEqualizer
    let histogram: [Float]
    let setBand: (Int, Float) -> Void
    @State private var dragging: Int?

    private static let evRange = ToneEqualizerState.histogramRange
    private static let gainRange = ToneEqualizer.gainRange

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { context, _ in
                let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
                context.fill(bg, with: .color(Color.secondary.opacity(0.08)))
                // Histogram of the mask.
                if !histogram.isEmpty {
                    var h = Path()
                    h.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in histogram.enumerated() {
                        let x = size.width * (CGFloat(i) + 0.5) / CGFloat(histogram.count)
                        h.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v) * 0.9)))
                    }
                    h.addLine(to: CGPoint(x: size.width, y: size.height))
                    h.closeSubpath()
                    context.fill(h, with: .color(Color.secondary.opacity(0.35)))
                }
                // Band stops and the zero line.
                for zone in ToneEqualizer.zones {
                    var line = Path()
                    let x = Self.x(zone, size.width)
                    line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(Color.secondary.opacity(0.15)), lineWidth: 1)
                }
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: size.height / 2)); zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(zero, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
                // The curve.
                var curve = Path()
                let steps = 120
                for s in 0...steps {
                    let ev = Self.evRange.lowerBound + (Self.evRange.upperBound - Self.evRange.lowerBound) * Float(s) / Float(steps)
                    let p = CGPoint(x: Self.x(ev, size.width), y: Self.y(equalizer.gain(atMaskEV: ev), size.height))
                    if s == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
                // Nodes, at each band's own value.
                for (i, zone) in ToneEqualizer.zones.enumerated() {
                    let c = CGPoint(x: Self.x(zone, size.width), y: Self.y(equalizer.bands[i], size.height))
                    let r: CGFloat = dragging == i ? 5 : 4
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(.accentColor))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let band = dragging ?? Self.band(atX: g.startLocation.x, width: size.width)
                    dragging = band
                    setBand(band, Self.gain(atY: g.location.y, height: size.height))
                }
                .onEnded { _ in dragging = nil })
        }
        .help("The gain each tone gets, over the histogram of the mask (−9.5 to +0.5 EV across). Drag a node up or down to raise or lower its band")
        .accessibilityElement()
        .accessibilityLabel("Tone equalizer curve")
        .accessibilityValue(equalizer.bands.enumerated()
            .map { String(format: "%.0f EV %+.1f", ToneEqualizer.zones[$0.offset], $0.element) }
            .joined(separator: ", "))
    }

    static func x(_ ev: Float, _ width: CGFloat) -> CGFloat {
        width * CGFloat((ev - evRange.lowerBound) / (evRange.upperBound - evRange.lowerBound))
    }

    static func y(_ gain: Float, _ height: CGFloat) -> CGFloat {
        height * (1 - CGFloat((gain - gainRange.lowerBound) / (gainRange.upperBound - gainRange.lowerBound)))
    }

    static func band(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let ev = evRange.lowerBound + Float(x / width) * (evRange.upperBound - evRange.lowerBound)
        return ToneEqualizer.band(atMaskEV: ev)
    }

    static func gain(atY y: CGFloat, height: CGFloat) -> Float {
        ToneEqualizerBandSlider.value(at: y, height: height)
    }
}

/// The panel's disclosure group, observing the equalizer's state so the
/// open or closed state redraws, and so opening it starts the mask (its
/// histogram and the readout need one even with every band at 0).
struct ToneEqualizerDisclosure<Label: View>: View {
    @Bindable var model: EditorModel
    @ObservedObject var state: ToneEqualizerState
    let label: Label

    init(model: EditorModel, @ViewBuilder label: () -> Label) {
        self.model = model
        self.state = model.toneEqualizerState
        self.label = label()
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { state.expanded }, set: { model.setToneEqualizerExpanded($0) })) {
            ToneEqualizerSection(model: model).padding(.top, 8)
        } label: {
            label
        }
    }
}
