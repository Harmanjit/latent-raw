import SwiftUI
import PixelEngine

/// Presets and the settings clipboard.
struct PresetsPanel: View {
    @ObservedObject var model: EditorModel
    let onApply: (Preset) -> Void
    @State private var newName = ""
    @State private var showingSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Presets
            ForEach(model.presets) { preset in
                HStack {
                    Button(preset.name) { onApply(preset) }
                        .buttonStyle(.plain)
                    Spacer()
                    Text(preset.groups.count == 1 ? "1 group" : "\(preset.groups.count) groups")
                        .font(.caption2).foregroundStyle(.tertiary)
                    if !preset.isBuiltIn {
                        Button { model.deletePreset(preset) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Button("Save current as preset…") { showingSave = true }
                .controlSize(.small)
                .disabled(!model.hasImage)

            Divider()

            // Clipboard groups
            Text("Copy / paste carries:").font(.caption2).foregroundStyle(.secondary)
            ForEach(EditGroup.allCases) { group in
                Toggle(group.displayName, isOn: Binding(
                    get: { model.pasteGroups.contains(group) },
                    set: { on in if on { model.pasteGroups.insert(group) } else { model.pasteGroups.remove(group) } }))
                .toggleStyle(.checkbox).controlSize(.mini)
            }
            HStack {
                Button("Copy") { model.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste") { model.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Spacer()
                Button(model.showingBefore ? "After" : "Before") { model.showingBefore.toggle() }
                    .help("Hold \\ to compare with the unedited image")
            }
            .controlSize(.small)
            .disabled(!model.hasImage)
        }
        .sheet(isPresented: $showingSave) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save preset").font(.headline)
                TextField("Name", text: $newName)
                Text("Includes the groups ticked under “Copy / paste carries”.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showingSave = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        model.savePreset(named: newName.trimmingCharacters(in: .whitespaces), groups: model.pasteGroups)
                        newName = ""; showingSave = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(width: 340)
        }
    }
}
