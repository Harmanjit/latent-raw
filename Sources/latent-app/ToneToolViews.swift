import SwiftUI
import ColorKit
import PixelEngine

// The White Balance menu and selector, the Tone Curve's region mode,
// presets and Refine Saturation, the targeted adjustment buttons, the
// pointer readout, the clipping switches and the draggable histogram.
// The model side is EditorModel+ToneTools.swift.

// MARK: - White balance

/// The White Balance menu (As Shot, Auto, the light sources) and the
/// selector, above the Temperature and Tint sliders.
struct WhiteBalancePresetRow: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("White balance", selection: Binding(
                get: { model.whiteBalancePreset?.rawValue ?? "custom" },
                set: { raw in WhiteBalancePreset(rawValue: raw).map(model.applyWhiteBalancePreset) })) {
                ForEach(WhiteBalancePreset.allCases) { Text($0.title).tag($0.rawValue) }
                if model.whiteBalancePreset == nil {
                    Divider()
                    Text("Custom").tag("custom")
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("White balance")
            .help("A starting point: the camera's setting, an estimate from the picture, or a light source")

            Spacer()

            Toggle(isOn: Binding(get: { model.toneTool == .whiteBalance },
                                 set: { model.toneTool = $0 ? .whiteBalance : .none })) {
                Image(systemName: "eyedropper")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .accessibilityLabel("White balance selector")
            .help("White Balance Selector (W): click something in the photo that should be neutral grey")
        }
        .disabled(!model.hasImage)
    }
}

/// Shown over the image while a tone tool is armed, so the click it is
/// waiting for is never a surprise. Doesn't take the mouse.
struct ToneToolHint: View {
    let tool: ToneTool

    var body: some View {
        VStack {
            Text(tool.hint)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
            Spacer()
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Targeted adjustment

/// The Tone Curve's targeted tool switch.
struct CurveTargetButton: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.toneTool == .curve },
                             set: { model.toneTool = $0 ? .curve : .none })) {
            Label("Target", systemImage: "scope")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .accessibilityLabel("Tone curve targeted adjustment")
        .help("Targeted adjustment: drag up or down on the photo to lighten or darken that tone on the curve showing (points or regions)")
        .disabled(!model.hasImage)
    }
}

/// The HSL panel's targeted tool: which of hue, saturation or luminance
/// a drag on the photo changes, or off.
struct HSLTargetRow: View {
    @ObservedObject var model: EditorModel

    private var selection: Binding<Int> {
        Binding(get: {
            if case .colour(let c) = model.toneTool { return c.rawValue }
            return -1
        }, set: { raw in
            model.toneTool = HSLComponent(rawValue: raw).map { .colour($0) } ?? .none
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Targeted adjustment", selection: selection) {
                Text("Off").tag(-1)
                ForEach(HSLComponent.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .accessibilityLabel("Colour targeted adjustment")
            .help("Targeted adjustment: pick hue, saturation or luminance, then drag up or down on a colour in the photo")
        }
        .disabled(!model.hasImage)
    }
}

// MARK: - Tone Curve

/// The Tone Curve group: point or region editor, presets, the targeted
/// tool and Refine Saturation.
struct ToneCurveControls: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Curve editor", selection: $model.curveEditorMode) {
                    ForEach(CurveEditorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Curve editor")
                .help("Point curve, or the region curve's four sliders")
                Spacer()
                CurveTargetButton(model: model)
            }

            switch model.curveEditorMode {
            case .point:
                presetRow
                ToneCurvePanel(master: $model.parameters.toneCurve, channels: $model.parameters.channelCurves)
                if !model.parameters.parametricCurve.isNeutral {
                    Text("The region curve is also on; it applies before these points.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .parametric:
                ParametricCurvePanel(curve: $model.parameters.parametricCurve)
            }

            refineSaturationRow
        }
        .disabled(!model.hasImage)
    }

    private var presetRow: some View {
        HStack {
            Text("Point Curve").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Spacer()
            Picker("Point curve preset", selection: Binding(
                get: { ToneCurve.Preset.matching(model.parameters.toneCurve)?.rawValue ?? "custom" },
                set: { raw in
                    if let preset = ToneCurve.Preset(rawValue: raw) { model.parameters.toneCurve = preset.curve }
                })) {
                ForEach(ToneCurve.Preset.allCases) { Text($0.title).tag($0.rawValue) }
                if ToneCurve.Preset.matching(model.parameters.toneCurve) == nil {
                    Divider()
                    Text("Custom").tag("custom")
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Point curve preset")
            .help("Start the RGB point curve from Linear, Medium Contrast or Strong Contrast")
        }
    }

    private var refineSaturationRow: some View {
        let format = SliderValueFormat(decimals: 0, signed: true, scale: 100)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Refine Saturation").font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: $model.parameters.curveSaturation, in: -1...1, format: format,
                                 label: "Refine Saturation")
            }
            ResettableSlider(value: $model.parameters.curveSaturation, in: -1...1, label: "Refine Saturation",
                             format: format) { model.parameters.curveSaturation = 0 }
                .help("How much colour the curve's contrast adds: left keeps only its brightness change, right strengthens it. Double-click to reset")
        }
    }
}

