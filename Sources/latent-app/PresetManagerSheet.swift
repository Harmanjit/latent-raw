import SwiftUI
import PixelEngine

/// Presets panel › Manage Presets…: every preset in one place, searchable
/// and grouped by folder, with its star, note and groups. User presets can
/// be renamed, given a note, narrowed to fewer groups, duplicated and
/// removed; built-ins can be starred, duplicated and exported.
struct PresetManagerSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var catalog: PresetCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @State private var renaming: Preset?
    @State private var removing: Preset?
    @State private var noteDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manage Presets").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search presets", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search presets")
                    List(selection: $selection) {
                        ForEach(Self.sections(filtered), id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.presets) { preset in
                                    row(preset).tag(preset.name)
                                }
                            }
                        }
                    }
                    .frame(width: 260, height: 360)
                }
                detail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack {
                Button("Import…") { model.importPresetsWithPanel() }
                Button("Export All…") { model.exportPresetsWithPanel(model.presets.filter { !$0.isBuiltIn }) }
                    .disabled(!model.presets.contains { !$0.isBuiltIn })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onChange(of: selection) { _, _ in noteDraft = selected?.details ?? "" }
        .sheet(item: $renaming) { preset in
            PresetNameSheet(title: "Rename preset", initial: preset.name, action: "Rename") { name in
                model.renamePreset(preset, to: name)
                if let found = model.presets.first(where: { Preset.normalisedName(name) == $0.name }) {
                    selection = found.name
                }
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Preset", role: .destructive) {
                if let removing { model.deletePreset(removing) }
                removing = nil
                selection = nil
            }
        } message: {
            Text("Photos it was applied to keep their settings. Export it first to keep a copy.")
        }
    }

    private var filtered: [Preset] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.presets }
        return model.presets.filter {
            $0.name.lowercased().contains(query) || ($0.details?.lowercased().contains(query) ?? false)
        }
    }

    private var selected: Preset? { model.presets.first { $0.name == selection } }

    /// Built-in, then the user’s presets by folder.
    struct ListSection {
        let title: String
        let presets: [Preset]
    }

    static func sections(_ presets: [Preset]) -> [ListSection] {
        var result: [ListSection] = []
        let builtIns = presets.filter(\.isBuiltIn)
        if !builtIns.isEmpty { result.append(ListSection(title: "Built-in", presets: builtIns)) }
        var order: [String] = []
        var byFolder: [String: [Preset]] = [:]
        for preset in presets where !preset.isBuiltIn {
            let folder = preset.folders.joined(separator: " › ")
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(preset)
        }
        // Unfiled presets first, then folders by name.
        for folder in order.sorted(by: { ($0.isEmpty ? "" : "\u{1}" + $0.lowercased()) < ($1.isEmpty ? "" : "\u{1}" + $1.lowercased()) }) {
            result.append(ListSection(title: folder.isEmpty ? "My Presets" : folder, presets: byFolder[folder] ?? []))
        }
        return result
    }

    private func row(_ preset: Preset) -> some View {
        HStack {
            Button {
                catalog.toggleFavourite(preset)
            } label: {
                Image(systemName: catalog.isFavourite(preset) ? "star.fill" : "star")
                    .foregroundStyle(catalog.isFavourite(preset) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(catalog.isFavourite(preset) ? "Remove \(preset.name) from favourites"
                                : "Add \(preset.name) to favourites")
            Text(preset.leafName).lineLimit(1)
            Spacer()
        }
    }

    @ViewBuilder private var detail: some View {
        if let preset = selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(preset.name).font(.title3).lineLimit(2)
                    if preset.isBuiltIn { Text("Built-in").font(.caption).foregroundStyle(.secondary) }
                }
                Toggle("Favourite", isOn: Binding(get: { catalog.isFavourite(preset) },
                                                  set: { _ in catalog.toggleFavourite(preset) }))
                    .toggleStyle(.checkbox)
                if preset.isBuiltIn {
                    Text(preset.details ?? "Built-in presets can’t be changed. Duplicate one to make your own.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextField("Optional", text: $noteDraft, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityLabel("Description")
                        .onSubmit { model.setPresetDetails(preset, noteDraft) }
                    if noteDraft != (preset.details ?? "") {
                        Button("Save Description") { model.setPresetDetails(preset, noteDraft) }.controlSize(.small)
                    }
                }
                Text("Holds").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(EditGroup.allCases) { group in
                            Toggle(group.displayName, isOn: Binding(
                                get: { preset.groups.contains(group) },
                                set: { on in
                                    var groups = preset.groups
                                    if on { groups.insert(group) } else { groups.remove(group) }
                                    model.restrictPreset(preset, to: groups)
                                }))
                            .toggleStyle(.checkbox).controlSize(.small)
                            // A group the preset never saved has nothing to
                            // restore: Update from Current Edit captures one.
                            .disabled(preset.isBuiltIn || !preset.groups.contains(group)
                                      || preset.groups.count == 1)
                        }
                    }
                }
                .frame(height: 150)
                HStack {
                    if !preset.isBuiltIn { Button("Rename…") { renaming = preset } }
                    Button("Duplicate") { model.duplicatePreset(preset) }
                    Button("Export…") { model.exportPresetsWithPanel([preset]) }
                    if !preset.isBuiltIn {
                        Button("Update from Current Edit") { model.updatePresetFromCurrentEdit(preset) }
                            .disabled(!model.hasImage)
                            .help("Capture the preset's groups again from the open photo")
                        Button("Remove…", role: .destructive) { removing = preset }
                    }
                }
                .controlSize(.small)
            }
        } else {
            Text("Choose a preset to see what it holds.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
