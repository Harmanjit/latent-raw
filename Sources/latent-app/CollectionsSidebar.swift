import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Catalog
import PixelEngine

/// The Collections section of the sidebar: the open folder's collections,
/// smart collections and sets. Clicking one shows its photos in the grid
/// (the filter bar still narrows them); clicking it again, or All
/// Photographs, shows the whole folder. Photos dragged from the grid onto
/// a collection are added to it.
struct CollectionsSection: View {
    @ObservedObject var library: Library
    @ObservedObject var collections: LibraryCollections
    @ObservedObject private var sheets = CollectionSheets.shared
    @AppStorage("latent.collectionsExpanded") private var expanded = true
    /// Sets the user has folded.
    @State private var folded: Set<Int64> = []
    @State private var dropTarget: Int64?
    @ObservedObject private var recents = RecentCollectionsStore.shared
    @AppStorage("latent.recentCollectionsExpanded") private var recentExpanded = true

    init(library: Library) {
        self.library = library
        self.collections = library.collections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if expanded {
                if library.folderURL == nil {
                    note("Open a folder to make collections of its photos.")
                } else if collections.state.collections.isEmpty {
                    note("Gather photos from anywhere in this folder: select them and choose New Collection, or press B to add them to the Quick Collection.")
                } else {
                    recentSection
                    let rows = flatRows(parent: nil, depth: 0)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            allPhotosRow
                            ForEach(rows, id: \.collection.id) { row in
                                collectionRow(row.collection, depth: row.depth)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(rows.count + 1) * 22 + 4, 260))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Every collection opened, from here, the menu bar or the grid, is
        // remembered for this folder's Recent list.
        .onChange(of: collections.activeID) { _, id in
            if let id, let folder = library.folderURL { recents.record(id, folder: folder) }
        }
    }

    /// The collections opened most recently in this folder, newest first.
    /// Back and Forward are untouched: this is only a list to click.
    @ViewBuilder private var recentSection: some View {
        let ids = library.folderURL.map { RecentCollections.existing(recents.list(for: $0), in: collections.state) } ?? []
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    recentExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: recentExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Recent").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recent collections")
                .accessibilityValue(recentExpanded ? "Expanded" : "Collapsed")
                if recentExpanded {
                    ForEach(ids, id: \.self) { id in
                        if let c = collections.state.collection(id) {
                            let active = collections.activeID == id
                            Button {
                                collections.show(active ? nil : id)
                            } label: {
                                rowLabel(icon: Self.icon(c.kind), name: collections.state.path(of: id),
                                         count: collections.counts[id] ?? 0, active: active, depth: 0)
                            }
                            .buttonStyle(.plain)
                            .help("Opened recently in this folder. Click to show it again.")
                            .accessibilityLabel("Recent \(Self.kindName(c.kind).lowercased()) \(c.name)")
                            .accessibilityValue("\(collections.counts[id] ?? 0) photos")
                            .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Collections")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collections")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("New Collection…") { sheets.request = .new(.regular, parent: nil) }
                Button("New Smart Collection…") { sheets.request = .new(.smart, parent: nil) }
                Button("New Collection Set…") { sheets.request = .new(.set, parent: nil) }
                Divider()
                Button("Save Filter as Smart Collection…") { sheets.request = .smartFromFilter }
                    .disabled(!library.filter.isActive)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(library.folderURL == nil)
            .help("Make a collection, smart collection or collection set in this folder")
            .accessibilityLabel("New collection")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
    }

    private var allPhotosRow: some View {
        let active = collections.activeID == nil
        return Button {
            collections.show(nil)
        } label: {
            rowLabel(icon: "photo.on.rectangle", name: "All Photographs", count: library.images.count,
                     active: active, depth: 0)
        }
        .buttonStyle(.plain)
        .help("Show every photo in the folder")
        .accessibilityLabel("All Photographs")
        .accessibilityValue("\(library.images.count) photos")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private struct FlatRow { var collection: CatalogCollection; var depth: Int }

    private func flatRows(parent: Int64?, depth: Int) -> [FlatRow] {
        collections.state.children(of: parent).flatMap { c -> [FlatRow] in
            let row = FlatRow(collection: c, depth: depth)
            guard c.kind == .set, !folded.contains(c.id) else { return [row] }
            return [row] + flatRows(parent: c.id, depth: depth + 1)
        }
    }

    private func collectionRow(_ c: CatalogCollection, depth: Int) -> some View {
        let active = collections.activeID == c.id
        let count = collections.counts[c.id] ?? 0
        let isTarget = collections.targetCollection?.id == c.id
        return HStack(spacing: 0) {
            if c.kind == .set {
                Button {
                    if folded.contains(c.id) { folded.remove(c.id) } else { folded.insert(c.id) }
                } label: {
                    Image(systemName: folded.contains(c.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 12, height: 18)
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(depth) * 12)
                .accessibilityLabel(folded.contains(c.id) ? "Expand \(c.name)" : "Collapse \(c.name)")
            }
            Button {
                collections.show(active ? nil : c.id)
            } label: {
                rowLabel(icon: Self.icon(c.kind), name: c.name + (isTarget ? " +" : ""), count: count, active: active,
                         depth: c.kind == .set ? 0 : depth, dropping: dropTarget == c.id,
                         indent: c.kind == .set ? 0 : 12)
            }
            .buttonStyle(.plain)
            .help(Self.help(c, count: count, isTarget: isTarget))
            .accessibilityLabel("\(Self.kindName(c.kind)) \(c.name)\(isTarget ? ", target collection" : "")")
            .accessibilityValue("\(count) photos")
            .accessibilityHint(active ? "Shows the whole folder again" : "Shows its photos in the grid")
            .accessibilityAddTraits(active ? .isSelected : [])
        }
        .contextMenu { contextMenu(c, isTarget: isTarget) }
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dropTarget == c.id },
                                                    set: { dropTarget = $0 ? c.id : (dropTarget == c.id ? nil : dropTarget) })) { providers in
            guard c.kind == .regular else { return false }
            return acceptDrop(providers, into: c.id)
        }
    }

    private func rowLabel(icon: String, name: String, count: Int, active: Bool, depth: Int,
                          dropping: Bool = false, indent: CGFloat = 12) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 14)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
        .padding(.leading, CGFloat(depth) * 12 + indent)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(dropping ? Color.accentColor.opacity(0.35) : active ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func contextMenu(_ c: CatalogCollection, isTarget: Bool) -> some View {
        let selected = Set(library.selectedImageIDs)
        if c.kind == .regular {
            Button("Add Selected Photos") { collections.add(selected, to: c.id) }
                .disabled(selected.isEmpty)
            Button("Remove Selected Photos") { collections.remove(selected, from: c.id) }
                .disabled(selected.isDisjoint(with: collections.state.members[c.id] ?? []))
            Button(isTarget ? "Stop Being Target Collection" : "Set as Target Collection") {
                collections.setTarget(isTarget ? nil : c.id)
            }
            .help("B adds the selected photos to the target collection")
            Divider()
        }
        if c.kind == .smart {
            Button("Edit Smart Collection…") { sheets.request = .editSmart(c.id) }
            Divider()
        }
        if c.kind == .set {
            Button("New Collection Inside…") { sheets.request = .new(.regular, parent: c.id) }
            Button("New Smart Collection Inside…") { sheets.request = .new(.smart, parent: c.id) }
            Button("New Collection Set Inside…") { sheets.request = .new(.set, parent: c.id) }
            Divider()
        }
        Button("Rename…") { sheets.request = .rename(c.id) }
        Menu("Move to") {
            Button("Top Level") { collections.move(c.id, into: nil) }
                .disabled(c.parentID == nil)
            let parents = collections.state.possibleParents(for: c.id)
            if !parents.isEmpty { Divider() }
            ForEach(parents) { set in
                Button(collections.state.path(of: set.id)) { collections.move(c.id, into: set.id) }
                    .disabled(c.parentID == set.id)
            }
        }
        Divider()
        Button(c.kind == .set ? "Delete Collection Set" : "Delete Collection") { collections.delete(c.id) }
    }

    private func acceptDrop(_ providers: [NSItemProvider], into id: Int64) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }
        let collector = URLCollector(expected: fileProviders.count) { urls in
            let ids = collections.imageIDs(forFileURLs: urls)
            if !ids.isEmpty { collections.add(ids, to: id) }
        }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.add(url) }
            }
        }
        return true
    }

    static func icon(_ kind: CatalogCollection.Kind) -> String {
        switch kind {
        case .regular: "rectangle.stack"
        case .smart: "gearshape"
        case .set: "folder"
        }
    }

    static func kindName(_ kind: CatalogCollection.Kind) -> String {
        switch kind {
        case .regular: "Collection"
        case .smart: "Smart collection"
        case .set: "Collection set"
        }
    }

    static func help(_ c: CatalogCollection, count: Int, isTarget: Bool) -> String {
        let photos = count == 1 ? "1 photo" : "\(count) photos"
        switch c.kind {
        case .regular:
            return "\(photos). Click to show them; drag photos here to add them."
                + (isTarget ? " B adds to this collection (the target)." : "")
        case .smart: return "\(photos) match its rules. Click to show them."
        case .set: return "A set of collections: \(photos) in the collections inside it."
        }
    }
}