/// The region curve: a graph showing the curve and its four regions,
/// three split handles under it, and the four sliders, Highlights at the
/// top as in Lightroom.
struct ParametricCurvePanel: View {
    @Binding var curve: ParametricCurve
    @State private var draggingSplit: Int?

    private let handleHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: geo.size.width)
                VStack(spacing: 2) {
                    Canvas { context, size in draw(&context, size) }
                        .frame(width: size.width, height: size.height)
                        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityElement()
                        .accessibilityLabel("Region curve")
                        .accessibilityValue(curve.isNeutral ? "Linear" : summary)
                    splitHandles(width: size.width)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.bottom, handleHeight + 2)

            ForEach(ParametricCurve.Region.allCases.reversed(), id: \.rawValue) { region in
                row(region)
            }
            HStack {
                Text("Drag the triangles to move where the regions meet")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Reset") { curve = .neutral }
                    .controlSize(.mini)
                    .disabled(curve == .neutral)
                    .help("All four sliders to zero and the splits back to quarters")
            }
        }
    }

    private var summary: String {
        ParametricCurve.Region.allCases.map { "\($0.title) \(Int((curve.amounts[$0.rawValue] * 100).rounded()))" }
            .joined(separator: ", ")
    }

    private func row(_ region: ParametricCurve.Region) -> some View {
        let format = SliderValueFormat(decimals: 0, signed: true, scale: 100)
        let value = Binding<Float>(get: { curve.amounts[region.rawValue] },
                                   set: { v in var a = curve.amounts; a[region.rawValue] = v; curve.amounts = a })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(region.title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: -1...1, format: format, label: region.title)
            }
            ResettableSlider(value: value, in: -1...1, label: region.title, format: format) { value.wrappedValue = 0 }
                .help("Double-click to reset")
        }
    }

    /// The strip under the graph. A drag anywhere on it takes the split
    /// nearest where it started, so a handle is easy to catch.
    private func splitHandles(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: handleHeight).contentShape(Rectangle())
            ForEach(0..<3, id: \.self) { i in
                Triangle()
                    .fill(draggingSplit == i ? Color.accentColor : Color.secondary)
                    .frame(width: handleHeight, height: handleHeight)
                    .offset(x: CGFloat(curve.splits[i]) * width - handleHeight / 2)
                    .onTapGesture(count: 2) { curve.setSplit(i, to: ParametricCurve.defaultSplits[i]) }
                    .accessibilityElement()
                    .accessibilityLabel(Self.splitNames[i])
                    .accessibilityValue("\(Int((curve.splits[i] * 100).rounded())) percent")
                    .accessibilityAdjustableAction { direction in
                        let step: Float = direction == .increment ? 0.05 : -0.05
                        curve.setSplit(i, to: curve.splits[i] + step)
                    }
                    .help("\(Self.splitNames[i]): drag to move, double-click to put back")
            }
        }
        .frame(width: width, height: handleHeight, alignment: .topLeading)
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let w = max(width, 1)
                if draggingSplit == nil {
                    let start = Float(value.startLocation.x / w)
                    draggingSplit = (0..<3).min { abs(curve.splits[$0] - start) < abs(curve.splits[$1] - start) }
                }
                guard let i = draggingSplit else { return }
                curve.setSplit(i, to: Float(min(max(value.location.x / w, 0), 1)))
            }
            .onEnded { _ in draggingSplit = nil })
    }

    private static let splitNames = ["Shadows and Darks split", "Darks and Lights split", "Lights and Highlights split"]

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let s = curve.sanitized.splits
        let edges: [CGFloat] = [0, CGFloat(s.x), CGFloat(s.y), CGFloat(s.z), 1]
        // Alternate shading marks the regions.
        for i in 0..<4 where i % 2 == 0 {
            let rect = CGRect(x: edges[i] * size.width, y: 0,
                              width: (edges[i + 1] - edges[i]) * size.width, height: size.height)
            context.fill(Path(rect), with: .color(Color(white: 1, opacity: 0.04)))
        }
        var grid = Path()
        for f in [0.25, 0.5, 0.75] {
            grid.move(to: CGPoint(x: 0, y: size.height * f)); grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
        }
        for e in edges.dropFirst().dropLast() {
            grid.move(to: CGPoint(x: e * size.width, y: 0)); grid.addLine(to: CGPoint(x: e * size.width, y: size.height))
        }
        context.stroke(grid, with: .color(Color(white: 0.22)), lineWidth: 0.5)
        var diag = Path()
        diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diag, with: .color(Color(white: 0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        let lut = curve.lookupTable()
        var path = Path()
        for (i, y) in lut.enumerated() {
            let pt = CGPoint(x: CGFloat(i) / CGFloat(lut.count - 1) * size.width, y: (1 - CGFloat(y)) * size.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Readout and clipping

/// Under the histogram: the colour under the pointer, and the two
/// clipping switches (J turns both on or off).
struct PixelReadoutBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            clipToggle(.shadows, title: "Shadows", systemImage: "triangle.bottomhalf.filled",
                       help: "Show crushed shadows in blue (J shows both)")
            PixelReadoutText(probe: model.pixelProbe)
            Spacer(minLength: 0)
            clipToggle(.highlights, title: "Highlights", systemImage: "triangle.tophalf.filled",
                       help: "Show clipped highlights in red (J shows both)")
        }
        .disabled(!model.hasImage)
    }

    private func clipToggle(_ indicator: ClippingIndicators, title: String, systemImage: String,
                            help: String) -> some View {
        Toggle(isOn: Binding(get: { model.clipping.contains(indicator) },
                             set: { on in
                                 if on { model.clipping.insert(indicator) } else { model.clipping.remove(indicator) }
                             })) {
            Image(systemName: systemImage)
        }
        .toggleStyle(.button)
        .controlSize(.mini)
        .accessibilityLabel("Show \(title.lowercased()) clipping")
        .help(help)
    }
}

/// The readout itself, observing only the probe so pointer moves don't
/// redraw the panel around it.
struct PixelReadoutText: View {
    @ObservedObject var probe: PixelProbe

    var body: some View {
        Group {
            if let r = probe.readout {
                let p = r.percent, lab = r.lab
                // Above SDR white (an HDR view), how far, as Lightroom's
                // HDR readout does; RGB itself stays on the 0–100 scale.
                let hdr = r.stopsAboveSDRWhite.map { String(format: "   +%.1f stops", $0) } ?? ""
                Text(String(format: "R %.0f  G %.0f  B %.0f %%   L %.0f  a %.0f  b %.0f",
                            p.x, p.y, p.z, lab.x, lab.y, lab.z) + hdr)
            } else {
                Text("Point at the photo for its colour")
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .help("The colour under the pointer as shown: RGB in percent, CIE Lab (D50), and in an HDR view how many stops above SDR white it is")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Colour under the pointer")
    }
}

// MARK: - Draggable histogram

/// Over the histogram: drag sideways in a region of it to move the
/// slider that region belongs to, as in Lightroom: Blacks, Shadows,
/// Exposure, Highlights, Whites from left to right. Hovering names the
/// region.
struct HistogramAdjustOverlay: View {
    @ObservedObject var model: EditorModel
    @State private var hovered: HistogramRegion?
    @State private var drag: (region: HistogramRegion, start: Float)?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let region = drag?.region ?? hovered {
                    let span = region.span
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: geo.size.width * CGFloat(span.upperBound - span.lowerBound))
                        .offset(x: geo.size.width * CGFloat(span.lowerBound))
                    Text(region.title + valueText(region))
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = HistogramRegion.at(Float(p.x / max(geo.size.width, 1)))
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard model.hasImage else { return }
                            if drag == nil {
                                let region = HistogramRegion.at(Float(value.startLocation.x / max(geo.size.width, 1)))
                                drag = (region, region.value(in: model.parameters))
                            }
                            guard let drag else { return }
                            let moved = Float(value.translation.width / max(geo.size.width, 1))
                            drag.region.set(drag.start + moved * drag.region.dragScale, in: &model.parameters)
                        }
                        .onEnded { _ in drag = nil })
            }
        }
        .help("Drag sideways to adjust Blacks, Shadows, Exposure, Highlights or Whites, by where you start")
        // The same five sliders are in the Tone group, where VoiceOver
        // reaches them; this is a pointer shortcut to them.
        .accessibilityHidden(true)
    }

    private func valueText(_ region: HistogramRegion) -> String {
        let v = region.value(in: model.parameters)
        return region == .exposure ? String(format: " %+.2f EV", v) : String(format: " %+.0f", v * 100)
    }
}

