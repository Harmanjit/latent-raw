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
            // Presets: a menu, so the list can grow without eating the panel.
            HStack {
                Menu("Apply preset") {
                    let builtIns = model.presets.filter(\.isBuiltIn)
                    let user = model.presets.filter { !$0.isBuiltIn }
                    ForEach(builtIns) { preset in
                        Button(preset.name) { onApply(preset) }
                    }
                    if !user.isEmpty {
                        Divider()
                        ForEach(user) { preset in
                            Button(preset.name) { onApply(preset) }
                        }
                        Divider()
                        Menu("Delete preset") {
                            ForEach(user) { preset in
                                Button(preset.name, role: .destructive) { model.deletePreset(preset) }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(!model.hasImage)
                Spacer()
                Button("Save…") { showingSave = true }
                    .help("Save the current settings as a preset")
                    .disabled(!model.hasImage)
            }
            .controlSize(.small)

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