/// Gathers the URLs of a drop, which arrive one by one, and hands them on
/// once all are in.
@MainActor
private final class URLCollector {
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void

    init(expected: Int, done: @escaping ([URL]) -> Void) {
        remaining = expected
        self.done = done
    }

    func add(_ url: URL?) {
        if let url { urls.append(url) }
        remaining -= 1
        if remaining == 0 { done(urls) }
    }
}

/// The collections opened recently, per folder path, in the preferences.
@MainActor
final class RecentCollectionsStore: ObservableObject {
    static let shared = RecentCollectionsStore()
    private static let key = "latent.recentCollections"

    /// Folder path → collection ids, newest first.
    @Published private(set) var byFolder: [String: [Int64]]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [Int]] ?? [:]
        byFolder = stored.mapValues { $0.map(Int64.init) }
    }

    func list(for folder: URL) -> [Int64] {
        byFolder[folder.standardizedFileURL.path] ?? []
    }

    func record(_ id: Int64, folder: URL) {
        let path = folder.standardizedFileURL.path
        let next = RecentCollections.recording(id, in: byFolder[path] ?? [])
        guard next != byFolder[path] else { return }
        byFolder[path] = next
        UserDefaults.standard.set(byFolder.mapValues { $0.map(Int.init) }, forKey: Self.key)
    }
}

