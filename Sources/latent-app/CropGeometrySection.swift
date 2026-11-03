import SwiftUI
import PixelEngine

/// Develop's Crop & Straighten panel and the Transform panel under it:
/// the crop tool, aspect, straighten (slider, Auto, ruler), the guide
/// overlay and the surround's darkness; then Upright, the keystone and
/// Transform sliders, the flips and Constrain Crop. R opens the crop
/// tool; the rectangle is edited on the image.
struct CropGeometrySection: View {
    @ObservedObject var model: EditorModel
    @AppStorage(CropToolPreferences.guideKey) private var guide: CropGuide = .thirds
    @AppStorage(CropToolPreferences.maskOpacityKey) private var maskOpacity = CropToolPreferences.defaultMaskOpacity
    @State private var transformExpanded = false
    @State private var customAspectShown = false
    @State private var customWidth = 5.0
    @State private var customHeight = 7.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cropControls
            sliderRow("Straighten", value: Binding(get: { model.parameters.crop.angle },
                                                   set: { model.setStraighten($0) }),
                      range: -45...45, format: "%.2f°")
            HStack(spacing: 8) {
                Button("Auto") { model.autoStraighten() }
                    .help("Level the picture by the straight lines in it")
                    .accessibilityLabel("Auto straighten")
                    .disabled(model.geometry.analysing)
                Toggle(isOn: Binding(get: { model.geometry.straightenLineArmed },
                                     set: { armed in
                                         model.geometry.straightenLineArmed = armed
                                         if armed { model.cropToolActive = true }
                                     })) {
                    Image(systemName: "ruler")
                }
                .toggleStyle(.button)
                .help("Draw a line along something that should be level or upright (or ⌘-drag in the crop tool)")
                .accessibilityLabel("Straighten by drawing a line")
                Spacer()
                if model.geometry.analysing { ProgressView().controlSize(.mini) }
            }
            .controlSize(.small)
            .disabled(!model.hasImage)

            overlayControls

