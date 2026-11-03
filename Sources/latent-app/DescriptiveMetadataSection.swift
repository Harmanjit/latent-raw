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
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(DescriptiveField.allCases, id: \.self) { field in
                    GridRow {
                        Text(field.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                        input(field, shared: field.shared(by: targets))
                    }
                }
            }
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
        .onAppear { reload(targets) }
        .onChange(of: signature(targets)) { reload(self.targets) }
        .onChange(of: focused) { old, new in
            if let old, old != new { commit(old) }
            if let new { begin(new) }
        }
        .onDisappear {
            if let focused { commit(focused) }
        }
    }

    @ViewBuilder private func input(_ field: DescriptiveField, shared: DescriptiveField.Shared) -> some View {
        let binding = Binding(get: { text[field] ?? "" }, set: { text[field] = $0 })
        let prompt = Text(shared == .mixed ? "Mixed" : placeholder(field))
        Group {
            if field == .caption {
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
        }
    }

    private func help(_ field: DescriptiveField) -> String {
        switch field {
        case .title: "A short name for the photo (dc:title), written to the sidecar and to exports"
        case .caption: "A description of the photo (dc:description). Return saves; ⌥Return starts a new line"
        case .creator: "Who made the photo (dc:creator). Separate several names with “;”"
        case .copyright: "The copyright notice (dc:rights), written to the sidecar and to exports"
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
            if DescriptiveField.normalized(typed, multiline: field == .caption) == value { return }
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
