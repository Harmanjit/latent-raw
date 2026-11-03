import Foundation
import Combine

/// The open catalog's collections as the UI sees them: the list, which one
/// the grid is showing, and how many photos each holds. Owned by the
/// Library (`Library.collections`), which asks it what the grid may show.
///
/// Every change goes the way the Custom sort's does: the new state shows at
/// once, its undo is filed at once, and the catalog is written in the
/// background (`Catalog.saveCollections`), whole and in order. If a write
/// fails, what the catalog holds comes back and the status bar says why.
@MainActor
public final class LibraryCollections: ObservableObject {
    @Published public private(set) var state = CollectionsState()
    /// The collection the grid shows, nil for the whole folder.
    @Published public private(set) var activeID: Int64?
    /// Photos in each collection (for a set, in everything inside it).
    @Published public private(set) var counts: [Int64: Int] = [:]

    private weak var library: Library?
    private var observations: Set<AnyCancellable> = []
    private var countTask: Task<Void, Never>?
    /// The last save started; the next waits for it, so the catalog ends
    /// up holding the state shown last.
    private var saveTask: Task<Void, any Error>?

    init(library: Library) {
        self.library = library
        // Counts follow the photos, their edits and (via
        // `contentDidChange`, called by the Library) their keywords.
        library.$images.dropFirst().sink { [weak self] _ in self?.contentDidChange() }.store(in: &observations)
        library.$editedImageIDs.dropFirst().sink { [weak self] _ in self?.contentDidChange() }.store(in: &observations)
    }

    // MARK: What the grid shows

    /// What the active collection lets through, nil when none is active.
    var activeScope: CollectionScope? {
        activeID.flatMap(state.scope(for:))
    }

    public var activeCollection: CatalogCollection? { state.collection(activeID) }

    /// Shows `id` in the grid (nil: the whole folder). The filter bar still
    /// narrows what the collection holds.
    public func show(_ id: Int64?) {
        let next = id.flatMap { state.collection($0) == nil ? nil : $0 }
        guard next != activeID else { return }
        activeID = next
        library?.recomputeVisible()
    }

    /// A new catalog's collections, or the open one's after a refresh.
    func catalogDidLoad(_ loaded: CollectionsState, isNewCatalog: Bool) {
        if isNewCatalog {
            saveTask = nil
            state = loaded
            activeID = nil
        } else {
            // A refresh may have dropped photos; collections already shown
            // stay as they are, since a save of them may still be on its way.
            let ids = Set(library?.images.compactMap(\.id) ?? [])
            state = state.pruned(toImages: ids)
            if let active = activeID, state.collection(active) == nil { activeID = nil }
        }
        contentDidChange()
    }

