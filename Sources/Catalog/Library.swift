import Foundation
import Combine
import CoreGraphics
import os

/// CGImage is immutable but not declared Sendable; this vouches for it so
/// a thumbnail decoded on a background task can be handed to the UI.
public struct ThumbnailImage: @unchecked Sendable {
    public let cgImage: CGImage
}

/// The open catalog as the UI sees it: the image list, selection,
/// thumbnails and the open-folder flow. UI-framework-free (Combine only)
/// so the whole thing can be exercised from tests without a window.
///
/// Main-actor because it publishes to views. The heavy work — reconcile,
/// thumbnail generation, thumbnail decoding — happens on the catalog
/// actor or on utility-priority tasks and only the results land here.
@MainActor
public final class Library: ObservableObject {
    @Published public private(set) var folderURL: URL?
    @Published public private(set) var images: [ImageRecord] = [] {
        didSet { if !isPatchingRecords { recomputeVisible() } }
    }
    /// The grid's contents: `images` after `filter` and `sort`.
    @Published public private(set) var visibleImages: [ImageRecord] = []
    /// Bumped when `visibleImages` gains, loses or reorders images, but not
    /// when a record in it only changes in place (a rating, say). The grid
    /// rebuilds on the first and redraws just the changed cells on the second.
    public private(set) var visibleListVersion = 0
    /// Set while re-read records are patched into `images`, or a whole list
    /// is put in place, by code that then decides for itself whether the
    /// visible list needs recomputing.
    private var isPatchingRecords = false
    @Published public var filter = LibraryFilter() {
        didSet { if filter != oldValue { recomputeVisible() } }
    }
    @Published public var sort = LibrarySort.default {
        didSet {
            guard sort != oldValue else { return }
            recomputeVisible()
            sortDidChange?(sort, sortMemory)
        }
    }
    /// The directions of the sort keys not showing (see `chooseSortKey`).
    public var sortMemory = LibrarySortMemory()
    /// Called after every change of `sort`, with the directions to keep.
    /// The app saves both here so the choice outlives the launch; tests and
    /// a Library without the app keep them in memory only.
    public var sortDidChange: (@MainActor (LibrarySort, LibrarySortMemory) -> Void)?
    /// The open catalog's saved Custom arrangement (see `CustomOrder`):
    /// catalog-relative paths, empty when none was ever made.
    public internal(set) var customOrder: [String] = [] {
        didSet {
            customPositions = CustomOrder.positions(customOrder)
            if sort.key == .custom, !isPatchingRecords { recomputeVisible() }
        }
    }
    private var customPositions: [String: Int] = [:]
    /// image id → keywords, for filtering; refreshed with the image list
    /// and whenever keywords are edited.
    var keywordIndex: [Int64: Set<String>] = [:] {
        didSet { if filter.keyword != nil, !isPatchingRecords { recomputeVisible() } }
    }
    @Published public private(set) var isBusy = false
    /// Opens and refreshes still running. They can overlap (a second folder
    /// clicked while the first reconciles), so one finishing isn't the end.
    private var busyCount = 0 {
        didSet { if isBusy != (busyCount > 0) { isBusy = busyCount > 0 } }
    }
    @Published public private(set) var statusText = "No folder open"
    @Published public private(set) var thumbnailsDone = 0
    @Published public private(set) var thumbnailsTotal = 0
    /// Subfolders Latent found but has no decision for (DESIGN.md §5.2).
    @Published public private(set) var undecidedSubfolders: [String] = []
    /// Bumped whenever thumbnails land, so a grid knows to refresh cells.
    @Published public private(set) var thumbnailVersion = 0
    /// The most recent failure of a catalog operation, for the status bar.
    /// Cleared by the next success or by the user.
    @Published public var lastError: String?
    /// Images that have a stored edit, so the grid can badge them.
    @Published public internal(set) var editedImageIDs: Set<Int64> = [] {
        didSet { if filter.editedOnly, !isPatchingRecords { recomputeVisible() } }
    }

    /// The primary selection: what the editor opens and the panel edits.
    @Published public var selectedImageID: Int64? {
        didSet { if selectedImageID != oldValue { Task { await reloadSelectedKeywords() } } }
    }
    /// Everything selected in the grid (Cmd-click, Shift-click). Batch
    /// operations such as export act on this; it always contains the
    /// primary selection when there is one.
    @Published public var selectedImageIDs: Set<Int64> = []

    public var selectedImages: [ImageRecord] {
        images.filter { $0.id.map(selectedImageIDs.contains) ?? false }
    }

