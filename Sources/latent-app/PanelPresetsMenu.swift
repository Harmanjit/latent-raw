import SwiftUI
import PixelEngine

/// A small presets menu in a Develop panel's header, as darktable's
/// per-module presets: the presets that hold exactly this panel's groups,
/// applied to the open photo at the Presets panel's Amount, and Save Panel
/// as Preset…, which saves only this panel's settings.
struct PanelPresetsMenu: View {
    @Bindable var model: EditorModel
    let groups: Set<EditGroup>
    /// The panel's name, for the menu's label and the save sheet.
    var panel = ""
    @State private var saving = false

    /// The presets whose groups are exactly `groups`.
    static func presets(_ all: [Preset], for groups: Set<EditGroup>) -> [Preset] {
        all.filter { $0.groups == groups }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 4)
            Menu {
                let matching = Self.presets(model.presets, for: groups)
                if matching.isEmpty {
                    Text("No presets for this panel yet")
                } else {
                    PresetNodeItems(nodes: PresetMenuTree.nodes(matching), plainOnly: true) { preset, _ in
                        model.applyPresetInEditor(preset)
                    }
                }
                Divider()
                Button("Save Panel as Preset…") { saving = true }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
            .disabled(!model.hasImage)
            .accessibilityLabel(panel.isEmpty ? "Panel presets" : "\(panel) presets")
            .help("Presets for this panel only, and saving this panel's settings as one")
        }
        .sheet(isPresented: $saving) {
            PresetNameSheet(title: panel.isEmpty ? "Save panel as preset" : "Save \(panel) as preset",
                            initial: "", action: "Save",
                            note: "Saves only this panel’s settings. Use “Folder|Name” to put it in a folder.") { name in
                guard let name = Preset.normalisedName(name) else { return }
                model.savePreset(named: name, groups: groups)
            }
        }
    }
}