            if model.hasImage {
                let s = model.croppedPixelSize
                Text("\(Int(s.width.rounded())) × \(Int(s.height.rounded())) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $transformExpanded) {
                TransformPanel(model: model).padding(.top, 6)
            } label: {
                Text("Transform")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var cropControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.cropToolActive) {
                Text(model.cropToolActive ? "Cropping: on" : "Crop…")
            }
            .toggleStyle(.button)
            .help("Show the crop rectangle on the image (R)")
            Picker("Aspect", selection: Binding(
                get: { CropAspectOption.matching(model.cropAspectDisplayRatio, original: model.originalDisplayRatio) },
                set: { option in
                    if option == .custom {
                        customAspectShown = true
                    } else {
                        model.setCropAspect(displayRatio: option.ratio(original: model.originalDisplayRatio))
                    }
                })) {
                ForEach(CropAspectOption.allCases) { option in
                    Text(option.menuTitle(current: model.cropAspectDisplayRatio, original: model.originalDisplayRatio)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 104)
            .help("Lock the crop to an aspect ratio; Custom… takes any width and height")
            .accessibilityLabel("Crop aspect ratio")
            .popover(isPresented: $customAspectShown, arrowEdge: .bottom) { customAspectForm }
            Spacer()
            Button("Reset") { model.resetCrop() }
                .disabled(model.parameters.crop == .none)
                .help("Remove the crop and straighten")
        }
        .controlSize(.small)
        .disabled(!model.hasImage)
    }

    /// Custom aspect: any width and height, as displayed.
    private var customAspectForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom aspect ratio").font(.headline)
            HStack(spacing: 6) {
                TextField("Width", value: $customWidth, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 56)
                    .accessibilityLabel("Aspect width")
                Text("×").accessibilityHidden(true)
                TextField("Height", value: $customHeight, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 56)
                    .accessibilityLabel("Aspect height")
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { customAspectShown = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let ratio = CropAspectOption.customRatio(width: customWidth, height: customHeight) {
                        model.setCropAspect(displayRatio: ratio)
                    }
                    customAspectShown = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(CropAspectOption.customRatio(width: customWidth, height: customHeight) == nil)
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Overlay").font(.subheadline).accessibilityHidden(true)
                Spacer()
                Picker("Overlay", selection: Binding(get: { guide }, set: { guide = $0
                    UserDefaults.standard.set(0, forKey: CropToolPreferences.orientationKey) })) {
                    ForEach(CropGuide.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                .help("The guide drawn over the crop: O cycles them, ⇧O turns the spiral or triangle")
                .accessibilityLabel("Crop guide overlay")
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Surround").font(.subheadline).accessibilityHidden(true)
                    Spacer()
                    Text("\(Int((maskOpacity * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                ResettableSlider(value: Binding(get: { Float(maskOpacity) }, set: { maskOpacity = Double($0) }),
                                 in: 0...1, label: "Crop surround darkness",
                                 format: SliderValueFormat(decimals: 0, signed: false, unit: "%", scale: 100)) {
                    maskOpacity = CropToolPreferences.defaultMaskOpacity
                }
                .help("How dark the picture outside the crop is drawn. Double-click to reset")
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                           format: String, defaultValue: Float = 0) -> some View {
        TransformPanel.row(title, value: value, range: range, format: format, defaultValue: defaultValue)
            .disabled(!model.hasImage)
    }
}

/// Upright, the keystone pair, Rotate, Aspect, Scale, X and Y Offset, the
/// flips and Constrain Crop. Every change goes through the model's
/// `setTransform`, so Constrain Crop can refit the crop in the same edit
/// step and Undo takes both back together.
struct TransformPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            uprightControls
            Self.row("Vertical", value: binding(\.vertical), range: -1...1, format: "%+.2f")
            Self.row("Horizontal", value: binding(\.horizontal), range: -1...1, format: "%+.2f")
            Self.row("Rotate", value: binding(\.rotate), range: TransformRanges.rotate, format: "%+.1f°")
            Self.row("Aspect", value: binding(\.aspect), range: TransformRanges.aspect, format: "%+.2f")
            Self.row("Scale", value: binding(\.scale), range: TransformRanges.scale, format: "%.2f×", defaultValue: 1)
            Self.row("X Offset", value: binding(\.offsetX), range: TransformRanges.offset, format: "%+.2f")
            Self.row("Y Offset", value: binding(\.offsetY), range: TransformRanges.offset, format: "%+.2f")
            HStack(spacing: 8) {
                Button { model.flip(horizontal: true) } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontal: mirror the picture left to right")
                .accessibilityLabel("Flip horizontal")
                Button { model.flip(horizontal: false) } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip vertical: mirror the picture top to bottom")
                .accessibilityLabel("Flip vertical")
                Toggle("Constrain Crop", isOn: Binding(get: { model.parameters.perspective.constrainCrop },
                                                       set: { model.setConstrainCrop($0) }))
                    .toggleStyle(.checkbox)
                    .help("Keep the crop inside the picture whenever the transform changes")
                Spacer()
                Button("Reset") { model.resetTransform() }
                    .disabled(model.parameters.perspective.isIdentity && model.parameters.perspective.upright == nil)
                    .help("Put Upright, the keystone and the Transform sliders back")
            }
            .controlSize(.small)
            .disabled(!model.hasImage)
        }
    }

    private var uprightControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upright").font(.subheadline).accessibilityHidden(true)
                Spacer()
                if model.uprightMode != nil && model.uprightMode != .guided {
                    Button("Update") { model.updateUpright() }
                        .controlSize(.mini)
                        .help("Read the picture's lines again (after a lens change, say)")
                        .disabled(model.geometry.analysing)
                }
            }
            Picker("Upright", selection: Binding(get: { UprightChoice(model.uprightMode) },
                                                 set: { model.setUpright($0.mode) })) {
                ForEach(UprightChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Off; Auto levels and eases converging verticals; Guided uses lines you draw; Level, Vertical and Full correct more strongly")
            .accessibilityLabel("Upright mode")
            .disabled(!model.hasImage || model.geometry.analysing)
            if model.uprightMode == .guided {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { model.geometry.guidedToolActive },
                                         set: { model.setGuidedToolActive($0) })) {
                        Text(model.geometry.guidedToolActive ? "Drawing guides" : "Draw Guides")
                    }
                    .toggleStyle(.button)
                    .help("Drag along edges that should be upright or level: two to four guides. ⌥-click a guide to remove it")
                    Spacer()
                    Text(SpokenText.guides(count: model.parameters.perspective.upright?.guides?.count ?? 0))
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Clear") { model.clearGuides() }
                        .disabled(model.parameters.perspective.upright?.guides == nil)
                        .help("Remove every guide")
                }
                .controlSize(.small)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PerspectiveCorrection, Float>) -> Binding<Float> {
        Binding(get: { model.parameters.perspective[keyPath: keyPath] },
                set: { value in model.setTransform { $0[keyPath: keyPath] = value } })
    }

    /// A slider row laid out as the Develop panel's others: name and
    /// typed value above, the slider below, double-click to reset.
    static func row(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                    format: String, defaultValue: Float = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The field and slider are both named, so VoiceOver skips this.
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: value, in: range, format: SliderValueFormat(printf: format), label: title)
            }
            ResettableSlider(value: value, in: range, label: title,
                             format: SliderValueFormat(printf: format)) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
        }
    }
}