// MARK: - Sheets

/// Which collection sheet is up. One main window, so one presenter; the
/// sidebar, the menu bar and the grid's menu all ask it.
@MainActor
final class CollectionSheets: ObservableObject {
    static let shared = CollectionSheets()

    enum Request: Identifiable, Equatable {
        case new(CatalogCollection.Kind, parent: Int64?)
        case rename(Int64)
        case editSmart(Int64)
        /// A smart collection starting from the filter bar's settings.
        case smartFromFilter

        var id: String {
            switch self {
            case .new(let kind, let parent): "new-\(kind.rawValue)-\(parent.map(String.init) ?? "top")"
            case .rename(let id): "rename-\(id)"
            case .editSmart(let id): "edit-\(id)"
            case .smartFromFilter: "smart-from-filter"
            }
        }
    }

    @Published var request: Request?
}

extension View {
    /// The collection sheets, on the main window.
    func collectionSheets(library: Library) -> some View {
        modifier(CollectionSheetsModifier(library: library))
    }
}

private struct CollectionSheetsModifier: ViewModifier {
    let library: Library
    @ObservedObject private var sheets = CollectionSheets.shared

    func body(content: Content) -> some View {
        content.sheet(item: $sheets.request) { request in
            Group {
                switch request {
                case .new(.smart, let parent):
                    SmartCollectionEditor(library: library, editing: nil, parent: parent,
                                          rules: SmartCollectionRules(criteria: [SmartCriterion(field: .rating)]))
                case .smartFromFilter:
                    SmartCollectionEditor(library: library, editing: nil, parent: nil,
                                          rules: SmartCollectionRules(filter: library.filter))
                case .new(let kind, let parent):
                    CollectionNameSheet(library: library, kind: kind, renaming: nil, parent: parent)
                case .rename(let id):
                    if let c = library.collections.state.collection(id) {
                        CollectionNameSheet(library: library, kind: c.kind, renaming: c, parent: c.parentID)
                    }
                case .editSmart(let id):
                    if let c = library.collections.state.collection(id) {
                        SmartCollectionEditor(library: library, editing: c, parent: c.parentID,
                                              rules: c.rules ?? SmartCollectionRules())
                    }
                }
            }
            .motionFollowsAccessibility()
        }
    }
}

