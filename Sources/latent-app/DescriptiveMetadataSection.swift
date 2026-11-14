import SwiftUI
import Catalog

/// Title, caption, creator and copyright for the selected photos, in the
/// Library panel. With several selected, each field shows the value they
/// share, or "Mixed" when they differ, and a field you change is set on all
/// of them while the other fields keep each photo's own.
///
/// A field is saved when you press Return (in the caption, which can run to
/// several lines, ⌥Return starts a new one) or leave it. The photos it is
/// saved to are the ones selected when you started typing, so clicking
/// another photo to leave the field still saves to the ones you meant.
/// Each save is one step of the Library's undo.
struct DescriptiveMetadataSection: View {
    @ObservedObject var library: Library

    @State private var text: [DescriptiveField: String] = [:]
    /// What each field showed when typing started, to tell a change from none.
    @State private var started: [DescriptiveField: DescriptiveField.Shared] = [:]
    /// The photos and catalog a field being typed in will be saved to.
    @State private var editingIDs: [DescriptiveField: [Int64]] = [:]
    @State private var editingCatalog: Catalog?
    @FocusState private var focused: DescriptiveField?
    /// The More fields (headline, location, contact, instructions) shown.
    @AppStorage("latent.panel.descriptionMoreExpanded") private var moreExpanded = false
    /// Each field's values elsewhere in the catalog, for its chevron menu;
    /// worked out when the selection changes, not at every keystroke.
    @State private var existing: [DescriptiveField: [String]] = [:]
    @State private var presets: [MetadataPreset] = MetadataPresetStore.load()
    @State private var namingPreset = false
    @State private var presetName = ""

    private var targets: [ImageRecord] { library.batchTargets(onlyPrimary: false) }

    /// What the fields depend on: which photos, and their values.
    private struct Signature: Equatable {
        var ids: [Int64?]
        var values: [[String?]]
    }

    private func signature(_ targets: [ImageRecord]) -> Signature {
        Signature(ids: targets.map(\.id),
                  values: targets.map { record in DescriptiveField.allCases.map { $0.value(of: record) } })
    }