/// The five stretches of the histogram and the slider each drives.
enum HistogramRegion: CaseIterable, Equatable {
    case blacks, shadows, exposure, highlights, whites

    var title: String {
        switch self {
        case .blacks: return "Blacks"
        case .shadows: return "Shadows"
        case .exposure: return "Exposure"
        case .highlights: return "Highlights"
        case .whites: return "Whites"
        }
    }

    /// Where it sits along the histogram, 0…1.
    var span: ClosedRange<Float> {
        switch self {
        case .blacks: return 0...0.1
        case .shadows: return 0.1...0.35
        case .exposure: return 0.35...0.65
        case .highlights: return 0.65...0.9
        case .whites: return 0.9...1
        }
    }

    static func at(_ x: Float) -> HistogramRegion {
        allCases.first { x < $0.span.upperBound } ?? .whites
    }

    /// Change per histogram width dragged: the whole width is a slider's
    /// full travel, or four stops of exposure.
    var dragScale: Float { self == .exposure ? 4 : 2 }

    func value(in p: EditParameters) -> Float {
        switch self {
        case .blacks: return p.toneRanges.blacks
        case .shadows: return p.toneRanges.shadows
        case .exposure: return p.exposureEV
        case .highlights: return p.toneRanges.highlights
        case .whites: return p.toneRanges.whites
        }
    }

    func set(_ value: Float, in p: inout EditParameters) {
        let v = min(max(value, -1), 1)
        switch self {
        case .blacks: p.toneRanges.blacks = v
        case .shadows: p.toneRanges.shadows = v
        case .exposure: p.exposureEV = min(max(value, -5), 5)
        case .highlights: p.toneRanges.highlights = v
        case .whites: p.toneRanges.whites = v
        }
    }
}
