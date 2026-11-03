import SwiftUI
import PixelEngine
import MLKit

/// One slider row as the Local Adjustments panel draws them: title, value
/// field, slider; double-click puts `defaultValue` back.
struct LocalSliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String
    var defaultValue: Float = 0
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: $value, in: range, format: SliderValueFormat(printf: format), label: title)
            }
            ResettableSlider(value: $value, in: range, label: title,
                             format: SliderValueFormat(printf: format)) {
                value = LocalAdjustmentsPanel.resetValue(defaultValue, in: range)
            }
        }
        .help(help ?? "")
    }
}

/// The selected mask's sliders in Lightroom's four groups. Light and
/// Colour start open; Effects and Detail open once used.
struct LocalSliderGroups: View {
    @Binding var local: LocalAdjustment
    @State private var effectsOpen = false
    @State private var detailOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalSliderRow(title: "Amount", value: $local.amount, range: 0...1, format: "%.2f",
                           defaultValue: 1, help: "How strongly this mask applies all its sliders")
            group("Light")
            LocalSliderRow(title: "Exposure", value: $local.exposureEV, range: -3...3, format: "%+.2f EV")
            LocalSliderRow(title: "Contrast", value: $local.contrast, range: -1...1, format: "%+.2f")
            LocalSliderRow(title: "Highlights", value: $local.highlights, range: -1...1, format: "%+.2f",
                           help: "Brightens or darkens the bright tones inside the mask")
            LocalSliderRow(title: "Shadows", value: $local.shadows, range: -1...1, format: "%+.2f",
                           help: "Brightens or darkens the dark tones inside the mask")
            LocalSliderRow(title: "Whites", value: $local.whites, range: -1...1, format: "%+.2f",
                           help: "Moves the brightest tones inside the mask")
            LocalSliderRow(title: "Blacks", value: $local.blacks, range: -1...1, format: "%+.2f",
                           help: "Moves the darkest tones inside the mask")
            group("Colour")
            LocalSliderRow(title: "Temperature", value: $local.warmth, range: -1...1, format: "%+.2f",
                           help: "Cooler (blue) or warmer (yellow) inside the mask")
            LocalSliderRow(title: "Tint", value: $local.tint, range: -1...1, format: "%+.2f",
                           help: "Greener or more magenta inside the mask")
            LocalSliderRow(title: "Hue", value: $local.hue, range: -180...180, format: "%+.0f°",
                           help: "Turns every colour inside the mask around the colour wheel")
            LocalSliderRow(title: "Saturation", value: $local.saturation, range: -1...1, format: "%+.2f")
            DisclosureGroup(isExpanded: Binding(get: { effectsOpen || effectsUsed }, set: { effectsOpen = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    LocalSliderRow(title: "Texture", value: $local.texture, range: -1...1, format: "%+.2f",
                                   help: "Fine detail inside the mask: more, or smoothed")
                    LocalSliderRow(title: "Clarity", value: $local.clarity, range: -1...1, format: "%+.2f",
                                   help: "Midtone contrast at a larger scale inside the mask")
                    LocalSliderRow(title: "Dehaze", value: $local.dehaze, range: -1...1, format: "%+.2f",
                                   help: "Removes or adds haze inside the mask")
                }
                .padding(.top, 4)
            } label: { Text("Effects").font(.caption.weight(.semibold)) }
            .accessibilityLabel("Effects sliders")
            DisclosureGroup(isExpanded: Binding(get: { detailOpen || detailUsed }, set: { detailOpen = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    LocalSliderRow(title: "Sharpness", value: $local.sharpness, range: -1...1, format: "%+.2f",
                                   help: "Sharpens fine detail inside the mask; below zero, softens it")
                    LocalSliderRow(title: "Noise", value: $local.noise, range: 0...1, format: "%.2f",
                                   help: "Smooths luminance noise in flat areas inside the mask")
                    LocalSliderRow(title: "Defringe", value: $local.defringe, range: 0...1, format: "%.2f",
                                   help: "Removes purple and green fringes on edges inside the mask")
                }
                .padding(.top, 4)
            } label: { Text("Detail").font(.caption.weight(.semibold)) }
            .accessibilityLabel("Detail sliders")
        }
    }