/// Names a new collection or set, or renames one. A new collection can
/// start with the selected photos in it.
struct CollectionNameSheet: View {
    let library: Library
    let kind: CatalogCollection.Kind
    let renaming: CatalogCollection?
    @State private var name: String
    @State private var parent: Int64?
    @State private var includeSelected: Bool
    @Environment(\.dismiss) private var dismiss

    init(library: Library, kind: CatalogCollection.Kind, renaming: CatalogCollection?, parent: Int64?) {
        self.library = library
        self.kind = kind
        self.renaming = renaming
        _name = State(initialValue: renaming?.name ?? "")
        _parent = State(initialValue: parent)
        _includeSelected = State(initialValue: renaming == nil && kind == .regular && !library.selectedImageIDs.isEmpty)
    }

    private var title: String {
        if renaming != nil { return "Rename \(CollectionsSection.kindName(kind))" }
        return kind == .set ? "New Collection Set" : "New Collection"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .accessibilityLabel("Name")
                .onSubmit(confirm)
            if renaming == nil {
                let sets = library.collections.state.possibleParents(for: nil)
                if !sets.isEmpty {
                    Picker("Inside", selection: $parent) {
                        Text("Top level").tag(Int64?.none)
                        ForEach(sets) { set in
                            Text(library.collections.state.path(of: set.id)).tag(Int64?.some(set.id))
                        }
                    }
                    .frame(width: 280)
                    .help("The collection set to put it in")
                }
                if kind == .regular {
                    let n = library.selectedImageIDs.count
                    Toggle("Include the \(n == 1 ? "selected photo" : "\(n) selected photos")", isOn: $includeSelected)
                        .disabled(n == 0)
                        .help("Start the collection with the photos selected in the grid")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(renaming == nil ? "Create" : "Rename", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func confirm() {
        let collections = library.collections
        if let renaming {
            collections.rename(renaming.id, to: name)
        } else {
            let ids = includeSelected ? library.selectedImageIDs : []
            if let id = collections.create(name: name, kind: kind, in: parent, adding: ids), kind == .regular {
                collections.show(id)
            }
        }
        dismiss()
    }
}

/// Makes or edits a smart collection: criteria joined by all or any, with
/// how many photos match as you go.
struct SmartCollectionEditor: View {
    let library: Library
    /// Observed so the count follows edit details read in the background.
    @ObservedObject private var collections: LibraryCollections
    let editing: CatalogCollection?
    @State private var name: String
    @State private var parent: Int64?
    @State private var rules: SmartCollectionRules
    @Environment(\.dismiss) private var dismiss

    init(library: Library, editing: CatalogCollection?, parent: Int64?, rules: SmartCollectionRules) {
        self.library = library
        self.collections = library.collections
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _parent = State(initialValue: parent)
        _rules = State(initialValue: rules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New Smart Collection" : "Edit Smart Collection").font(.headline)
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .accessibilityLabel("Name")
                if editing == nil {
                    let sets = library.collections.state.possibleParents(for: nil)
                    if !sets.isEmpty {
                        Picker("Inside", selection: $parent) {
                            Text("Top level").tag(Int64?.none)
                            ForEach(sets) { set in
                                Text(library.collections.state.path(of: set.id)).tag(Int64?.some(set.id))
                            }
                        }
                        .frame(width: 220)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Match")
                Picker("Match", selection: $rules.match) {
                    ForEach(SmartCollectionRules.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Whether a photo must meet every rule, or any one of them")
                Text("of the following rules:")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rules.criteria.indices, id: \.self) { index in
                    SmartCriterionRow(criterion: $rules.criteria[index], keywords: library.availableKeywords,
                                      canRemove: rules.criteria.count > 1,
                                      join: index == 0 ? nil : joinBinding(index),
                                      existingValues: { collections.existingValues(for: $0) }) {
                        rules.criteria.remove(at: index)
                    } onAdd: {
                        rules.criteria.insert(SmartCriterion(field: .rating), at: index + 1)
                    }
                }
            }
            Text(matchCount)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(matchCount)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create" : "Save", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rules.criteria.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 720)
    }

    /// A line's join popup: its own join, else the one Match implies.
    /// Choosing the implied one leaves the line following Match.
    private func joinBinding(_ index: Int) -> Binding<SmartCriterion.Join> {
        Binding(get: {
            guard rules.criteria.indices.contains(index) else { return .and }
            return rules.effectiveJoin(of: rules.criteria[index])
        }, set: { join in
            guard rules.criteria.indices.contains(index) else { return }
            let implied: SmartCriterion.Join = rules.match == .all ? .and : .or
            rules.criteria[index].join = rules.criteria[index].join == nil && join == implied ? nil : join
        })
    }

    private var matchCount: String {
        let context = collections.matchContexts(for: rules)
        let n = library.images.filter { rules.matches($0, context: context($0)) }.count
        return n == 1 ? "1 photo in this folder matches." : "\(n) photos in this folder match."
    }

    private func confirm() {
        let collections = library.collections
        if let editing {
            if name.trimmingCharacters(in: .whitespaces) != editing.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                collections.rename(editing.id, to: name)
            }
            collections.setRules(rules, for: editing.id)
        } else if let id = collections.create(name: name, kind: .smart, in: parent, rules: rules) {
            collections.show(id)
        }
        dismiss()
    }
}

/// One rule: how it joins the rules above (from the second), field,
/// comparison, value, and the − and + buttons.
private struct SmartCriterionRow: View {
    @Binding var criterion: SmartCriterion
    let keywords: [String]
    let canRemove: Bool
    /// The join popup's value; nil on the first line, which has none.
    let join: Binding<SmartCriterion.Join>?
    /// The folder's values for a text field, for the value menu.
    let existingValues: (SmartCriterion.Field) -> [String]
    let onRemove: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let join {
                Picker("Join", selection: join) {
                    ForEach(SmartCriterion.Join.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                .help("How this rule joins the rules above it, read from the top down: and, or, or except (and not)")
                .accessibilityLabel("Join")
            } else {
                Color.clear.frame(width: 80, height: 1)
            }
            Picker("Field", selection: Binding(get: { criterion.field }, set: { field in
                guard field != criterion.field else { return }
                let join = criterion.join
                criterion = SmartCriterion(field: field)
                criterion.join = join
            })) {
                ForEach(SmartCriterion.Field.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel("Field")
            Picker("Comparison", selection: Binding(get: { criterion.op }, set: { op in
                let wasDays = criterion.op.takesDays
                criterion.op = op
                // The date fields' value changes meaning with the comparison.
                if criterion.field.valueKind == .date, wasDays != op.takesDays {
                    criterion.value = op.takesDays ? "30" : SmartCriterion.dayString(Date())
                }
                // A range needs its end; anything else carries none.
                if op.takesSecondValue {
                    if criterion.value2 == nil { criterion.value2 = criterion.value }
                } else {
                    criterion.value2 = nil
                }
                // Aspect ratio names a shape under is / is not, a number otherwise.
                if criterion.field == .aspectRatio {
                    let named = SmartCriterion.Shape(rawValue: criterion.value) != nil
                    if (op == .is || op == .isNot) != named {
                        criterion.value = op == .is || op == .isNot ? SmartCriterion.Shape.landscape.rawValue : "1.5"
                        if op.takesSecondValue { criterion.value2 = "1.5" }
                    }
                }
            })) {
                ForEach(criterion.field.operators, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel("Comparison")
            valueEditor
                .frame(width: 230, alignment: .leading)
            Button(action: onRemove) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove this rule")
                .accessibilityLabel("Remove rule")
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Add a rule below this one")
                .accessibilityLabel("Add rule")
        }
        .controlSize(.small)
    }

    private var secondValue: Binding<String> {
        Binding(get: { criterion.value2 ?? "" }, set: { criterion.value2 = $0 })
    }

    @ViewBuilder private var valueEditor: some View {
        if !criterion.op.takesValue {
            Color.clear.frame(height: 1)
        } else {
            switch criterion.field.valueKind {
            case .flag:
                Picker("Flag", selection: $criterion.value) {
                    Text("Picked").tag("1")
                    Text("Unflagged").tag("0")
                    Text("Rejected").tag("-1")
                }
                .labelsHidden()
                .accessibilityLabel("Flag")
            case .yesNo:
                Picker(criterion.field.title, selection: $criterion.value) {
                    Text("Yes").tag("true")
                    Text("No").tag("false")
                }
                .labelsHidden()
                .accessibilityLabel(criterion.field.title)
            case .number:
                HStack(spacing: 4) {
                    numberField($criterion.value)
                    if criterion.op.takesSecondValue {
                        Text("and").foregroundStyle(.secondary)
                        numberField(secondValue)
                    }
                    if criterion.field == .rating { Text("stars").foregroundStyle(.secondary) }
                    if criterion.field == .focalLength { Text("mm").foregroundStyle(.secondary) }
                    if criterion.field == .exposureTime { Text("s").foregroundStyle(.secondary) }
                }
            case .shape:
                if criterion.op == .is || criterion.op == .isNot {
                    Picker("Shape", selection: $criterion.value) {
                        if SmartCriterion.Shape(rawValue: criterion.value) == nil { Text("Choose…").tag(criterion.value) }
                        ForEach(SmartCriterion.Shape.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Shape")
                } else {
                    HStack(spacing: 4) {
                        numberField($criterion.value)
                        if criterion.op.takesSecondValue {
                            Text("and").foregroundStyle(.secondary)
                            numberField(secondValue)
                        }
                        Text("width ÷ height").foregroundStyle(.secondary)
                    }
                    .help("A number such as 1.5, or a ratio such as 3:2")
                }
            case .kind:
                Picker("Kind", selection: $criterion.value) {
                    ForEach(SmartCriterion.Kind.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .accessibilityLabel("Kind")
            case .integrity:
                Picker("File integrity", selection: $criterion.value) {
                    ForEach(FileIntegrity.State.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .help("What Library › Verify Files last found: damaged, OK, or not checked since the file changed")
                .accessibilityLabel("File integrity")
            case .module:
                Picker("Edit group", selection: $criterion.value) {
                    if EditGroup(rawValue: criterion.value) == nil { Text("Choose…").tag(criterion.value) }
                    ForEach(EditGroup.allCases) { Text(Self.shortName($0)).tag($0.rawValue) }
                }
                .labelsHidden()
                .help("Photos whose edit changes this part from its default")
                .accessibilityLabel("Edit group")
            case .date:
                HStack(spacing: 4) {
                    if criterion.op.takesDays {
                        TextField("Days", text: $criterion.value)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .accessibilityLabel("Number of days")
                        Text("days").foregroundStyle(.secondary)
                    } else {
                        dayPicker($criterion.value, label: criterion.op.takesSecondValue ? "From date" : "Date")
                        if criterion.op.takesSecondValue {
                            Text("and").foregroundStyle(.secondary)
                            dayPicker(secondValue, label: "To date")
                        }
                    }
                }
            case .days, .text:
                if criterion.field == .keyword, !keywords.isEmpty, criterion.op == .is || criterion.op == .isNot {
                    Picker("Keyword", selection: $criterion.value) {
                        if !keywords.contains(criterion.value) { Text("Choose…").tag(criterion.value) }
                        ForEach(keywords, id: \.self) { Text(KeywordPath.display($0)).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Keyword")
                } else {
                    HStack(spacing: 2) {
                        TextField(criterion.field == .fileType ? "e.g. NEF" : "Text", text: $criterion.value)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(criterion.field.title) text")
                        if criterion.field.offersExistingValues {
                            existingValuesMenu
                        }
                    }
                }
            }
        }
    }

    /// The values the field takes in this folder, to pick one.
    private var existingValuesMenu: some View {
        let values = existingValues(criterion.field)
        return Menu {
            if values.isEmpty {
                Text("None in this folder")
            }
            ForEach(values.prefix(200), id: \.self) { value in
                Button(criterion.field == .keyword ? KeywordPath.display(value)
                       : criterion.field == .folder && value.isEmpty ? "(top level)" : value) {
                    criterion.value = value
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a value the photos in this folder have")
        .accessibilityLabel("\(criterion.field.title) values in this folder")
    }

    private func numberField(_ value: Binding<String>) -> some View {
        TextField("Value", text: value)
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .accessibilityLabel("\(criterion.field.title) value")
    }

    private func dayPicker(_ value: Binding<String>, label: String) -> some View {
        DatePicker(label, selection: Binding(
            get: { SmartCriterion.parseDay(value.wrappedValue) ?? Date() },
            set: { value.wrappedValue = SmartCriterion.dayString($0) }), displayedComponents: .date)
            .labelsHidden()
            .accessibilityLabel(label)
    }

    /// "Tone" for "Tone (exposure, contrast, …)".
    static func shortName(_ group: EditGroup) -> String {
        let name = group.displayName
        guard let open = name.range(of: " (") else { return name }
        return String(name[..<open.lowerBound])
    }
}

// MARK: - Commands

/// What the collection commands do, for the menu bar, B and the grid's menu.
@MainActor
enum CollectionCommands {
    /// `onlyPrimary` as for ratings: Loupe and Develop act on the photo shown.
    static func perform(_ command: KeyCommand, library: Library, onlyPrimary: Bool = false) {
        let sheets = CollectionSheets.shared
        switch command {
        case .newCollection: sheets.request = .new(.regular, parent: nil)
        case .newSmartCollection: sheets.request = .new(.smart, parent: nil)
        case .newCollectionSet: sheets.request = .new(.set, parent: nil)
        case .saveFilterAsSmartCollection: sheets.request = .smartFromFilter
        case .addToTargetCollection:
            let ids = Set(library.batchTargets(onlyPrimary: onlyPrimary).compactMap(\.id))
            if let message = library.collections.toggleInTarget(ids) { Announcement.post(message) }
        case .removeFromCollection:
            guard let active = library.collections.activeCollection, active.kind == .regular else { return }
            library.collections.remove(Set(library.batchTargets(onlyPrimary: onlyPrimary).compactMap(\.id)), from: active.id)
        default:
            break
        }
    }

    /// "Add to Quick Collection" or the target's name.
    static func targetTitle(_ library: Library) -> String {
        "Add to \(library.collections.targetCollection?.name ?? LibraryCollections.quickCollectionName)"
    }

    /// The grid menu's Collections items.
    static func addItems(to menu: NSMenu, library: Library) {
        let collections = library.collections
        let selected = Set(library.selectedImageIDs)
        guard library.folderURL != nil else { return }
        menu.addItem(.separator())
        let inTarget = collections.targetContains(selected)
        let targetName = collections.targetCollection?.name ?? LibraryCollections.quickCollectionName
        menu.addItem(ClosureMenuItem(Shortcuts.menuTitle(inTarget ? "Remove from \(targetName)" : "Add to \(targetName)",
                                                         for: .addToTargetCollection),
                                     enabled: !selected.isEmpty) {
            CollectionCommands.perform(.addToTargetCollection, library: library)
        })
        var items: [NSMenuItem] = collections.state.regularCollections.map { c in
            let item = ClosureMenuItem(collections.state.path(of: c.id), enabled: !selected.isEmpty) {
                collections.add(selected, to: c.id)
            }
            item.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            item.state = !selected.isEmpty && selected.isSubset(of: collections.state.members[c.id] ?? []) ? .on : .off
            return item
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem("New Collection…", enabled: true) {
            CollectionSheets.shared.request = .new(.regular, parent: nil)
        })
        let add = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)
        add.submenu = submenu
        add.isEnabled = !selected.isEmpty
        menu.addItem(add)
        if let active = collections.activeCollection, active.kind == .regular {
            menu.addItem(ClosureMenuItem("Remove from “\(active.name)”", enabled: !selected.isEmpty) {
                collections.remove(selected, from: active.id)
            })
        }
    }
}

// MARK: - Edit changes

/// What the "Edit changes" smart collection field reads: the edit groups a
/// stored edit changes from Latent's own defaults. Run off the main
/// thread by `LibraryCollections`, which the catalog module can't do
/// itself (it doesn't link PixelEngine).
enum SmartCollectionEditGroups {
    private static let neutral = EditStack(parameters: EditParameters())

    static let reader: @Sendable (String) -> Set<String> = { json in
        guard let stack = try? EditStack.decode(json: json) else { return [] }
        return Set(EditGroup.allCases.filter { group in
            stack.restricted(to: [group]).modules != neutral.restricted(to: [group]).modules
        }.map(\.rawValue))
    }
}
