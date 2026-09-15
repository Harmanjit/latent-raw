import SwiftUI
import PixelEngine
import MLKit

/// The Local Adjustments panel: a list of masks, and for the selected
/// one, its tool, its sliders and its range refinements.
struct LocalAdjustmentsPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu("Add") {
                    Button("Linear Gradient") { model.addLocal(.linear) }
                    Button("Radial") { model.addLocal(.radial) }
                    Button("Brush") { model.addLocal(.brush) }
                    Button("Whole Image (range only)") { model.addLocal(.none) }
                    Divider()
                    Button("Click to Select (Segment Anything)") { model.addPromptedMask() }
                        .disabled(!model.sam2Available)
                    Menu("Select by Class") {
                        ForEach(AIMaskKind.allCases.filter { $0 != .subject }, id: \.self) { kind in
                            Button(kind.displayName) { model.addAIMask(kind) }
                        }
                    }
                    Button("Subject (auto, Vision)") { model.addAIMask(.subject) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.hasImage || model.parameters.locals.count >= LocalAdjustment.maximumCount)
                Spacer()
                Toggle("Show mask", isOn: $model.showMaskOverlay)
                    .toggleStyle(.checkbox)
                    .disabled(model.selectedLocal == nil)
            }
            .controlSize(.small)

            if model.parameters.locals.isEmpty {
                Text("Add a mask, then drag on the image to place it. Adjustments apply where the mask is red.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                localList
            }

            if let i = model.selectedLocalIndex, i < model.parameters.locals.count {
                selectedControls(i)
            }
        }
    }

    private var localList: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.parameters.locals.enumerated()), id: \.element.id) { index, local in
                let selected = model.selectedLocalIndex == index
                HStack(spacing: 6) {
                    Image(systemName: icon(for: local.shape)).frame(width: 14)
                    Text(local.name).font(.caption)
                    Spacer()
                    if local.invert { Text("inv").font(.caption2).foregroundStyle(.tertiary) }
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .selectionOutline(selected, cornerRadius: 4)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedLocalIndex = index }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(local.invert ? "\(local.name), inverted" : local.name)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { model.selectedLocalIndex = index }
            }
        }
    }

    private func icon(for shape: MaskShape) -> String {
        switch shape {
        case .linear: return "rectangle.lefthalf.filled"
        case .radial: return "circle.dashed"
        case .brush:  return "paintbrush.pointed"
        case .whole:  return "square"
        case .ai:     return "sparkles"
        case .prompted: return "cursorarrow.click"
        }
    }

    @ViewBuilder
    private func selectedControls(_ i: Int) -> some View {
        let binding = $model.parameters.locals[i]
        VStack(alignment: .leading, spacing: 10) {
            toolRow(i)

            slider("Exposure", binding.exposureEV, -3...3, "%+.2f EV")
            slider("Contrast", binding.contrast, -1...1, "%+.2f")
            slider("Saturation", binding.saturation, -1...1, "%+.2f")
            slider("Warmth", binding.warmth, -1...1, "%+.2f")

            HStack {
                Toggle("Invert", isOn: binding.invert).toggleStyle(.checkbox)
                Spacer()
                Button("Delete", role: .destructive) { model.removeSelectedLocal() }
            }
            .controlSize(.small)

            rangeControls(binding)
        }
        // The rows stay when another mask is selected, bound to it instead.
        .sliderFieldSubject(model.parameters.locals[i].id)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func toolRow(_ i: Int) -> some View {
        switch model.parameters.locals[i].shape {
        case .linear:
            toolHint("Drag on the image from where the effect is full to where it ends.",
                     tool: .linear, label: "Place gradient")
        case .radial:
            toolHint("Drag on the image from the centre outward.", tool: .radial, label: "Place radial")
            if case .radial(let c, let r, let feather) = model.parameters.locals[i].shape {
                slider("Feather", Binding(
                    get: { feather },
                    set: { model.parameters.locals[i].shape = .radial(centre: c, radii: r, feather: $0) }),
                       0...1, "%.2f", 0.5)
            }
        case .brush:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Brush tool", selection: $model.maskTool) {
                    Text("Paint").tag(EditorModel.MaskTool.brush)
                    Text("Erase").tag(EditorModel.MaskTool.erase)
                    Text("Pan").tag(EditorModel.MaskTool.none)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                // What a new window starts the brush at.
                slider("Size", $model.brushRadius, 0.005...0.2, "%.3f", 0.04)
                slider("Feather", $model.brushFeather, 0...1, "%.2f", 0.5)
                slider("Flow", $model.brushFlow, 0.1...1, "%.2f", 1)
            }
        case .whole:
            Text("Whole image — use the ranges below to limit it.")
                .font(.caption2).foregroundStyle(.secondary)
        case .ai(let kind, let version):
            HStack(spacing: 6) {
                if model.generatingMasks.contains(model.parameters.locals[i].id) {
                    ProgressView().controlSize(.mini)
                    Text("Generating \(kind) mask…").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("\(kind.capitalized) mask · \(version)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .prompted(let points, _):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(model.maskTool == .prompt ? "Clicking…" : "Click to select") { model.maskTool = .prompt }
                        .controlSize(.small).disabled(model.maskTool == .prompt)
                    Button("Clear points") { model.clearPromptPoints() }
                        .controlSize(.small).disabled(points.isEmpty)
                    if model.generatingMasks.contains(model.parameters.locals[i].id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(points.isEmpty
                     ? "Click the thing you want. Option-click to exclude something. \(model.sam2Status)"
                     : "\(points.count) point\(points.count == 1 ? "" : "s") · \(model.sam2Status)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toolHint(_ text: String, tool: EditorModel.MaskTool, label: String) -> some View {
        HStack {
            Text(text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(model.maskTool == tool ? "Placing…" : label) { model.maskTool = tool }
                .controlSize(.small)
                .disabled(model.maskTool == tool)
        }
    }

    @ViewBuilder
    private func rangeControls(_ binding: Binding<LocalAdjustment>) -> some View {
        let lumOn = Binding(get: { binding.wrappedValue.luminanceRange != nil },
                            set: { binding.wrappedValue.luminanceRange = $0 ? LuminanceRange() : nil })
        let hueOn = Binding(get: { binding.wrappedValue.hueRange != nil },
                            set: { binding.wrappedValue.hueRange = $0 ? HueRange() : nil })

        Toggle("Luminance range", isOn: lumOn).toggleStyle(.checkbox).controlSize(.small)
        if binding.wrappedValue.luminanceRange != nil {
            let lr = Binding(get: { binding.wrappedValue.luminanceRange ?? LuminanceRange() },
                             set: { binding.wrappedValue.luminanceRange = $0 })
            let lrDefault = LuminanceRange()
            slider("Low", lr.low, 0...1, "%.2f", lrDefault.low)
            slider("High", lr.high, 0...1, "%.2f", lrDefault.high)
            slider("Feather", lr.feather, 0.01...0.5, "%.2f", lrDefault.feather)
        }
        Toggle("Colour range", isOn: hueOn).toggleStyle(.checkbox).controlSize(.small)
        if binding.wrappedValue.hueRange != nil {
            let hr = Binding(get: { binding.wrappedValue.hueRange ?? HueRange() },
                             set: { binding.wrappedValue.hueRange = $0 })
            HStack {
                Circle().fill(Color(hue: Double(hr.centre.wrappedValue) / 360, saturation: 1, brightness: 1))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                slider("Hue", hr.centre, 0...360, "%.0f°", HueRange().centre)
            }
            slider("Width", hr.width, 5...90, "%.0f°", HueRange().width)
            slider("Min. sat.", hr.minimumSaturation, 0...1, "%.2f", HueRange().minimumSaturation)
        }
    }

    /// `defaultValue` is what a double-click puts back.
    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>,
                        _ format: String, _ defaultValue: Float = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: range, format: SliderValueFormat(printf: format), label: title)
            }
            ResettableSlider(value: value, in: range, label: title,
                             format: SliderValueFormat(printf: format)) {
                value.wrappedValue = Self.resetValue(defaultValue, in: range)
            }
        }
    }

    /// A row's default, kept inside its range. Every row used to reset to
    /// 0, below several of their ranges: a brush of size 0 has no spacing
    /// between dabs, and a colour range of width 0 no edge to smooth.
    static func resetValue(_ defaultValue: Float, in range: ClosedRange<Float>) -> Float {
        min(max(defaultValue, range.lowerBound), range.upperBound)
    }
}