    /// Sets both selections from the grid. The primary (lead) is `primary`
    /// if it's selected, else the current one if it still is, else the
    /// first selected image in grid order: never an arbitrary member of
    /// the set (see `GridSelection`).
    public func setSelection(_ ids: Set<Int64>, primary: Int64?) {
        let lead = GridSelection.resolvedLead(proposed: primary, current: selectedImageID, selected: ids,
                                              order: visibleImages)
        if selectedImageIDs != ids { selectedImageIDs = ids }
        if selectedImageID != lead { selectedImageID = lead }
    }

    /// Selects every visible image and keeps the lead where it is (⌘A).
    public func selectAllVisible() {
        setSelection(Set(visibleImages.compactMap(\.id)), primary: selectedImageID)
    }

    public private(set) var catalog: Catalog?

    /// Decoded thumbnails for display, bounded in bytes. The HEIC files in
    /// `_latent/thumbnails` are the disk tier.
    public let thumbnailLoader = ThumbnailLoader()
    /// Where the open catalog's thumbnail files are. Changes in the same
    /// step as `catalog` and `images`, so a cell never asks for one
    /// catalog's thumbnail under another's ids.
    private var thumbnailDirectory: URL?

    /// Renders thumbnails for edited images. Set by the app (it needs the
    /// GPU pipeline, which the catalog doesn't know about).
    public var thumbnailRenderer: (any EditedThumbnailRenderer)?
    private var thumbnailTask: Task<Void, Never>?

    public init() {}

    public var selectedImage: ImageRecord? {
        images.first { $0.id == selectedImageID }
    }