    /// Photos, keywords or edits changed: counts, and smart collections,
    /// may have too.
    func contentDidChange() {
        countTask?.cancel()
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.recount()
        }
    }

    /// Counts worked out now, for tests and for the first draw.
    func recount() {
        guard let library else { return }
        let edited = library.editedImageIDs
        let keywords = library.keywordIndex
        let images = library.images
        let now = Date()
        var result: [Int64: Int] = [:]
        for collection in state.collections {
            guard let scope = state.scope(for: collection.id) else { continue }
            if scope.rules.isEmpty {
                let present = Set(images.lazy.compactMap(\.id))
                result[collection.id] = scope.ids.intersection(present).count
            } else {
                result[collection.id] = images.lazy.filter { record in
                    scope.includes(record, isEdited: record.id.map(edited.contains) ?? false,
                                   keywords: record.id.flatMap { keywords[$0] } ?? [], now: now)
                }.count
            }
        }
        if result != counts { counts = result }
    }

    // MARK: Changes

    /// Makes a collection and returns its id; nil without an open catalog.
    /// A regular one can start with `adding` in it.
    @discardableResult
    public func create(name: String, kind: CatalogCollection.Kind, in parent: Int64? = nil,
                       rules: SmartCollectionRules? = nil, adding ids: Set<Int64> = []) -> Int64? {
        let name = Self.cleanName(name, kind: kind)
        var next = state
        let id = next.nextID
        let parent = parent.flatMap { next.collection($0)?.kind == .set ? $0 : nil }
        next.collections.append(CatalogCollection(id: id, name: name, kind: kind, parentID: parent,
                                                  rules: kind == .smart ? rules ?? SmartCollectionRules() : nil))
        if kind == .regular, !ids.isEmpty { next.members[id] = ids }
        let title = switch kind {
        case .regular: "New Collection"
        case .smart: "New Smart Collection"
        case .set: "New Collection Set"
        }
        return replace(with: next, actionName: title) ? id : nil
    }

    public func rename(_ id: Int64, to name: String) {
        guard let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = Self.cleanName(name, kind: state.collections[index].kind)
        guard cleaned != state.collections[index].name else { return }
        var next = state
        next.collections[index].name = cleaned
        replace(with: next, actionName: "Rename Collection")
    }

    /// Deletes a collection and, for a set, everything inside it. The
    /// photos themselves are untouched.
    public func delete(_ id: Int64) {
        guard let collection = state.collection(id) else { return }
        let gone = Set(state.subtree(id))
        var next = state
        next.collections.removeAll { gone.contains($0.id) }
        for member in gone { next.members[member] = nil }
        if let target = next.targetID, gone.contains(target) { next.targetID = nil }
        let title = collection.kind == .set ? "Delete Collection Set" : "Delete Collection"
        replace(with: next, actionName: title)
    }

    /// Moves a collection into a set (nil: the top level).
    public func move(_ id: Int64, into parent: Int64?) {
        guard let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        if let parent, !state.possibleParents(for: id).contains(where: { $0.id == parent }) { return }
        guard state.collections[index].parentID != parent else { return }
        var next = state
        next.collections[index].parentID = parent
        replace(with: next, actionName: "Move Collection")
    }

    public func setRules(_ rules: SmartCollectionRules, for id: Int64) {
        guard let index = state.collections.firstIndex(where: { $0.id == id }),
              state.collections[index].kind == .smart, state.collections[index].rules != rules else { return }
        var next = state
        next.collections[index].rules = rules
        replace(with: next, actionName: "Edit Smart Collection")
    }

    /// Adds photos to a regular collection. Returns how many were new.
    @discardableResult
    public func add(_ ids: Set<Int64>, to id: Int64, actionName: String? = nil) -> Int {
        guard state.collection(id)?.kind == .regular else { return 0 }
        let added = ids.subtracting(state.members[id] ?? [])
        guard !added.isEmpty else { return 0 }
        var next = state
        next.members[id, default: []].formUnion(added)
        replace(with: next, actionName: actionName ?? Self.photosAction("Add to Collection", count: added.count))
        return added.count
    }

    /// Takes photos out of a regular collection. Returns how many were in it.
    @discardableResult
    public func remove(_ ids: Set<Int64>, from id: Int64) -> Int {
        let removed = ids.intersection(state.members[id] ?? [])
        guard !removed.isEmpty else { return 0 }
        var next = state
        next.members[id]?.subtract(removed)
        if next.members[id]?.isEmpty == true { next.members[id] = nil }
        replace(with: next, actionName: Self.photosAction("Remove from Collection", count: removed.count))
        return removed.count
    }

    /// The collection B adds to; nil sends B to the Quick Collection.
    public func setTarget(_ id: Int64?) {
        let next = id.flatMap { state.collection($0)?.kind == .regular ? $0 : nil }
        guard next != state.targetID else { return }
        var copy = state
        copy.targetID = next
        replace(with: copy, actionName: "Set Target Collection")
    }

    public static let quickCollectionName = "Quick Collection"

    /// The target collection, else the Quick Collection, if there is one.
    public var targetCollection: CatalogCollection? {
        state.collection(state.targetID)
            ?? state.collections.first { $0.kind == .regular && $0.parentID == nil && $0.name == Self.quickCollectionName }
    }

    /// B, as in Lightroom: the selected photos go into the target
    /// collection, or come out of it when every one is already there.
    /// With no target and no Quick Collection, one is made. One undo step.
    /// Returns what was done, for the status line.
    @discardableResult
    public func toggleInTarget(_ ids: Set<Int64>) -> String? {
        guard !ids.isEmpty else { return nil }
        var next = state
        let target: CatalogCollection
        if let existing = targetCollection {
            target = existing
        } else {
            target = CatalogCollection(id: next.nextID, name: Self.quickCollectionName, kind: .regular)
            next.collections.append(target)
        }
        let current = next.members[target.id] ?? []
        let action: String
        let message: String
        if ids.isSubset(of: current) {
            next.members[target.id] = current.subtracting(ids)
            if next.members[target.id]?.isEmpty == true { next.members[target.id] = nil }
            action = Self.photosAction("Remove from \(target.name)", count: ids.count)
            message = "Removed \(Self.photoCount(ids.count)) from \(target.name)"
        } else {
            let added = ids.subtracting(current)
            next.members[target.id] = current.union(added)
            action = Self.photosAction("Add to \(target.name)", count: added.count)
            message = "Added \(Self.photoCount(added.count)) to \(target.name)"
        }
        return replace(with: next, actionName: action) ? message : nil
    }

    /// Whether every one of `ids` is in the target collection.
    public func targetContains(_ ids: Set<Int64>) -> Bool {
        guard let target = targetCollection, !ids.isEmpty else { return false }
        return ids.isSubset(of: state.members[target.id] ?? [])
    }

    /// The images of the open catalog among dragged file URLs.
    public func imageIDs(forFileURLs urls: [URL]) -> Set<Int64> {
        guard let library, let folder = library.folderURL?.standardizedFileURL.path else { return [] }
        let byPath = Dictionary(library.images.compactMap { r in r.id.map { (r.relPath, $0) } },
                                uniquingKeysWith: { a, _ in a })
        return Set(urls.compactMap { url -> Int64? in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(folder + "/") else { return nil }
            return byPath[String(path.dropFirst(folder.count + 1))]
        })
    }

    // MARK: Undo and saving

    /// Shows `next`, files the way back to what is shown now, and saves.
    /// False without an open catalog.
    @discardableResult
    private func replace(with next: CollectionsState, actionName: String) -> Bool {
        guard let library, let catalog = library.catalog else { return false }
        apply(next, previous: state, actionName: actionName, in: catalog)
        return true
    }

    /// Undo and redo come back here with the two states swapped, so each
    /// files its opposite while the manager is undoing, as UndoManager needs.
    private func apply(_ next: CollectionsState, previous: CollectionsState, actionName: String, in catalog: Catalog) {
        guard let library, catalog === library.catalog else { return }
        state = next
        if let active = activeID, next.collection(active) == nil { activeID = nil }
        library.recomputeVisible()
        recount()
        library.undoRegistration(actionName, in: catalog) { library, catalog in
            library.collections.apply(previous, previous: next, actionName: actionName, in: catalog)
        }(true)
        save(in: catalog)
    }

    private func save(in catalog: Catalog) {
        guard let library else { return }
        let previous = saveTask
        let task = Task<Void, any Error> { @MainActor [weak self] in
            _ = await previous?.result
            // Whatever is shown when the write starts: a later change's
            // save follows this one, so the last write is the last state.
            guard let self, catalog === self.library?.catalog else { return }
            let latest = self.state
            do {
                try await catalog.saveCollections(latest)
            } catch {
                if catalog === self.library?.catalog, let stored = try? await catalog.loadCollections() {
                    self.state = stored
                    if let active = self.activeID, stored.collection(active) == nil { self.activeID = nil }
                    self.library?.recomputeVisible()
                    self.recount()
                }
                throw error
            }
        }
        saveTask = task
        library.perform("Saving collections") { try await task.value }
    }

    /// Waits for every save started so far; for tests.
    func waitForSaves() async {
        _ = await saveTask?.result
        await library?.waitForPendingWork()
    }

    // MARK: Names

    static func cleanName(_ name: String, kind: CatalogCollection.Kind) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return switch kind {
        case .regular: "Untitled Collection"
        case .smart: "Untitled Smart Collection"
        case .set: "Untitled Collection Set"
        }
    }

    static func photosAction(_ action: String, count: Int) -> String {
        count > 1 ? "\(action) (\(count) Images)" : action
    }

    static func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }
}
