import SwiftUI
import Combine
import Catalog

/// Keywording in the library panel: the selected photos' keywords as chips,
/// and a field that adds keywords to every selected photo, completing from
/// the keywords already in the folder.
///
/// A keyword typed as "Places > France > Paris" is a hierarchical keyword
/// (see `KeywordPath`). Commas separate keywords. The chips show the
/// innermost level; a chip drawn faintly is on only some of the selected
/// photos, and its × takes it off all of them.
struct KeywordingField: View {
    @ObservedObject var library: Library
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var highlighted = 0
    /// Bumped after each add, so the Recent chips redraw.
    @State private var added = 0
    @FocusState private var focused: Bool
    @ObservedObject private var focus = KeywordEntryFocus.shared

    var body: some View {
        let usage = library.selectionKeywords()
        VStack(alignment: .leading, spacing: 5) {
            if !usage.counts.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(usage.counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                        KeywordChip(path: path, onAll: usage.counts[path] == usage.photos, photos: usage.photos) {
                            library.perform("Removing a keyword") { try await library.removeKeywords([path]) }
                        } onShow: {
                            library.filter.keyword = path
                            library.filter.noKeywords = false
                        }
                    }
                }
            }
            TextField(usage.photos > 1 ? "Add keywords to \(usage.photos) photos" : "Add keywords", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
                .disabled(usage.photos == 0)
                .accessibilityLabel("Add keywords")
                .accessibilityHint("Separate keywords with commas. Type Places > France to make a keyword inside another.")
                .help("Keywords to add to the selected photos, separated by commas. Type “Places > France > Paris” for a keyword inside another. Click a suggestion to use it.")
                .onSubmit(submit)
                .onChange(of: text) { _, newValue in updateSuggestions(newValue) }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlighted = min(highlighted + 1, suggestions.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard suggestions.indices.contains(highlighted) else { return .ignored }
                    accept(suggestions[highlighted])
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !suggestions.isEmpty else { return .ignored }
                    suggestions = []
                    return .handled
                }
            if focused, !suggestions.isEmpty {
                suggestionList
            }
            // Recent and "Often used with" chips (KeywordSuggestions.swift).
            KeywordSuggestionChips(library: library, current: Set(usage.counts.keys), photos: usage.photos,
                                   refresh: added)
        }
        // A draft typed for one selection is never added to the next.
        .onChange(of: library.selectedImageID) { text = "" }
        // Photo › Add Keywords….
        .onChange(of: focus.request) { focused = true }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, path in
                Button {
                    accept(path)
                } label: {
                    HStack(spacing: 4) {
                        Text(KeywordPath.leaf(path)).lineLimit(1)
                        if let parent = KeywordPath.parent(path) {
                            Text(KeywordPath.display(parent)).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlighted ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use keyword \(KeywordPath.display(path))")
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyword suggestions")
    }

    private func updateSuggestions(_ text: String) {
        let token = KeywordPath.lastToken(text)
        let already = Set(KeywordPath.parse(text).dropLast())
        // The folder's keywords and the app-wide dictionary's.
        let available = KeywordDictionaryStore.shared.completionCandidates(folderKeywords: library.availableKeywords)
        suggestions = KeywordPath.suggestions(for: token, in: available, limit: 6)
            .filter { !already.contains($0) && KeywordPath.normalized(token) != $0 }
        highlighted = 0
    }

    private func accept(_ path: String) {
        text = KeywordPath.completing(text, with: path)
        suggestions = []
    }

    private func submit() {
        let keywords = KeywordPath.parse(text)
        text = ""
        suggestions = []
        guard !keywords.isEmpty else { return }
        KeywordAdding.add(keywords, library: library)
        added += 1
    }
}

/// One keyword of the selection.
private struct KeywordChip: View {
    let path: String
    /// Every selected photo has it.
    let onAll: Bool
    let photos: Int
    let onRemove: () -> Void
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onShow) {
                Text(KeywordPath.leaf(path) + (onAll ? "" : "*"))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("\(KeywordPath.display(path))\(onAll ? "" : " (on some of the selected photos)"). Click to show every photo with it.")
            .accessibilityLabel("Keyword \(KeywordPath.display(path))\(onAll ? "" : ", on some of the selected photos")")
            .accessibilityHint("Shows every photo with this keyword")
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(photos > 1 ? "Remove from the \(photos) selected photos" : "Remove this keyword")
            .accessibilityLabel("Remove keyword \(KeywordPath.leaf(path))")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(onAll ? Color.primary : Color.secondary)
        .background(Capsule().fill(Color.secondary.opacity(onAll ? 0.22 : 0.1)))
    }
}

/// Lays its views out left to right, wrapping onto new lines, for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Keyword List

/// The keyword hierarchy, kept rather than worked out in the panel's body,
/// which redraws on every thumbnail. Rebuilt when photos or keywords change,
/// as the filter bar's lists are (`FilterOptions`).
@MainActor
final class KeywordListModel: ObservableObject {
    @Published private(set) var tree: [KeywordTree] = []
    /// Photos in the folder (or collection) with no keyword, for the
    /// No Keywords row (KeywordListNoKeywordsRow).
    @Published private(set) var unkeywordedCount = 0
    private weak var library: Library?
    private var observation: AnyCancellable?
    private var dictionaryObservation: AnyCancellable?