    private var effectsUsed: Bool { local.texture != 0 || local.clarity != 0 || local.dehaze != 0 }
    private var detailUsed: Bool { local.sharpness != 0 || local.noise != 0 || local.defringe != 0 }

    private func group(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The mask's components: its first shape, then each added, subtracted
/// or intersected one. Selecting a row points the mask tools at it.
struct MaskComponentList: View {
    @ObservedObject var model: EditorModel
    let index: Int

    var body: some View {
        let local = model.parameters.locals[index]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Components").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ForEach(MaskCombineMode.allCases, id: \.self) { mode in
                    addMenu(mode)
                }
            }
            row(id: nil, title: local.shape.componentName, mode: nil, invert: local.invert)
            ForEach(local.components) { component in
                row(id: component.id, title: component.displayName, mode: component.mode, invert: component.invert)
            }
        }
    }

    private func addMenu(_ mode: MaskCombineMode) -> some View {
        Menu {
            Button("Brush") { model.addMaskComponent(.brush, mode: mode) }
            Button("Linear Gradient") { model.addMaskComponent(.linear, mode: mode) }
            Button("Radial Gradient") { model.addMaskComponent(.radial, mode: mode) }
            Button("Colour Range") { model.addMaskComponent(.colourRange, mode: mode) }
            Button("Luminance Range") { model.addMaskComponent(.luminanceRange, mode: mode) }
            Divider()
            if let subject = ModelMenus.defaultEntry(kind: .subjectSegmentation, registry: .shared) {
                Button("Subject") { model.addMaskComponent(.subject(subject), mode: mode) }
            }
            Menu("Select by Class") {
                ForEach(AIMaskKind.allCases.filter { $0 != .subject }, id: \.self) { kind in
                    Button(kind.displayName) { model.addMaskComponent(.aiClass(kind), mode: mode) }
                }
            }
            if let prompted = ModelMenus.defaultEntry(kind: .promptedSegmentation, registry: .shared) {
                Button("Click to Select") { model.addMaskComponent(.clickToSelect(prompted), mode: mode) }
                Button("Select Objects (Box)") { model.addMaskComponent(.objects(prompted), mode: mode) }
            }
        } label: {
            Image(systemName: mode == .add ? "plus.circle" : mode == .subtract ? "minus.circle" : "circle.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.canAddMaskComponent)
        .help("\(mode.displayName): combine another shape or range with this mask")
        .accessibilityLabel("\(mode.displayName) a component")
    }

    private func row(id: UUID?, title: String, mode: MaskCombineMode?, invert: Bool) -> some View {
        let selected = model.selectedMaskComponentID == id
        return HStack(spacing: 6) {
            if let mode, let id {
                Menu(mode.displayName) {
                    ForEach(MaskCombineMode.allCases, id: \.self) { m in
                        Button(m.displayName) { setMode(m, of: id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption2)
                .help("How this component joins the mask above it")
                .accessibilityLabel("Combine mode, \(mode.displayName)")
            } else {
                Text("Shape").font(.caption2).foregroundStyle(.secondary)
            }
            Text(title).font(.caption)
            Spacer()
            Toggle("Invert", isOn: Binding(get: { invert }, set: { setInvert($0, of: id) }))
                .toggleStyle(.checkbox).font(.caption2)
                .help("Invert this component")
            if let id {
                Button {
                    model.removeMaskComponent(id)
                } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Remove this component")
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedMaskComponentID = id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode.map { "\($0.displayName) \(title)" } ?? title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Select") { model.selectedMaskComponentID = id }
    }

    private func setMode(_ mode: MaskCombineMode, of id: UUID) {
        guard let c = model.parameters.locals[index].components.firstIndex(where: { $0.id == id }) else { return }
        model.parameters.locals[index].components[c].mode = mode
    }

    private func setInvert(_ on: Bool, of id: UUID?) {
        guard let id else { model.parameters.locals[index].invert = on; return }
        guard let c = model.parameters.locals[index].components.firstIndex(where: { $0.id == id }) else { return }
        model.parameters.locals[index].components[c].invert = on
    }
}

/// Controls for a selected range component: the eyedropper and its
/// samples for a colour range, the band for a luminance range.
struct MaskRangeComponentControls: View {
    @ObservedObject var model: EditorModel
    let index: Int
    let component: MaskComponent

    var body: some View {
        switch component.source {
        case .colour(let range):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button(model.maskTool == .colourSample ? "Sampling…" : "Sample Colour") { model.maskTool = .colourSample }
                        .disabled(model.maskTool == .colourSample)
                        .help("Click the image to pick a colour; each click adds one, up to five")
                    Button("Clear") { model.clearColourSamples() }
                        .disabled(range.samples.isEmpty)
                        .help("Forget the picked colours")
                    Spacer()
                    ForEach(Array(range.samples.enumerated()), id: \.offset) { _, sample in
                        Circle()
                            .fill(Color(hue: Double(sample.hue) / 360, saturation: Double(sample.saturation), brightness: 0.9))
                            .frame(width: 10, height: 10)
                    }
                    .accessibilityHidden(true)
                }
                .controlSize(.small)
                Text(range.samples.isEmpty ? "Click the colour to select on the image."
                     : "\(range.samples.count) colour\(range.samples.count == 1 ? "" : "s") picked.")
                    .font(.caption2).foregroundStyle(.secondary)
                LocalSliderRow(title: "Refine", value: binding(\.refine, in: range), range: 0...1, format: "%.2f",
                               defaultValue: 0.5, help: "Higher selects colours further from the samples")
            }
        case .luminance(let band):
            VStack(alignment: .leading, spacing: 6) {
                LocalSliderRow(title: "Low", value: lum(\.low, band), range: 0...1, format: "%.2f", defaultValue: 0.5)
                LocalSliderRow(title: "High", value: lum(\.high, band), range: 0...1, format: "%.2f", defaultValue: 1)
                LocalSliderRow(title: "Feather", value: lum(\.feather, band), range: 0.01...0.5, format: "%.2f", defaultValue: 0.1)
            }
        case .shape:
            EmptyView()
        }
    }

    private func update(_ source: MaskComponentSource) {
        guard let c = model.parameters.locals[index].components.firstIndex(where: { $0.id == component.id }) else { return }
        model.parameters.locals[index].components[c].source = source
    }

    private func binding(_ key: WritableKeyPath<ColourRange, Float>, in range: ColourRange) -> Binding<Float> {
        Binding(get: { range[keyPath: key] }, set: { var r = range; r[keyPath: key] = $0; update(.colour(r)) })
    }

    private func lum(_ key: WritableKeyPath<LuminanceRange, Float>, _ band: LuminanceRange) -> Binding<Float> {
        Binding(get: { band[keyPath: key] }, set: { var b = band; b[keyPath: key] = $0; update(.luminance(b)) })
    }
}

/// Overlay ▸ how the selected mask is shown, its colour and strength.
struct MaskOverlayMenu: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var settings = MaskOverlaySettings.shared

    var body: some View {
        Menu("Overlay") {
            Picker("Show As", selection: Binding(get: { settings.mode }, set: { settings.mode = $0; model.rerender() })) {
                ForEach(MaskOverlayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Colour", selection: Binding(get: { settings.swatch }, set: { settings.swatch = $0; model.rerender() })) {
                ForEach(MaskOverlaySettings.Swatch.allCases) { Text($0.displayName).tag($0) }
            }
            .disabled(!settings.mode.usesColour)
            Picker("Opacity", selection: Binding(get: { settings.opacity }, set: { settings.opacity = $0; model.rerender() })) {
                ForEach([Float(0.25), 0.5, 0.75, 1], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }
            .disabled(!settings.mode.usesColour)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How the selected mask is shown on the image")
        .accessibilityLabel("Mask overlay style")
    }
}
