import SwiftUI
import PixelEngine

/// Presets and the settings clipboard.
struct PresetsPanel: View {
    @ObservedObject var model: EditorModel
    let onApply: (Preset) -> Void
    @State private var newName = ""
    @State private var showingSave = false
    /// The Amount the next preset applies at, and the last one re-blends
    /// at while it is still the photo's last change (`PresetAmountSession`).
    @AppStorage(PresetAmountSession.amountKey) private var amount = 1.0

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

            HStack(spacing: 6) {
                Text("Amount").font(.caption)
                ResettableSlider(value: Binding(get: { Float(amount) }, set: { amount = Double($0) }),
                                 in: PresetAmount.range, label: "Preset amount",
                                 accessibilityValue: String(format: "%.0f percent", amount * 100)) {
                    amount = 1
                }
                Text(String(format: "%.0f%%", amount * 100)).font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            .help("How strongly a preset applies: 0% leaves the photo alone, 200% goes twice as far. "
                  + "Moving it straight after applying a preset re-blends that preset. Double-click for 100%.")
            .onChange(of: amount) { _, new in model.reblendLastPreset(amount: Float(new)) }
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
                Button("Copy") { model.copySettings() }
                Button("Paste") { model.pasteSettings() }
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