/// The Upright picker's entries, Off included.
enum UprightChoice: String, CaseIterable, Identifiable {
    case off, auto, guided, level, vertical, full
    var id: String { rawValue }

    init(_ mode: UprightCorrection.Mode?) {
        self = mode.flatMap { UprightChoice(rawValue: $0.rawValue) } ?? .off
    }

    var mode: UprightCorrection.Mode? { UprightCorrection.Mode(rawValue: rawValue) }
    var title: String { mode?.title ?? "Off" }
}

/// The aspect menu's entries, as displayed (portrait images see "3:2" tall).
enum CropAspectOption: String, CaseIterable, Identifiable {
    case free, original, square, r3x2, r2x3, r4x3, r3x4, r5x4, r4x5, r5x7, r7x5, r16x9, r9x16, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .r3x2: "3:2"
        case .r2x3: "2:3"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r5x4: "5:4"
        case .r4x5: "4:5"
        case .r5x7: "5:7"
        case .r7x5: "7:5"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        case .custom: "Custom"
        }
    }

    /// The menu's text: Custom shows the ratio in use when it is one.
    func menuTitle(current: Float?, original: Float) -> String {
        guard self == .custom else { return title }
        guard let current, Self.matching(current, original: original) == .custom else { return "Custom…" }
        return "Custom (\(Self.describe(current)))"
    }

    /// The ratio, or nil for Free and for Custom (which asks).
    func ratio(original: Float) -> Float? {
        switch self {
        case .free, .custom: nil
        case .original: original
        case .square: 1
        case .r3x2: 3 / 2
        case .r2x3: 2 / 3
        case .r4x3: 4 / 3
        case .r3x4: 3 / 4
        case .r5x4: 5 / 4
        case .r4x5: 4 / 5
        case .r5x7: 5 / 7
        case .r7x5: 7 / 5
        case .r16x9: 16 / 9
        case .r9x16: 9 / 16
        }
    }

    /// The entry whose ratio matches `ratio` (within a hair); a lock that
    /// matches none of them is Custom, no lock is Free.
    static func matching(_ ratio: Float?, original: Float) -> CropAspectOption {
        guard let ratio else { return .free }
        return allCases.first { option in
            guard let r = option.ratio(original: original) else { return false }
            return abs(r - ratio) < 0.002
        } ?? .custom
    }

    /// Width over height from the custom form, or nil when either is not
    /// a sensible positive number (or the shape is absurdly thin).
    static func customRatio(width: Double, height: Double) -> Float? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let r = width / height
        guard r >= 0.05, r <= 20 else { return nil }
        return Float(r)
    }

    /// "1.85:1", or "1:2.4" for a tall one.
    static func describe(_ ratio: Float) -> String {
        func trimmed(_ v: Float) -> String {
            let s = String(format: "%.2f", v)
            return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        return ratio >= 1 ? "\(trimmed(ratio)):1" : "1:\(trimmed(1 / ratio))"
    }
}