    /// Runs a catalog operation and, if it fails, records what and why
    /// instead of dropping the error. Every UI action that writes to the
    /// catalog goes through here, so a read-only or full volume shows
    /// up in the status bar rather than as a rating that didn't stick.
    ///
    /// Each operation is counted until it finishes, so quitting can wait
    /// for a rating or an edit made just before Cmd-Q to reach the sidecar
    /// and the database (see `waitForPendingWork`).
    public func perform(_ what: String, _ operation: @escaping @MainActor () async throws -> Void) {
        pendingOperations += 1
        Task { @MainActor in
            defer { operationFinished() }
            do {
                try await operation()
            } catch {
                lastError = "\(what) failed: \(error)"
                Self.logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Operations started with `perform` that haven't finished, and the
    /// callers waiting for that count to reach zero.
    private var pendingOperations = 0
    private var pendingWorkWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether any operation started with `perform` is still running.
    public var hasPendingWork: Bool { pendingOperations > 0 }

    /// Returns once every operation started with `perform` has finished,
    /// including any started while it waits (an operation that starts
    /// another, say). There is no timeout here; a caller that can't wait
    /// forever, such as quitting, bounds the wait itself.
    public func waitForPendingWork() async {
        // A loop, not a single wait: between the count reaching zero and
        // this waiter running, another operation may have started.
        while pendingOperations > 0 {
            await withCheckedContinuation { pendingWorkWaiters.append($0) }
        }
    }

    private func operationFinished() {
        pendingOperations -= 1
        guard pendingOperations == 0 else { return }
        let waiters = pendingWorkWaiters
        pendingWorkWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    static let logger = Logger(subsystem: "com.latent.app", category: "catalog")

    /// Position in the *visible* list, which is what arrow keys walk.
    public var selectedIndex: Int? {
        visibleImages.firstIndex { $0.id == selectedImageID }
    }

    // MARK: - Filtering and sorting

    private func recomputeVisible() {
        let edited = editedImageIDs
        let filter = filter
        let index = keywordIndex
        let passing = filter.isActive
            ? images.filter { record in
                filter.matches(record, isEdited: record.id.map(edited.contains) ?? false,
                               keywords: record.id.flatMap { index[$0] } ?? [])
            }
            : images
        let next = passing.sorted(by: sort, customPositions: customPositions)
        if next != visibleImages {
            if !next.elementsEqual(visibleImages, by: { $0.id == $1.id }) {
                visibleListVersion += 1
                deselectHidden(visible: next)
            }
            visibleImages = next
        }
    }

    /// A filter (or a rating under one) that hides selected images
    /// deselects them: the grid shows only visible images selected, and
    /// batch actions such as rating, paste and export must act on exactly
    /// those. The lead stays even if hidden: in Loupe and Develop it's the
    /// image on screen, and moving it would send the next key to another.
    private func deselectHidden(visible: [ImageRecord]) {
        guard !selectedImageIDs.isEmpty else { return }
        let shown = selectedImageIDs.intersection(visible.lazy.compactMap(\.id))
        if shown != selectedImageIDs { selectedImageIDs = shown }
    }

    /// Puts re-read records into `images` and `visibleImages` in place.
    /// The whole folder is filtered and sorted again only when the active
    /// filter or sort looks at what changed (rating under a rating sort,
    /// say), so a rating or flag key press doesn't rebuild the grid.
    private func applyChangedRecords(_ fresh: [Int64: ImageRecord]) {
        var updated = images
        var changed = false
        var reorder = false
        for index in updated.indices {
            guard let id = updated[index].id, let record = fresh[id], record != updated[index] else { continue }
            if filter.dependsOnChange(from: updated[index], to: record)
                || sort.dependsOnChange(from: updated[index], to: record) {
                reorder = true
            }
            updated[index] = record
            changed = true
        }
        guard changed else { return }
        isPatchingRecords = true
        images = updated
        isPatchingRecords = false
        if reorder {
            recomputeVisible()
            return
        }
        var visible = visibleImages
        for index in visible.indices {
            if let id = visible[index].id, let record = fresh[id] { visible[index] = record }
        }
        if visible != visibleImages { visibleImages = visible }
    }

    /// Distinct values for the filter pickers, from the whole folder (not
    /// the filtered view, or a picker would lose entries as you narrow).
    public var availableCameras: [String] {
        Array(Set(images.compactMap(\.camera))).sorted()
    }
    public var availableLenses: [String] {
        Array(Set(images.compactMap(\.lens))).sorted()
    }
    public var availableKeywords: [String] {
        Array(keywordIndex.values.reduce(into: Set<String>()) { $0.formUnion($1) }).sorted()
    }
    /// Every Finder tag in the folder, by name, each in the colour its
    /// first file shows it in.
    public var availableFinderTags: [FinderTag] {
        var byName: [String: FinderTag] = [:]
        for record in images where record.finderTags != nil {
            for tag in record.tags where byName[tag.name] == nil { byName[tag.name] = tag }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func fileURL(for record: ImageRecord) -> URL? {
        folderURL?.appendingPathComponent(record.relPath)
    }

    /// What Reveal in Finder shows: the selected originals, or the primary
    /// when only that is set, or the folder itself when nothing is selected.
    public var revealInFinderURLs: [URL] {
        guard let folderURL else { return [] }
        let targets = selectedImageIDs.isEmpty ? selectedImage.map { [$0] } ?? [] : selectedImages
        return targets.isEmpty ? [folderURL] : targets.map { folderURL.appendingPathComponent($0.relPath) }
    }

    // MARK: - Opening

    /// Bumped by every open and every refresh respectively. Each captures
    /// its number and shows its results only if no later one has started,
    /// so a slow folder clicked first can't put its list over the one
    /// clicked next.
    private var openGeneration = 0
    private var refreshGeneration = 0

    /// Called just before another catalog replaces the open one, while
    /// `catalog` is still the old one. The app closes its editor here: an
    /// image of the old folder opened while the new one loaded then saves
    /// its pending edit into its own catalog, not under the same id in the
    /// next.
    public var willReplaceCatalog: (@MainActor () -> Void)?

    /// Where library actions (ratings, flags, rotation, keywords, pasted
    /// settings, file moves and renames) register their undo. The app sets
    /// it to the window's undo manager; nil means those actions can't be
    /// undone, as in tests that don't set one.
    public weak var undoManager: UndoManager?

    /// Move to Folder, Copy to Folder and Rename (LibraryFileOperations).
    public private(set) lazy var fileOperations = LibraryFileOperations(library: self)
    /// Called when an undo or redo has put back rotations or stored edits
    /// of images in the open catalog, so an editor holding one catches up.
    public var didRestoreImages: (@MainActor (Set<Int64>, RestoredAspect) -> Void)?
    /// The undo or redo being restored last; the next waits for it.
    var undoRestores: Task<Void, any Error>?

    /// Tests only: runs after a folder's list is read and before it is
    /// shown, so a test can hold one open or refresh while another finishes.
    var willPublishList: (@MainActor (Catalog) async throws -> Void)?

    /// Opens (or creates) the catalog in `folder`, reconciles, shows the
    /// images, then generates thumbnails in the background.
    ///
    /// Until the new list is ready the Library stays wholly on the previous
    /// catalog: its images, its selection and its thumbnails, so a key
    /// pressed meanwhile changes the photo the user sees. Then everything
    /// switches in one step. If opening fails, nothing has switched.
    ///
    /// Returns false, without showing anything, when a later `open` started
    /// before this one finished: that folder is the one the user wants.
    @discardableResult
    public func open(folder: URL, defaultSubfolderMode: SubfolderMode? = nil) async throws -> Bool {
        openGeneration += 1
        let generation = openGeneration
        busyCount += 1
        defer { busyCount -= 1 }
        let opening = "Opening \(folder.lastPathComponent)…"
        let previousStatus = statusText
        statusText = opening

        do {
            // Off the main thread: the database may be on a slow disk or a
            // network share.
            let catalog = try await Task.detached(priority: .userInitiated) { try Catalog.open(at: folder) }.value
            // A catalog that has never recorded a subfolder policy takes the
            // app's default; one that has keeps its own.
            if let mode = defaultSubfolderMode, try await catalog.setting(Catalog.defaultSubfolderModeKey) == nil {
                try await catalog.setDefaultSubfolderMode(mode)
            }
            let list = try await loadList(from: catalog)
            guard generation == openGeneration else { return false }
            publish(list, of: catalog, isNewCatalog: true)
            return true
        } catch {
            // Overtaken as well as failed: the folder opening now matters,
            // not this one's error.
            guard generation == openGeneration else { return false }
            if statusText == opening { statusText = previousStatus }
            throw error
        }
    }

    /// Re-reconciles the open folder (the Refresh action, DESIGN.md §5.3
    /// "no live watching"). Its result is dropped if another folder opened,
    /// or another refresh started, while it ran.
    public func refresh() async throws {
        guard let catalog else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        busyCount += 1
        defer { busyCount -= 1 }

        let list = try await loadList(from: catalog)
        guard catalog === self.catalog, generation == refreshGeneration else { return }
        publish(list, of: catalog, isNewCatalog: false)
    }

    /// Everything the grid shows of a catalog, read but not yet shown.
    private struct LoadedList {
        var report: ReconcileReport
        var rootPath: URL
        var thumbnailDirectory: URL
        var images: [ImageRecord]
        var editedImageIDs: Set<Int64>
        var keywordIndex: [Int64: Set<String>]
        var customOrder: [String]
    }

    /// Reconciles `catalog` and reads its list, touching nothing shown:
    /// the awaits here are where another open or refresh can overtake.
    private func loadList(from catalog: Catalog) async throws -> LoadedList {
        let report = try await catalog.reconcile()
        let list = LoadedList(report: report,
                              rootPath: catalog.rootPath,
                              thumbnailDirectory: await catalog.thumbnailDirectory,
                              images: try await catalog.allImages(),
                              editedImageIDs: try await catalog.editedImageIDs(),
                              keywordIndex: try await catalog.allImageKeywords(),
                              customOrder: await catalog.customOrder())
        try await willPublishList?(catalog)
        return list
    }

    /// Shows `list` as `catalog`'s. One synchronous step: the catalog, its
    /// folder, thumbnails, images, badges, keywords and selection always
    /// belong together, whatever runs between two awaits elsewhere.
    private func publish(_ list: LoadedList, of catalog: Catalog, isNewCatalog: Bool) {
        if isNewCatalog {
            willReplaceCatalog?()
            if let old = self.catalog, old !== catalog { dropUndo(for: old) }
            thumbnailTask?.cancel()
            // Image ids belong to a catalog: nothing decoded for the old one
            // may be shown, or cached, under the new one's ids. Ids also
            // restart in every catalog, so two folders can list the same ids
            // (even the same names) in the same order: a new catalog always
            // counts as a new list.
            thumbnailLoader.removeAll()
            visibleListVersion += 1
            self.catalog = catalog
            folderURL = list.rootPath
            selectedImageID = nil
            selectedImageIDs = []
        }
        thumbnailDirectory = list.thumbnailDirectory
        undecidedSubfolders = list.report.undecidedSubfolders
        // All three before filtering once, so the visible list is never
        // worked out from one list's images and another's badges.
        isPatchingRecords = true
        images = list.images
        editedImageIDs = list.editedImageIDs
        keywordIndex = list.keywordIndex
        customOrder = list.customOrder
        isPatchingRecords = false
        recomputeVisible()
        if let selected = selectedImageID, !images.contains(where: { $0.id == selected }) {
            selectedImageID = nil
        }
        selectedImageIDs = selectedImageIDs.filter { id in images.contains { $0.id == id } }
        statusText = "\(images.count) images · \(list.report)"

        startThumbnailGeneration()
    }

    /// Records a decision for every undecided subfolder and rescans.
    public func decideUndecidedSubfolders(include: Bool) async throws {
        guard let catalog else { return }
        for relPath in undecidedSubfolders {
            try await catalog.setSubfolderMode(include ? .included : .independent, forRelPath: relPath)
        }
        // Another folder opened meanwhile: its question is still open.
        guard catalog === self.catalog else { return }
        undecidedSubfolders = []
        try await refresh()
    }

    // MARK: - Thumbnails

    func startThumbnailGeneration() {
        guard let catalog else { return }
        thumbnailTask?.cancel()
        thumbnailsDone = 0
        thumbnailsTotal = 0
        thumbnailTask = Task { [weak self] in
            do {
                let needed = try await catalog.imagesNeedingThumbnails().count
                // Every hop back checks the catalog is still the open one:
                // cancelling doesn't stop a generation already under way.
                await MainActor.run { if self?.catalog === catalog { self?.thumbnailsTotal = needed } }
                guard needed > 0 else { return }
                let renderer = await self?.thumbnailRenderer
                let report = try await catalog.generateMissingThumbnails(
                    editedRenderer: renderer
                ) { done, total in
                    Task { @MainActor in
                        guard self?.catalog === catalog else { return }
                        self?.thumbnailsDone = done
                        self?.thumbnailsTotal = total
                        // Refresh the grid every few, and at the end, rather
                        // than per file — cells reload cheaply but not for free.
                        if done % 8 == 0 || done == total { self?.thumbnailVersion += 1 }
                    }
                }
                await MainActor.run {
                    guard let self, self.catalog === catalog else { return }
                    // Files that replaced an older thumbnail replace what the
                    // cache holds; first-time files can't be cached stale.
                    if !report.replacedRelPaths.isEmpty {
                        let replaced = Set(report.replacedRelPaths)
                        self.thumbnailLoader.invalidate(ids: Set(self.images.lazy
                            .filter { replaced.contains($0.relPath) }.compactMap(\.id)))
                    }
                    if !report.regeneratedRelPaths.isEmpty { self.thumbnailVersion += 1 }
                    if !report.failures.isEmpty {
                        self.statusText += " · \(report.failures.count) thumbnails failed"
                    }
                }
            } catch {
                await MainActor.run { if self?.catalog === catalog { self?.statusText = "Thumbnails failed: \(error)" } }
            }
        }
    }

    /// The cached thumbnail, camera-oriented (the user's rotation not
    /// applied), if it's been loaded. On a miss, call `loadThumbnail`.
    public func cachedThumbnail(for record: ImageRecord) -> CGImage? {
        guard let id = record.id else { return nil }
        return thumbnailLoader.cachedImage(id: id, quarterTurns: 0, pixelSize: Thumbnailer.size)
    }

    /// Decodes the thumbnail file off the main thread and caches it. Returns
    /// nil when the file doesn't exist yet (generation still running).
    /// Camera-oriented, like `cachedThumbnail`.
    public func loadThumbnail(for record: ImageRecord) async -> CGImage? {
        if let cached = cachedThumbnail(for: record) { return cached }
        let image: ThumbnailImage? = await withCheckedContinuation { continuation in
            let started = requestThumbnail(for: record, quarterTurns: 0, pixelSize: Thumbnailer.size) { image in
                continuation.resume(returning: image.map(ThumbnailImage.init))
            }
            if started == nil { continuation.resume(returning: nil) }
        }
        return image?.cgImage
    }

    /// The thumbnail as the grid shows it, turned by the image's own
    /// rotation and at least `pixelSize` on its long edge, if it's in memory.
    public func displayThumbnail(for record: ImageRecord, pixelSize: Int) -> CGImage? {
        guard let id = record.id else { return nil }
        return thumbnailLoader.cachedImage(id: id, quarterTurns: record.userRotation, pixelSize: pixelSize)
    }

    /// Asks for `displayThumbnail` to be decoded. The completion runs on the
    /// main actor, never after the returned request is cancelled; nil means
    /// nothing was asked for (no catalog open yet, or an unsaved record).
    @discardableResult
    public func requestDisplayThumbnail(for record: ImageRecord, pixelSize: Int,
                                        completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> ThumbnailRequest? {
        requestThumbnail(for: record, quarterTurns: record.userRotation, pixelSize: pixelSize, completion: completion)
    }

    private func requestThumbnail(for record: ImageRecord, quarterTurns: Int, pixelSize: Int,
                                  completion: @escaping @MainActor @Sendable (CGImage?) -> Void) -> ThumbnailRequest? {
        guard let id = record.id, let thumbnailDirectory else { return nil }
        // Same layout as Catalog.thumbnailURL(forRelPath:), without a hop
        // onto the catalog's actor for every cell.
        let url = thumbnailDirectory.appendingPathComponent(record.relPath + ".heic")
        return thumbnailLoader.request(id: id, url: url, quarterTurns: quarterTurns, pixelSize: pixelSize,
                                       completion: completion)
    }

    // MARK: - Metadata on the selection

    /// Keywords of the selected image, refreshed whenever selection or
    /// keywords change. Published separately because keywords live in
    /// their own tables, not on the ImageRecord.
    @Published public private(set) var selectedKeywords: [String] = []

    private func reloadSelectedKeywords() async {
        guard let id = selectedImageID, let catalog else { selectedKeywords = []; return }
        do {
            selectedKeywords = try await catalog.keywords(forImageID: id)
        } catch {
            selectedKeywords = []
            lastError = "Reading keywords failed: \(error)"
        }
    }

    /// The images a rating, flag or rotation applies to: the whole grid
    /// selection, as in Lightroom's grid. If the set doesn't hold the
    /// primary — the editor made another image primary without touching
    /// the grid, or the set is left over from before — only the primary
    /// changes, so images the user can't see selected are never touched.
    /// For the same reason the grid never changes what its filter hides,
    /// a hidden primary included; Loupe and Develop (`onlyPrimary`) change
    /// the image on screen, filtered out or not.
    private func metadataTargets(onlyPrimary: Bool) -> [ImageRecord] {
        guard let primary = selectedImage else { return [] }
        if onlyPrimary { return [primary] }
        let visibleIDs = Set(visibleImages.lazy.compactMap(\.id))
        let shown = { (record: ImageRecord) in record.id.map(visibleIDs.contains) ?? false }
        guard let primaryID = primary.id, selectedImageIDs.contains(primaryID) else {
            return shown(primary) ? [primary] : selectedImages.filter(shown)
        }
        return selectedImages.filter(shown)
    }

    /// A metadata change that failed on some of the selected images. The
    /// others were still changed; this names the ones that weren't.
    public struct SelectionChangeError: Error, CustomStringConvertible {
        public var total: Int
        public var failures: [(fileName: String, error: any Error)]

        public var description: String {
            let names = failures.map { "\($0.fileName) (\($0.error))" }.joined(separator: ", ")
            return "\(failures.count) of \(total) images: \(names)"
        }
    }

    /// Runs a catalog change (row plus sidecar, like any single change) on
    /// each of `records`, then refreshes those rows locally so the grid,
    /// filters and badges update without a full reload. One image failing
    /// doesn't stop the rest; the failures are thrown together at the end
    /// so `perform` reports them.
    /// Internal rather than private so tests can hold a change open.
    func change(_ records: [ImageRecord],
                _ change: @Sendable (Catalog, Int64, ImageRecord) async throws -> Void) async throws {
        guard let catalog, !records.isEmpty else { return }
        var failures: [(fileName: String, error: any Error)] = []
        var fresh: [Int64: ImageRecord] = [:]
        for record in records {
            guard let id = record.id else { continue }
            var failed = false
            do {
                try await change(catalog, id, record)
            } catch {
                failed = true
                failures.append((record.fileName, error))
                Self.logger.error("Changing \(record.fileName, privacy: .private) failed: \(String(describing: error), privacy: .private)")
            }
            // Re-read even after a failure: the row commits before the
            // sidecar is written, so a failed sidecar can leave a changed row.
            do {
                fresh[id] = try await catalog.image(forRelPath: record.relPath)
            } catch {
                if !failed { failures.append((record.fileName, error)) }
            }
        }
        // Patch whatever `images` is now (a refresh may have landed during
        // the awaits), in one assignment, recomputing the visible list only
        // if the filter or sort cares. Unless another folder opened: the
        // writes stayed in the catalog these records belong to, but `images`
        // is now the other catalog's, where the same ids are other photos.
        if catalog === self.catalog {
            applyChangedRecords(fresh)
            await reloadSelectedKeywords()
        }
        if failures.count == 1, records.count == 1 { throw failures[0].error }
        if !failures.isEmpty { throw SelectionChangeError(total: records.count, failures: failures) }
    }

    public func setRating(_ rating: Int, onlyPrimary: Bool = false) async throws {
        let written = catalog, after = min(max(rating, 0), 5), before = UndoLedger<Int>()
        defer {
            let changed = before.recorded.filter { $0.value != after }
            fileFreshUndo("Rating", count: changed.count, in: written,
                          undo: .rating(changed), redo: .rating(changed.mapValues { _ in after }))
        }
        try await change(metadataTargets(onlyPrimary: onlyPrimary)) { catalog, id, _ in
            if let previous = try await catalog.exchangeRating(rating, forImageID: id) { before.record(id, previous) }
        }
    }

    public func setFlag(_ flag: ImageFlag, onlyPrimary: Bool = false) async throws {
        let written = catalog, before = UndoLedger<Int>()
        defer {
            let changed = before.recorded.filter { $0.value != flag.rawValue }
            fileFreshUndo("Flag", count: changed.count, in: written,
                          undo: .flag(changed), redo: .flag(changed.mapValues { _ in flag.rawValue }))
        }
        try await change(metadataTargets(onlyPrimary: onlyPrimary)) { catalog, id, _ in
            if let previous = try await catalog.exchangeFlag(flag, forImageID: id) { before.record(id, previous) }
        }
    }

    /// Keywords stay primary-only: the keyword field shows the primary's
    /// keywords and this replaces the whole list with them, so applying
    /// it to the selection would wipe every other image's own keywords.
    public func setKeywords(_ keywords: [String]) async throws {
        let written = catalog
        let target = selectedImage
        let cleaned = Set(keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let before = UndoLedger<[String]>()
        defer {
            let changed = before.recorded.filter { Set($0.value) != cleaned }
            fileFreshUndo("Keywords", count: changed.count, in: written,
                          undo: .keywords(changed), redo: .keywords(changed.mapValues { _ in cleaned.sorted() }))
        }
        try await change(target.map { [$0] } ?? []) { catalog, id, _ in
            before.record(id, try await catalog.exchangeKeywords(keywords, forImageID: id))
        }
        // The image written, not whatever is selected after the write, and
        // only while its catalog is still the open one.
        if let id = target?.id, written === catalog {
            keywordIndex[id] = cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Adds quarter turns clockwise (negative for counter-clockwise) to
    /// each selected image, each from its own current rotation. That is read
    /// by the catalog as it writes, not from `images`: a second press while
    /// the first is still writing would otherwise start from the same
    /// rotation and lose a turn.
    public func rotateSelected(by quarterTurns: Int, onlyPrimary: Bool = false) async throws {
        let written = catalog, turned = UndoLedger<Bool>()
        defer {
            let ids = quarterTurns % 4 == 0 ? [] : Array(turned.recorded.keys)
            fileFreshUndo("Rotation", count: ids.count, in: written,
                          undo: .rotation(ids, quarterTurns: -quarterTurns), redo: .rotation(ids, quarterTurns: quarterTurns))
        }
        try await change(metadataTargets(onlyPrimary: onlyPrimary)) { catalog, id, _ in
            try await catalog.rotate(by: quarterTurns, forImageID: id)
            turned.record(id, true)
        }
    }

    // MARK: - Edits

    /// The stored edit stack for an image, or nil if it's unedited. Throws
    /// if the catalog can't be read: "unedited" and "unreadable" must not
    /// look the same, or an image would open at defaults and the next
    /// save would overwrite an edit that was there all along.
    public func editStack(for record: ImageRecord) async throws -> String? {
        guard let id = record.id, let catalog else { return nil }
        return try await catalog.editStack(forImageID: id)
    }

    /// Persists an edit stack (nil = back to defaults) for an image by id,
    /// which need not be the selection — the editor may still be saving
    /// the previous image after the user moved on.
    ///
    /// `target` is the catalog the id belongs to, captured when the edit
    /// settled: by the time this runs another folder may be open, where
    /// the same id is a different photo. Nil means the open catalog.
    public func saveEditStack(_ json: String?, schemaVersion: Int, processVersion: String,
                              forImageID id: Int64, in target: Catalog? = nil) async throws {
        guard let catalog = target ?? catalog else { return }
        try await catalog.setEditStack(json, schemaVersion: schemaVersion,
                                       processVersion: processVersion, forImageID: id)
        guard catalog === self.catalog else { return }
        if json == nil { editedImageIDs.remove(id) } else { editedImageIDs.insert(id) }
        // The thumbnail no longer matches the edit; regenerate in the
        // background (DESIGN.md §10: after the edit is saved, never while
        // a slider is being dragged).
        startThumbnailGeneration()
    }

    public struct TransformOutcome: Equatable, Sendable {
        public var changed = 0
        /// Images left alone because their stored edit couldn't be read or
        /// the transform threw; never silently replaced.
        public var skipped: [String] = []
    }

    /// Applies `transform` to the stored edit JSON of each selected image
    /// (nil in = no edit yet). Used for batch paste and presets; the
    /// caller supplies the merge since the catalog doesn't know the
    /// stack's contents. An image whose existing edit can't be read, or
    /// whose transform throws, is skipped and named in the outcome.
    /// `onlyPrimary` as for ratings: a view showing one image changes that one.
    /// Undo, under `undoName`, puts back each changed image's stored edit.
    @discardableResult
    public func transformSelectedEdits(onlyPrimary: Bool = false, schemaVersion: Int, processVersion: String,
                                       undoName: String = "Change Settings",
                                       _ transform: (String?) throws -> String?) async throws -> TransformOutcome {
        guard let catalog else { return TransformOutcome() }
        var outcome = TransformOutcome()
        var before: [Int64: StoredEdit?] = [:], after: [Int64: StoredEdit?] = [:]
        defer {
            fileFreshUndo(undoName, count: before.count, in: catalog, undo: .edits(before), redo: .edits(after))
        }
        for record in onlyPrimary ? metadataTargets(onlyPrimary: true) : selectedImages {
            guard let id = record.id else { continue }
            let stored: StoredEdit?
            let existing: String?
            let next: String?
            do {
                stored = try await catalog.storedEdit(forImageID: id)
                existing = stored?.json
                next = try transform(existing)
            } catch {
                outcome.skipped.append(record.fileName)
                Self.logger.error("Skipped \(record.fileName, privacy: .private): \(String(describing: error), privacy: .private)")
                continue
            }
            if next != existing {
                try await catalog.setEditStack(next, schemaVersion: schemaVersion,
                                               processVersion: processVersion, forImageID: id)
                before[id] = .some(stored)
                after[id] = .some(next.map { StoredEdit(json: $0, schemaVersion: schemaVersion, processVersion: processVersion) })
                // The badges are the open catalog's; another folder may
                // have opened during the write.
                if catalog === self.catalog {
                    if next == nil { editedImageIDs.remove(id) } else { editedImageIDs.insert(id) }
                }
                outcome.changed += 1
            }
        }
        if outcome.changed > 0, catalog === self.catalog { startThumbnailGeneration() }
        return outcome
    }

    // MARK: - Snapshots and history (per image, stored with the catalog)

    public func snapshots(for record: ImageRecord) async throws -> [(name: String, stackJSON: String)] {
        guard let id = record.id, let catalog else { return [] }
        return try await catalog.snapshots(forImageID: id)
    }

    public func setSnapshots(_ snapshots: [(name: String, stackJSON: String)], forImageID id: Int64,
                             in target: Catalog? = nil) async throws {
        try await (target ?? catalog)?.setSnapshots(snapshots, forImageID: id)
    }

    public func history(for record: ImageRecord) async throws -> [(stackJSON: String, createdAt: Int64)] {
        guard let id = record.id, let catalog else { return [] }
        return try await catalog.history(forImageID: id)
    }

    public func setHistory(_ steps: [(stackJSON: String, createdAt: Int64)], forImageID id: Int64,
                           in target: Catalog? = nil) async throws {
        try await (target ?? catalog)?.setHistory(steps, forImageID: id)
    }

    // MARK: - Navigation

    /// Moves the selection by `offset`, clamped to the list. Returns the
    /// newly selected image, or nil if nothing changed.
    @discardableResult
    public func moveSelection(by offset: Int) -> ImageRecord? {
        let list = visibleImages
        guard !list.isEmpty else { return nil }
        let current = selectedIndex ?? (offset > 0 ? -1 : list.count)
        let target = min(max(current + offset, 0), list.count - 1)
        guard target != selectedIndex else { return nil }
        selectedImageID = list[target].id
        selectedImageIDs = [list[target].id!]
        return list[target]
    }

    public func selectNext() -> ImageRecord? { moveSelection(by: 1) }
    public func selectPrevious() -> ImageRecord? { moveSelection(by: -1) }
}
