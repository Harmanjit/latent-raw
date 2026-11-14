import SwiftUI
import PixelEngine

/// The export sheet's Apply Preset choice: None, or a develop preset applied
/// to the files only (Append over each photo's edit, or Replace it), at an
/// Amount from 0 to 200%.
struct ExportPresetStyleSection: View {
    @Binding var preset: ExportPreset
    @ObservedObject private var catalog = PresetCatalog.shared

    var body: some View {
        PresetStylePicker(style: $preset.presetStyle, presets: catalog.presets, purpose: "exported file")
    }
}

/// None or a preset, its mode and its Amount; shared by the export sheet
/// and the print panel's Photo Layout section.
struct PresetStylePicker: View {
    @Binding var style: PresetStyle?
    let presets: [Preset]
    /// "exported file" or "print", for the help text.
    let purpose: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apply preset").accessibilityHidden(true)
                Menu(menuTitle) {
                    Button("None") { style = nil }
                    Divider()
                    PresetNodeItems(nodes: PresetMenuTree.nodes(presets), plainOnly: true) { chosen, _ in
                        style = PresetStyle(presetName: chosen.name, mode: style?.mode ?? .append,
                                            amount: style?.amount ?? PresetAmount.full)
                    }
                }
                .fixedSize()
                .accessibilityLabel("Apply preset to each \(purpose)")
                .help("A develop preset applied to each \(purpose) only. The photos' own edits don't change.")
                if missing {
                    Text("Missing").font(.caption).foregroundStyle(.red)
                        .help("No preset has this name any more, so nothing is applied.")
                }
            }
            if style != nil {
                HStack {
                    Picker("Mode", selection: Binding(get: { style?.mode ?? .append },
                                                      set: { style?.mode = $0 })) {
                        ForEach(PresetStyle.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .help("Append applies the preset over each photo's edit; Replace uses the preset alone, from no edit.")
                    Text("Amount").accessibilityHidden(true)
                    ResettableSlider(value: Binding(get: { style?.amount ?? PresetAmount.full },
                                                    set: { style?.amount = $0 }),
                                     in: PresetAmount.range, label: "Preset amount",
                                     format: SliderValueFormat(decimals: 0, unit: "%", scale: 100)) {
                        style?.amount = PresetAmount.full
                    }
                    Text(String(format: "%.0f%%", (style?.amount ?? 1) * 100)).monospacedDigit().frame(width: 44)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var menuTitle: String {
        guard let style else { return "None" }
        return PresetMenuTree.favouriteTitle(Preset(name: style.presetName, groups: [], stack: EditStack()))
    }

    private var missing: Bool {
        guard let style else { return false }
        return !presets.contains { $0.name == style.presetName }
    }
}