    var body: some View {
        let targets = self.targets
        VStack(alignment: .leading, spacing: 6) {
            if targets.count > 1 {
                Text("\(targets.count) photos: what you type is set on all of them")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fieldGrid(DescriptiveField.primary, targets: targets)
            DisclosureGroup(isExpanded: $moreExpanded) {
                fieldGrid(DescriptiveField.more, targets: targets).padding(.top, 4)
            } label: {
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityLabel("More descriptive fields")
            presetMenu(targets: targets)
            if focused == nil, targets.count == 1, let record = targets.first,
               record.copyright == nil, let creator = record.creator {
                // Built as a plain String: a localized title would print the
                // year with a thousands separator ("2,026").
                let notice = "© \(Self.year) \(creator)"
                Button("Copyright " + notice) {
                    save(.copyright, notice, ids: targets.compactMap(\.id))
                }
                .buttonStyle(.link)
                .font(.caption2)
                .help("Fill in the copyright from the creator and this year")
            }
        }
        .controlSize(.small)
        .onAppear { reload(targets); existing = library.existingDescriptiveValues() }
        .onChange(of: signature(targets)) {
            reload(self.targets)
            existing = library.existingDescriptiveValues()
        }
        .alert("Save Metadata Preset", isPresented: $namingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { savePreset(named: presetName, from: self.targets) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The fields the selected photos share, as typed now, under a name to apply to other photos.")
        }
        .onChange(of: focused) { old, new in
            if let old, old != new { commit(old) }
            if let new { begin(new) }
        }
        .onDisappear {
            if let focused { commit(focused) }
        }
    }

    private func fieldGrid(_ fields: [DescriptiveField], targets: [ImageRecord]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(fields, id: \.self) { field in
                GridRow {
                    Text(field.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .accessibilityHidden(true)
                    input(field, shared: field.shared(by: targets))
                    existingMenu(field, targets: targets)
                }
            }
        }
    }

    /// A small chevron listing the field's values on other photos of the
    /// catalog; choosing one sets it on the selection.
    private func existingMenu(_ field: DescriptiveField, targets: [ImageRecord]) -> some View {
        let values = existing[field] ?? []
        return Menu {
            ForEach(values, id: \.self) { value in
                Button(value.count > 60 ? String(value.prefix(60)) + "…" : value) {
                    save(field, value, ids: targets.compactMap(\.id))
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(values.isEmpty)
        .help("Values of \(field.title.lowercased()) used on other photos")
        .accessibilityLabel("Existing values of \(field.title)")
    }

    /// Save the shared fields under a name, apply a saved set to the
    /// selection (one undo step), or delete one.
    private func presetMenu(targets: [ImageRecord]) -> some View {
        Menu("Presets") {
            ForEach(presets) { preset in
                Button(preset.name) { apply(preset, to: targets) }
            }
            if !presets.isEmpty { Divider() }
            Button("Save Current as Preset…") {
                presetName = ""
                namingPreset = true
            }
            .disabled(MetadataPreset.values(sharedBy: targets).isEmpty)
            if !presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            presets.removeAll { $0.id == preset.id }
                            MetadataPresetStore.save(presets)
                        }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption2)
        .help("Save the title, copyright and other fields as a preset, or apply one to the selected photos")
        .accessibilityLabel("Metadata presets")
    }

    private func savePreset(named name: String, from targets: [ImageRecord]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = MetadataPreset.values(sharedBy: targets)
        guard !trimmed.isEmpty, !values.isEmpty else { return }
        presets.removeAll { $0.name == trimmed }
        presets.append(MetadataPreset(name: trimmed, values: values))
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        MetadataPresetStore.save(presets)
    }

    private func apply(_ preset: MetadataPreset, to targets: [ImageRecord]) {
        if let focused { commit(focused) }
        let ids = targets.compactMap(\.id), catalog = library.catalog
        library.perform("Applying the metadata preset") {
            try await library.setDescriptive(preset.fields, forImageIDs: ids, in: catalog)
        }
    }

    @ViewBuilder private func input(_ field: DescriptiveField, shared: DescriptiveField.Shared) -> some View {
        let binding = Binding(get: { text[field] ?? "" }, set: { text[field] = $0 })
        let prompt = Text(shared == .mixed ? "Mixed" : placeholder(field))
        Group {
            if field.isMultiline {
                TextField(field.title, text: binding, prompt: prompt, axis: .vertical)
                    .lineLimit(1...6)
            } else {
                TextField(field.title, text: binding, prompt: prompt)
            }
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .focused($focused, equals: field)
        .onSubmit {
            commit(field)
            begin(field)
        }
        .accessibilityLabel(field.title)
        .accessibilityValue(shared == .mixed && (text[field] ?? "").isEmpty ? "Mixed" : text[field] ?? "")
        .help(help(field))
    }

    private func placeholder(_ field: DescriptiveField) -> String {
        switch field {
        case .title: "Title"
        case .caption: "What the photo shows"
        case .creator: "Your name"
        case .copyright: "© Year Name"
        case .headline: "A short summary"
        case .sublocation: "Place within the city"
        case .city: "City"
        case .state: "State or province"
        case .country: "Country"
        case .countryCode: "ISO code, such as GB"
        case .creatorJobTitle: "Job title"
        case .creatorEmail: "Email"
        case .creatorURL: "Website"
        case .instructions: "Instructions for the user of the photo"
        }
    }

    private func help(_ field: DescriptiveField) -> String {
        switch field {
        case .title: "A short name for the photo (dc:title), written to the sidecar and to exports"
        case .caption: "A description of the photo (dc:description). Return saves; ⌥Return starts a new line"
        case .creator: "Who made the photo (dc:creator). Separate several names with “;”"
        case .copyright: "The copyright notice (dc:rights), written to the sidecar and to exports"
        case .headline: "A short synopsis of the photo (photoshop:Headline)"
        case .sublocation: "The place within the city (Iptc4xmpCore:Location); exported with the location switch"
        case .city: "The city (photoshop:City); exported with the location switch"
        case .state: "The state or province (photoshop:State); exported with the location switch"
        case .country: "The country (photoshop:Country); exported with the location switch"
        case .countryCode: "The country's ISO code (Iptc4xmpCore:CountryCode); exported with the location switch"
        case .creatorJobTitle: "The creator's job title (photoshop:AuthorsPosition)"
        case .creatorEmail: "The creator's email (Iptc4xmpCore:CreatorContactInfo)"
        case .creatorURL: "The creator's website (Iptc4xmpCore:CreatorContactInfo)"
        case .instructions: "Instructions such as embargoes or credit (photoshop:Instructions). Return saves; ⌥Return starts a new line"
        }
    }

    private static var year: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }

    /// Shows the selection's values in every field not being typed in.
    private func reload(_ targets: [ImageRecord]) {
        for field in DescriptiveField.allCases where field != focused {
            if case .same(let value) = field.shared(by: targets) { text[field] = value ?? "" } else { text[field] = "" }
        }
    }

    /// Typing starts: remember which photos it is for.
    private func begin(_ field: DescriptiveField) {
        let targets = self.targets
        editingIDs[field] = targets.compactMap(\.id)
        editingCatalog = library.catalog
        started[field] = field.shared(by: targets)
    }

    /// Saves a field's text to the photos it was typed for, if it changed.
    private func commit(_ field: DescriptiveField) {
        guard let ids = editingIDs.removeValue(forKey: field), let catalog = editingCatalog else { return }
        let typed = text[field] ?? ""
        switch started[field] ?? .mixed {
        case .mixed:
            // Left empty over different values: nothing was typed.
            if typed.isEmpty { return }
        case .same(let value):
            if DescriptiveField.normalized(typed, multiline: field.isMultiline) == value { return }
        }
        library.perform("Saving the \(field.title.lowercased())") {
            try await library.setDescriptive(field, to: typed, forImageIDs: ids, in: catalog)
        }
    }

    private func save(_ field: DescriptiveField, _ value: String, ids: [Int64]) {
        let catalog = library.catalog
        library.perform("Saving the \(field.title.lowercased())") {
            try await library.setDescriptive(field, to: value, forImageIDs: ids, in: catalog)
        }
    }
}