    func attach(to library: Library) {
        guard self.library !== library else { return }
        self.library = library
        rebuild()
        observation = Publishers.Merge(library.$images.map { _ in () }, library.$selectedKeywords.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.rebuild() } }
        // The dictionary, and whether its unused keywords show.
        let store = KeywordDictionaryStore.shared
        dictionaryObservation = Publishers.Merge(store.$dictionary.map { _ in () }, store.$showsDictionaryKeywords.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.rebuild() } }
    }

    func rebuild() {
        guard let library else { return }
        let store = KeywordDictionaryStore.shared
        // Every keyword the folder uses goes into the app-wide dictionary.
        store.record(library.availableKeywords)
        let next = store.showsDictionaryKeywords
            ? KeywordTree.build(from: library.keywordsByImage, including: store.dictionary.paths)
            : library.keywordTree
        if next != tree { tree = next }
        let count = library.unkeywordedCount(in: library.imagesInScope)
        if count != unkeywordedCount { unkeywordedCount = count }
    }
}

/// Lightroom's Keyword List: every keyword in the folder as a hierarchy,
/// with how many photos carry it (or a keyword inside it). Clicking a name
/// shows those photos; the checkbox puts the keyword on, or takes it off,
/// every selected photo.
struct KeywordListView: View {
    @ObservedObject var library: Library
    @StateObject private var model = KeywordListModel()
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var renaming: String?
    @State private var newName = ""
    @ObservedObject private var dictionary = KeywordDictionaryStore.shared
    @State private var creating = false
    @State private var createdName = ""
    @State private var topDropTargeted = false
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("Find keyword", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .accessibilityLabel("Find keyword")
                    .help("Show only keywords whose name contains this")
                dictionaryMenu
            }
            // Dropping a keyword row here moves it to the top level.
            .background(topDropTargeted ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onDrop(of: [.plainText, .utf8PlainText], isTargeted: $topDropTargeted) { providers in
                KeywordDrag.accept(providers, onto: nil, library: library)
            }
            if search.isEmpty, !model.tree.isEmpty {
                KeywordListNoKeywordsRow(library: library, count: model.unkeywordedCount)
            }
            let trees = KeywordTree.filter(model.tree, matching: search)
            if trees.isEmpty {
                Text(model.tree.isEmpty ? "No keywords in this folder yet. Add some to the selected photos above."
                                        : "No keyword matches.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let usage = library.selectionKeywords()
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows(trees)) { row in
                        keywordRow(row.tree, depth: row.depth, usage: usage)
                    }
                }
            }
        }
        .onAppear { model.attach(to: library) }
        .alert("New Keyword", isPresented: $creating) {
            TextField("Name", text: $createdName)
            Button("Add") {
                if let path = KeywordPath.normalized(createdName) {
                    dictionary.record([path])
                    dictionary.showsDictionaryKeywords = true
                    for ancestor in KeywordPath.ancestors(path) { expanded.insert(ancestor) }
                }
                creating = false
            }
            Button("Cancel", role: .cancel) { creating = false }
        } message: {
            Text("Adds the keyword to the keyword dictionary without putting it on any photo. Type a path such as “Places > France > Paris” to put it inside another.")
        }
        .alert("Keyword Dictionary", isPresented: Binding(get: { dictionary.lastError != nil },
                                                          set: { if !$0 { dictionary.lastError = nil } })) {
            Button("OK", role: .cancel) { dictionary.lastError = nil }
        } message: {
            Text(dictionary.lastError ?? "")
        }
        .alert("Rename Keyword", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming, let new = KeywordPath.normalized(newName) {
                    dictionary.rename(old, to: new)
                    library.perform("Renaming a keyword") { try await library.renameKeyword(old, to: new) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Every photo with this keyword gets the new name. Type a path such as “Places > France > Paris” to move it.")
        }
    }

    /// The keyword dictionary's commands (KeywordSuggestions.swift).
    private var dictionaryMenu: some View {
        Menu {
            Toggle("Show Dictionary Keywords", isOn: $dictionary.showsDictionaryKeywords)
            Button("New Keyword…") {
                createdName = ""
                creating = true
            }
            Divider()
            Button("Import Keyword List…") { dictionary.importList() }
            Button("Export Keyword List…") { dictionary.exportList() }
                .disabled(dictionary.dictionary.paths.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The keyword dictionary: keywords kept across every folder, a new keyword, and keyword lists as text files")
        .accessibilityLabel("Keyword dictionary")
    }

    /// The tree as rows, expanded where the user opened it, or everywhere
    /// while searching.
    private struct Row: Identifiable {
        var tree: KeywordTree
        var depth: Int
        var id: String { tree.path }
    }

    private func rows(_ trees: [KeywordTree], depth: Int = 0) -> [Row] {
        trees.flatMap { tree -> [Row] in
            let open = !search.isEmpty || expanded.contains(tree.path)
            return [Row(tree: tree, depth: depth)] + (open ? rows(tree.children, depth: depth + 1) : [])
        }
    }

    private func keywordRow(_ tree: KeywordTree, depth: Int, usage: (photos: Int, counts: [String: Int])) -> some View {
        let onSelection = usage.counts[tree.path] ?? 0
        let state: Bool? = usage.photos == 0 || onSelection == 0 ? false : onSelection == usage.photos ? true : nil
        let isFilter = library.filter.keyword == tree.path
        return HStack(spacing: 4) {
            if tree.children.isEmpty {
                Color.clear.frame(width: 10, height: 10)
            } else {
                Button {
                    if expanded.contains(tree.path) { expanded.remove(tree.path) } else { expanded.insert(tree.path) }
                } label: {
                    Image(systemName: expanded.contains(tree.path) || !search.isEmpty ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded.contains(tree.path) ? "Collapse \(tree.name)" : "Expand \(tree.name)")
            }
            Button {
                library.perform("Changing keywords") { try await library.toggleKeyword(tree.path) }
            } label: {
                Image(systemName: state == true ? "checkmark.square.fill" : state == nil ? "minus.square" : "square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(usage.photos == 0)
            .help(usage.photos == 0 ? "Select photos to put this keyword on them"
                  : state == true ? "Take this keyword off the selected photos" : "Put this keyword on the selected photos")
            .accessibilityLabel("\(tree.name) on selected photos")
            .accessibilityValue(state == true ? "On all" : state == nil ? "On some" : "Off")
            Button {
                library.filter.keyword = isFilter ? nil : tree.path
                library.filter.noKeywords = false
            } label: {
                HStack(spacing: 4) {
                    Text(tree.name).lineLimit(1).truncationMode(.middle)
                        .fontWeight(isFilter ? .semibold : .regular)
                    Spacer(minLength: 2)
                    Text("\(tree.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFilter ? "Showing photos with “\(KeywordPath.display(tree.path))”. Click to show all again."
                  : "Show the \(tree.count) photos with “\(KeywordPath.display(tree.path))” or a keyword inside it")
            .accessibilityLabel("Show photos with \(KeywordPath.display(tree.path))")
            .accessibilityValue("\(tree.count) photos")
            .accessibilityAddTraits(isFilter ? .isSelected : [])
        }
        .font(.caption)
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 1)
        .background(dropTarget == tree.path ? Color.accentColor.opacity(0.35)
                    : isFilter ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 3))
        // Drag a row onto another to move it inside; drop photos from the
        // grid on a row to give them the keyword (KeywordSuggestions.swift).
        .onDrag { KeywordDrag.provider(for: tree.path) }
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText],
                isTargeted: Binding(get: { dropTarget == tree.path },
                                    set: { dropTarget = $0 ? tree.path : (dropTarget == tree.path ? nil : dropTarget) })) { providers in
            KeywordDrag.accept(providers, onto: tree.path, library: library)
        }
        .contextMenu {
            Button(isFilter ? "Show All Photos" : "Show Photos with This Keyword") {
                library.filter.keyword = isFilter ? nil : tree.path
                library.filter.noKeywords = false
            }
            Divider()
            Button("Add to Selected Photos") {
                library.perform("Adding a keyword") { try await library.addKeywords([tree.path]) }
            }
            .disabled(usage.photos == 0)
            Button("Remove from Selected Photos") {
                library.perform("Removing a keyword") { try await library.removeKeywords([tree.path]) }
            }
            .disabled(onSelection == 0)
            Divider()
            Button("Rename…") {
                newName = KeywordPath.entryText(tree.path)
                renaming = tree.path
            }
            Button("Delete Keyword") {
                // Forgotten by the keyword dictionary too, or it would come
                // back with a count of zero.
                let path = tree.path
                library.perform("Deleting a keyword") {
                    try await library.deleteKeyword(path)
                    KeywordDictionaryStore.shared.remove(path)
                }
            }
        }
    }
}
