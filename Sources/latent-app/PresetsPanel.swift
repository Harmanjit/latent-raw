import SwiftUI
import PixelEngine

/// Presets and the settings clipboard.
struct PresetsPanel: View {
    @Bindable var model: EditorModel
    let onApply: (Preset) -> Void
    /// Apply with a mode (Overwrite with Option, or as a new virtual copy);
    /// nil offers plain Apply only.
    var onApplyMode: PresetMenuAction?
    @ObservedObject private var catalog = PresetCatalog.shared
    @State private var newName = ""
    @State private var showingSave = false
    @State private var showingManager = false
    /// The preset a Rename… sheet is renaming.
    @State private var renaming: Preset?
    /// The preset Delete preset asks to remove; nil when no dialog shows.
    @State private var deleting: Preset?
    /// The Amount the next preset applies at, and the last one re-blends
    /// at while it is still the photo's last change (`PresetAmountSession`).
    @AppStorage(PresetAmountSession.amountKey) private var amount = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Presets: a menu, so the list can grow without eating the panel.
            HStack {
                Menu("Apply preset") {
                    let user = model.presets.filter { !$0.isBuiltIn }
                    PresetMenuItems(presets: model.presets, favourites: catalog.favouritePresets,
                                    virtualCopies: onApplyMode != nil) { preset, mode in
                        if mode == .append { onApply(preset) } else { onApplyMode?(preset, mode) }
                    }
                    if !user.isEmpty {
                        Divider()
                        Menu("Delete preset") {
                            ForEach(user) { preset in
                                Button(preset.name + "…", role: .destructive) { deleting = preset }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(!model.hasImage)
                PresetManagementMenu(model: model, catalog: catalog, showingManager: $showingManager,
                                     renaming: $renaming)
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
        .sheet(isPresented: $showingManager) {
            PresetManagerSheet(model: model, catalog: catalog)
        }
        .sheet(item: $renaming) { preset in
            PresetNameSheet(title: "Rename preset", initial: preset.name, action: "Rename") { name in
                model.renamePreset(preset, to: name)
            }
        }
        // Matches Manage Presets… (PresetManagerSheet), which already asks.
        .confirmationDialog("Remove “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting) { preset in
            Button("Remove Preset", role: .destructive) { model.deletePreset(preset) }
        } message: { _ in
            Text("Photos it was applied to keep their settings. Export it first to keep a copy.")
        }
    }
}

/// The Presets panel's management menu: Import…, Export…, Manage…, and
/// Rename…, Duplicate, Update from Current Edit and Favourite per preset.
/// Built-ins can only be duplicated, exported and starred.
struct PresetManagementMenu: View {
    @Bindable var model: EditorModel
    @ObservedObject var catalog: PresetCatalog
    @Binding var showingManager: Bool
    @Binding var renaming: Preset?

    var body: some View {
        let user = model.presets.filter { !$0.isBuiltIn }
        Menu {
            Button("Manage Presets…") { showingManager = true }
            Divider()
            Button("Import…") { model.importPresetsWithPanel() }
            Menu("Export") {
                if !user.isEmpty {
                    Button("All My Presets…") { model.exportPresetsWithPanel(user) }
                    Divider()
                }
                perPreset(model.presets) { model.exportPresetsWithPanel([$0]) }
            }
            Divider()
            Menu("Favourite") {
                PresetNodeItems(nodes: PresetMenuTree.nodes(model.presets), plainOnly: true,
                                isChecked: { catalog.isFavourite($0) }) { preset, _ in
                    catalog.toggleFavourite(preset)
                }
            }
            Menu("Duplicate") { perPreset(model.presets) { model.duplicatePreset($0) } }
            if !user.isEmpty {
                Menu("Rename") { perPreset(user) { renaming = $0 } }
                Menu("Update from Current Edit") { perPreset(user) { model.updatePresetFromCurrentEdit($0) } }
                    .disabled(!model.hasImage)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Manage presets")
        .help("Import, export, rename, duplicate, star or update presets")
    }

    private func perPreset(_ presets: [Preset], _ action: @escaping (Preset) -> Void) -> some View {
        PresetNodeItems(nodes: PresetMenuTree.nodes(presets), plainOnly: true) { preset, _ in action(preset) }
    }
}

/// A sheet asking for a preset name, for Rename… and Save Panel as Preset….
/// "Folder|Name" files it in a folder.
struct PresetNameSheet: View {
    let title: String
    let initial: String
    let action: String
    var note: String = "Use “Folder|Name” to put it in a folder."
    let onDone: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .accessibilityLabel("Preset name")
            Text(note).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    onDone(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Preset.normalisedName(name) == nil)
            }
        }
        .padding(20).frame(width: 340)
        .onAppear { name = initial }
    }
}
