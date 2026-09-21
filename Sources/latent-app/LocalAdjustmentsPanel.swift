import SwiftUI
import PixelEngine
import MLKit

/// The Local Adjustments panel: a list of masks, and for the selected
/// one, its tool, its sliders and its range refinements.
struct LocalAdjustmentsPanel: View {
    @ObservedObject var model: EditorModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu("Add") {
                    Button("Linear Gradient") { model.addLocal(.linear) }
                    Button("Radial") { model.addLocal(.radial) }
                    Button("Brush") { model.addLocal(.brush) }
                    Button("Whole Image (range only)") { model.addLocal(.none) }
                    Divider()
                    modelMenu("Subject", kind: .subjectSegmentation) { model.addAIMask(model: $0) }
                    modelMenu("Click to Select", kind: .promptedSegmentation) { model.addPromptedMask(model: $0) }
                        .disabled(!model.promptedModelAvailable)
                    Menu("Select by Class") {
                        ForEach(AIMaskKind.allCases.filter { $0 != .subject }, id: \.self) { kind in
                            Button(kind.displayName) { model.addAIMask(kind) }
                        }
                    }
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

    /// The installed models of a kind, the default first and ticked, then
    /// the way to Settings for more.
    private func modelMenu(_ title: String, kind: ModelManifest.Kind,
                           add: @escaping (ModelEntry) -> Void) -> some View {
        let choices = ModelMenus.choices(kind: kind, registry: .shared)
        return Menu(title) {
            ForEach(choices) { entry in
                // A Toggle draws the tick a menu item shows; choosing it
                // adds the mask rather than changing a setting.
                Toggle(isOn: Binding(get: { entry.id == choices.first?.id }, set: { _ in add(entry) })) {
                    Text(entry.manifest.displayName)
                }
            }
            Divider()
            Button("More models…") { openSettings() }
                .help("Settings › AI › Models: add a model from disk or choose the default")
        }
        .disabled(choices.isEmpty)
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
        case .ai:
            let shape = model.parameters.locals[i].shape
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if model.generatingMasks.contains(model.parameters.locals[i].id) {
                        ProgressView().controlSize(.mini)
                        Text("Generating \(ModelMenus.rowTitle(for: shape, registry: .shared))…")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(ModelMenus.rowTitle(for: shape, registry: .shared))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    modelSwitch(i, shape: shape)
                }
                missingModelRow(shape)
            }
        case .prompted(let points, let version):
            let shape = model.parameters.locals[i].shape
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(model.maskTool == .prompt ? "Clicking…" : "Click to select") { model.maskTool = .prompt }
                        .controlSize(.small).disabled(model.maskTool == .prompt)
                    Button("Clear points") { model.clearPromptPoints() }
                        .controlSize(.small).disabled(points.isEmpty)
                    if model.generatingMasks.contains(model.parameters.locals[i].id) {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    modelSwitch(i, shape: shape)
                }
                let status = model.promptModelID(for: version).flatMap { model.promptStatus[$0] } ?? ""
                Text(ModelMenus.promptedRowText(for: shape, status: status, registry: .shared))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                missingModelRow(shape)
            }
        }
    }

    /// Menu("Model"): the other installed models of the mask's kind, each
    /// making the mask again.
    @ViewBuilder
    private func modelSwitch(_ i: Int, shape: MaskShape) -> some View {
        let others = ModelMenus.alternatives(for: shape, registry: .shared)
        if !others.isEmpty {
            Menu("Model") {
                ForEach(others) { entry in
                    Button(entry.manifest.displayName) { model.rerunMask(at: i, with: entry) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("Make this mask again with another model")
            .accessibilityLabel("Model for this mask")
            .accessibilityHint("Makes the mask again with the model you choose")
        }
    }

    /// "BiRefNet General is not installed — shown with Apple Vision
    /// instead." with the ways to get it, when the edit names a model this
    /// Mac lacks.
    @ViewBuilder
    private func missingModelRow(_ shape: MaskShape) -> some View {
        if let sentence = ModelMenus.missingSentence(for: shape, registry: .shared) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sentence)
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let entry = ModelMenus.missingEntry(for: shape, registry: .shared) {
                        Button("Get…") { NSWorkspace.shared.open(entry.manifest.sourceURL) }
                            .help("Open the page for \(entry.manifest.displayName) in your browser; nothing is downloaded by Latent")
                            .accessibilityLabel("Get \(entry.manifest.displayName), opens its page in your browser")
                    }
                    Button("Add Model…") { openSettings() }
                        .help("Settings › AI › Models adds a converted model from disk")
                        .accessibilityLabel("Add a model in Settings")
                }
                .controlSize(.small)
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

extension AIMaskKind {
    /// The mask in a status line: "subject", "sky".
    var maskNoun: String { self == .subject ? "subject" : displayName.lowercased() }
}

/// What the Add menu and the mask rows say about models, as functions of
/// a registry so ModelMenuTests can ask them of a fixture.
enum ModelMenus {
    /// Installed models of `kind` a new mask can be made with, the
    /// default (Settings › AI › Models) first.
    static func choices(kind: ModelManifest.Kind, registry: ModelRegistry) -> [ModelEntry] {
        let installed = registry.entries(kind: kind).filter(\.isInstalled)
        guard let preferred = defaultEntry(kind: kind, registry: registry),
              let index = installed.firstIndex(where: { $0.id == preferred.id }) else { return installed }
        var ordered = installed
        ordered.remove(at: index)
        ordered.insert(preferred, at: 0)
        return ordered
    }

    /// The model a NEW mask of `kind` is made with; nil for a kind with
    /// none installed.
    static func defaultEntry(kind: ModelManifest.Kind, registry: ModelRegistry) -> ModelEntry? {
        switch kind {
        case .subjectSegmentation: return registry.defaultSubject()
        case .promptedSegmentation: return registry.defaultPrompted()
        case .semanticSegmentation: return registry.entries(kind: kind).first(where: \.isInstalled)
        case .denoise: return nil
        }
    }

    /// Apple Vision's row name: the stand-in for a missing subject model.
    static func visionName(registry: ModelRegistry) -> String {
        registry.entry(id: ModelRegistry.builtInSubjectID)?.manifest.displayName ?? "Apple Vision"
    }

    /// The entry a stored version names, installed or not, when the
    /// registry lists it.
    static func namedEntry(_ stored: String, registry: ModelRegistry) -> ModelEntry? {
        ModelRef(stored: stored).flatMap { registry.entry(id: $0.id) }
    }

    /// The name to show for a stored version: the model's display name
    /// when the registry lists it, else the id, else the string as stored.
    static func modelName(_ stored: String, registry: ModelRegistry) -> String {
        guard let ref = ModelRef(stored: stored) else { return stored }
        return registry.entry(id: ref.id)?.manifest.displayName ?? ref.id
    }

    /// The installed subject model a stored version runs (Apple Vision
    /// counts), or nil when Vision stands in (`AIMaskGenerator.generate`).
    static func subjectEntry(running stored: String, registry: ModelRegistry) -> ModelEntry? {
        registry.installed(ModelRef(stored: stored)).flatMap { $0.manifest.kind == .subjectSegmentation ? $0 : nil }
    }

    /// The click-to-select model a stored version runs: the one named when
    /// installed, else the default (as export does); nil with none.
    static func promptedEntry(running stored: String, registry: ModelRegistry) -> ModelEntry? {
        if let named = registry.installed(ModelRef(stored: stored)), named.manifest.kind == .promptedSegmentation {
            return named
        }
        return registry.defaultPrompted()
    }

    /// The class model a stored version runs: the one named when installed
    /// as a class model, else the installed class model; nil when a
    /// built-in estimate stands in.
    static func semanticEntry(running stored: String, registry: ModelRegistry) -> ModelEntry? {
        if let named = registry.installed(ModelRef(stored: stored)), named.manifest.kind == .semanticSegmentation {
            return named
        }
        return registry.installed(ModelRef(id: SegmentationModel.modelID, version: 1))
    }

    /// What will make a mask of `kind` stored as `modelVersion`, for the
    /// status line: "BiRefNet Lite", "Apple Vision", "SegFormer B2".
    static func runningModelName(for kind: AIMaskKind, modelVersion: String,
                                 registry: ModelRegistry = .shared) -> String {
        switch kind {
        case .subject:
            return subjectEntry(running: modelVersion, registry: registry)?.manifest.displayName
                ?? visionName(registry: registry)
        case .sky:
            return semanticEntry(running: modelVersion, registry: registry)?.manifest.displayName
                ?? "the built-in sky estimate"
        case .people:
            return semanticEntry(running: modelVersion, registry: registry)?.manifest.displayName
                ?? visionName(registry: registry)
        default:
            return semanticEntry(running: modelVersion, registry: registry)?.manifest.displayName
                ?? modelName(modelVersion, registry: registry)
        }
    }

    /// The mask row: "Subject · BiRefNet Lite", "Sky · SegFormer B2". A
    /// click-to-select row is `promptedRowText`.
    static func rowTitle(for shape: MaskShape, registry: ModelRegistry) -> String {
        switch shape {
        case .ai(let kindName, let version):
            guard let kind = AIMaskKind(storedName: kindName) else { return "\(kindName.capitalized) mask" }
            let noun = kind == .subject ? "Subject" : kind.displayName
            return "\(noun) · \(runningModelName(for: kind, modelVersion: version, registry: registry))"
        case .prompted(_, let version):
            return promptedEntry(running: version, registry: registry)?.manifest.displayName
                ?? modelName(version, registry: registry)
        default:
            return ""
        }
    }

    /// "SAM 2.1 Large · 3 points · Image encoded in 640 ms — …", or the
    /// instructions while there are no points.
    static func promptedRowText(for shape: MaskShape, status: String, registry: ModelRegistry) -> String {
        guard case .prompted(let points, _) = shape else { return "" }
        let name = rowTitle(for: shape, registry: registry)
        let count = points.isEmpty ? "Click the thing you want. Option-click to exclude something."
            : "\(points.count) point\(points.count == 1 ? "" : "s")"
        return [name, count, status].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The model the edit names but this Mac lacks, when the registry
    /// lists it (a catalogue row, so Get… has a page to open).
    static func missingEntry(for shape: MaskShape, registry: ModelRegistry) -> ModelEntry? {
        guard missingSentence(for: shape, registry: registry) != nil else { return nil }
        let stored: String
        switch shape {
        case .ai(_, let version), .prompted(_, let version): stored = version
        default: return nil
        }
        return namedEntry(stored, registry: registry).flatMap { $0.isInstalled ? nil : $0 }
    }

    /// "BiRefNet General is not installed — shown with Apple Vision
    /// instead." when the mask's model is missing; nil when the mask is
    /// made with the model it names. Mirrors what `AIMaskGenerator` and
    /// `ExportWorker.regenerateMasks` report as substituted.
    static func missingSentence(for shape: MaskShape, registry: ModelRegistry) -> String? {
        switch shape {
        case .ai(let kindName, let version):
            guard let kind = AIMaskKind(storedName: kindName) else { return nil }
            if kind == .subject {
                guard subjectEntry(running: version, registry: registry) == nil else { return nil }
                return "\(modelName(version, registry: registry)) is not installed — shown with "
                    + "\(visionName(registry: registry)) instead."
            }
            // A class mask only reports a real model it names and lacks;
            // the bundled class model or its estimate stands in silently,
            // as the 0.9.0 beta did.
            guard let ref = ModelRef(stored: version), ref.id != SegmentationModel.modelID,
                  !ref.id.hasPrefix("latent."),
                  registry.installed(ref).map({ $0.manifest.kind == .semanticSegmentation }) != true else { return nil }
            return "\(modelName(version, registry: registry)) is not installed — shown with "
                + "\(runningModelName(for: kind, modelVersion: version, registry: registry)) instead."
        case .prompted(_, let version):
            if let named = registry.installed(ModelRef(stored: version)), named.manifest.kind == .promptedSegmentation {
                return nil
            }
            let name = modelName(version, registry: registry)
            guard let fallback = registry.defaultPrompted() else {
                return "\(name) is not installed, and no click-to-select model is, so the mask is empty."
            }
            return "\(name) is not installed — shown with \(fallback.manifest.displayName) instead."
        default:
            return nil
        }
    }

    /// The other installed models of the mask's kind, for Menu("Model"):
    /// everything installed but the one making it now.
    static func alternatives(for shape: MaskShape, registry: ModelRegistry) -> [ModelEntry] {
        let kind: ModelManifest.Kind
        let current: String?
        switch shape {
        case .ai(let kindName, let version):
            guard let maskKind = AIMaskKind(storedName: kindName) else { return [] }
            kind = maskKind == .subject ? .subjectSegmentation : .semanticSegmentation
            current = maskKind == .subject ? subjectEntry(running: version, registry: registry)?.id
                : semanticEntry(running: version, registry: registry)?.id
        case .prompted(_, let version):
            kind = .promptedSegmentation
            current = promptedEntry(running: version, registry: registry)?.id
        default:
            return []
        }
        return choices(kind: kind, registry: registry).filter { $0.id != current }
    }
}
