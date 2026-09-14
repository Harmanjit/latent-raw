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
        didSet { recomputeVisible() }
    }
    /// The grid's contents: `images` after `filter` and `sort`.
    @Published public private(set) var visibleImages: [ImageRecord] = []
    @Published public var filter = LibraryFilter() {
        didSet { if filter != oldValue { recomputeVisible() } }
    }
    @Published public var sort = LibrarySort.default {
        didSet { if sort != oldValue { recomputeVisible() } }
    }
    /// image id → keywords, for filtering; refreshed with the image list
    /// and whenever keywords are edited.
    private var keywordIndex: [Int64: Set<String>] = [:] {
        didSet { recomputeVisible() }
    }
    @Published public private(set) var isBusy = false
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
    @Published public private(set) var editedImageIDs: Set<Int64> = [] {
        didSet { if filter.editedOnly { recomputeVisible() } }
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

    /// Sets both selections from the grid.
    public func setSelection(_ ids: Set<Int64>, primary: Int64?) {
        selectedImageIDs = ids
        selectedImageID = primary ?? ids.first.flatMap { id in images.first { $0.id == id }?.id }
    }

    public private(set) var catalog: Catalog?

    private let thumbnailCache = NSCache<NSNumber, CGImage>()

    /// Renders thumbnails for edited images. Set by the app (it needs the
    /// GPU pipeline, which the catalog doesn't know about).
    public var thumbnailRenderer: (any EditedThumbnailRenderer)?
    private var thumbnailTask: Task<Void, Never>?

    public init() {
        thumbnailCache.countLimit = 2000
    }

    public var selectedImage: ImageRecord? {
        images.first { $0.id == selectedImageID }
    }

    /// Runs a catalog operation and, if it fails, records what and why
    /// instead of dropping the error. Every UI action that writes to the
    /// catalog goes through here, so a read-only or full volume shows
    /// up in the status bar rather than as a rating that didn't stick.
    public func perform(_ what: String, _ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                lastError = "\(what) failed: \(error)"
                Self.logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            }
        }
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
        let next = passing.sorted(by: sort)
        if next != visibleImages { visibleImages = next }
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

    public func fileURL(for record: ImageRecord) -> URL? {
        folderURL?.appendingPathComponent(record.relPath)
    }

    // MARK: - Opening

    /// Opens (or creates) the catalog in `folder`, reconciles, shows the
    /// images, then generates thumbnails in the background.
    public func open(folder: URL, defaultSubfolderMode: SubfolderMode? = nil) async throws {
        thumbnailTask?.cancel()
        isBusy = true
        statusText = "Opening \(folder.lastPathComponent)…"
        defer { isBusy = false }

        let catalog = try Catalog.open(at: folder)
        // A catalog that has never recorded a subfolder policy takes the
        // app's default; one that has keeps its own.
        if let mode = defaultSubfolderMode, try await catalog.setting(Catalog.defaultSubfolderModeKey) == nil {
            try await catalog.setDefaultSubfolderMode(mode)
        }
        self.catalog = catalog
        self.folderURL = await catalog.rootPath
        thumbnailCache.removeAllObjects()
        selectedImageID = nil

        try await refresh()
    }

    /// Re-reconciles the open folder (the Refresh action, DESIGN.md §5.3
    /// "no live watching").
    public func refresh() async throws {
        guard let catalog else { return }
        isBusy = true
        defer { isBusy = false }

        let report = try await catalog.reconcile()
        undecidedSubfolders = report.undecidedSubfolders
        images = try await catalog.allImages()
        editedImageIDs = try await catalog.editedImageIDs()
        keywordIndex = try await catalog.allImageKeywords()
        if let selected = selectedImageID, !images.contains(where: { $0.id == selected }) {
            selectedImageID = nil
        }
        selectedImageIDs = selectedImageIDs.filter { id in images.contains { $0.id == id } }
        statusText = "\(images.count) images · \(report)"

        startThumbnailGeneration()
    }

    /// Records a decision for every undecided subfolder and rescans.
    public func decideUndecidedSubfolders(include: Bool) async throws {
        guard let catalog else { return }
        for relPath in undecidedSubfolders {
            try await catalog.setSubfolderMode(include ? .included : .independent, forRelPath: relPath)
        }
        undecidedSubfolders = []
        try await refresh()
    }

    // MARK: - Thumbnails

    private func startThumbnailGeneration() {
        guard let catalog else { return }
        thumbnailTask?.cancel()
        thumbnailsDone = 0
        thumbnailsTotal = 0
        thumbnailTask = Task { [weak self] in
            do {
                let needed = try await catalog.imagesNeedingThumbnails().count
                await MainActor.run { self?.thumbnailsTotal = needed }
                guard needed > 0 else { return }
                let renderer = await self?.thumbnailRenderer
                let report = try await catalog.generateMissingThumbnails(
                    editedRenderer: renderer
                ) { done, total in
                    Task { @MainActor in
                        self?.thumbnailsDone = done
                        self?.thumbnailsTotal = total
                        // Refresh the grid every few, and at the end, rather
                        // than per file — cells reload cheaply but not for free.
                        if done % 8 == 0 || done == total { self?.thumbnailVersion += 1 }
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    // Regenerated files replace what the cache holds.
                    for relPath in report.regeneratedRelPaths {
                        if let id = self.images.first(where: { $0.relPath == relPath })?.id {
                            self.thumbnailCache.removeObject(forKey: NSNumber(value: id))
                        }
                    }
                    if !report.regeneratedRelPaths.isEmpty { self.thumbnailVersion += 1 }
                    if !report.failures.isEmpty {
                        self.statusText += " · \(report.failures.count) thumbnails failed"
                    }
                }
            } catch {
                await MainActor.run { self?.statusText = "Thumbnails failed: \(error)" }
            }
        }
    }

    /// The cached thumbnail, if it's been loaded. Cells call this first;
    /// on a miss they call `loadThumbnail` and update when it returns.
    public func cachedThumbnail(for record: ImageRecord) -> CGImage? {
        guard let id = record.id else { return nil }
        return thumbnailCache.object(forKey: NSNumber(value: id))
    }

    /// Decodes the thumbnail file on a utility task and caches it. Returns
    /// nil when the file doesn't exist yet (generation still running).
    public func loadThumbnail(for record: ImageRecord) async -> CGImage? {
        guard let id = record.id, let catalog else { return nil }
        if let cached = thumbnailCache.object(forKey: NSNumber(value: id)) { return cached }
        let url = await catalog.thumbnailURL(forRelPath: record.relPath)
        let loaded = await Task.detached(priority: .utility) { () -> ThumbnailImage? in
            Thumbnailer.load(from: url).map(ThumbnailImage.init)
        }.value
        guard let image = loaded?.cgImage else { return nil }
        thumbnailCache.setObject(image, forKey: NSNumber(value: id))
        return image
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
    private var metadataTargets: [ImageRecord] {
        guard let primary = selectedImage else { return [] }
        guard let primaryID = primary.id, selectedImageIDs.contains(primaryID) else { return [primary] }
        return selectedImages
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
    private func change(_ records: [ImageRecord],
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
        // the awaits), in one assignment so the visible list is recomputed
        // once rather than per image.
        var updated = images
        for index in updated.indices {
            if let id = updated[index].id, let record = fresh[id] { updated[index] = record }
        }
        images = updated
        await reloadSelectedKeywords()
        if failures.count == 1, records.count == 1 { throw failures[0].error }
        if !failures.isEmpty { throw SelectionChangeError(total: records.count, failures: failures) }
    }

    public func setRating(_ rating: Int) async throws {
        try await change(metadataTargets) { catalog, id, _ in try await catalog.setRating(rating, forImageID: id) }
    }

    public func setFlag(_ flag: ImageFlag) async throws {
        try await change(metadataTargets) { catalog, id, _ in try await catalog.setFlag(flag, forImageID: id) }
    }

    /// Keywords stay primary-only: the keyword field shows the primary's
    /// keywords and this replaces the whole list with them, so applying
    /// it to the selection would wipe every other image's own keywords.
    public func setKeywords(_ keywords: [String]) async throws {
        try await change(selectedImage.map { [$0] } ?? []) { catalog, id, _ in
            try await catalog.setKeywords(keywords, forImageID: id)
        }
        if let id = selectedImageID {
            let cleaned = Set(keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            keywordIndex[id] = cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Adds quarter turns clockwise (negative for counter-clockwise) to
    /// each selected image, each from its own current rotation.
    public func rotateSelected(by quarterTurns: Int) async throws {
        try await change(metadataTargets) { catalog, id, record in
            try await catalog.setUserRotation(record.userRotation + quarterTurns, forImageID: id)
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
    public func saveEditStack(_ json: String?, schemaVersion: Int, processVersion: String,
                              forImageID id: Int64) async throws {
        guard let catalog else { return }
        try await catalog.setEditStack(json, schemaVersion: schemaVersion,
                                       processVersion: processVersion, forImageID: id)
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
    @discardableResult
    public func transformSelectedEdits(schemaVersion: Int, processVersion: String,
                                       _ transform: (String?) throws -> String?) async throws -> TransformOutcome {
        guard let catalog else { return TransformOutcome() }
        var outcome = TransformOutcome()
        for record in selectedImages {
            guard let id = record.id else { continue }
            let existing: String?
            let next: String?
            do {
                existing = try await catalog.editStack(forImageID: id)
                next = try transform(existing)
            } catch {
                outcome.skipped.append(record.fileName)
                Self.logger.error("Skipped \(record.fileName, privacy: .private): \(String(describing: error), privacy: .private)")
                continue
            }
            if next != existing {
                try await catalog.setEditStack(next, schemaVersion: schemaVersion,
                                               processVersion: processVersion, forImageID: id)
                if next == nil { editedImageIDs.remove(id) } else { editedImageIDs.insert(id) }
                outcome.changed += 1
            }
        }
        if outcome.changed > 0 { startThumbnailGeneration() }
        return outcome
    }

    // MARK: - Snapshots and history (per image, stored with the catalog)

    public func snapshots(for record: ImageRecord) async throws -> [(name: String, stackJSON: String)] {
        guard let id = record.id, let catalog else { return [] }
        return try await catalog.snapshots(forImageID: id)
    }

    public func setSnapshots(_ snapshots: [(name: String, stackJSON: String)], forImageID id: Int64) async throws {
        try await catalog?.setSnapshots(snapshots, forImageID: id)
    }

    public func history(for record: ImageRecord) async throws -> [(stackJSON: String, createdAt: Int64)] {
        guard let id = record.id, let catalog else { return [] }
        return try await catalog.history(forImageID: id)
    }

    public func setHistory(_ steps: [(stackJSON: String, createdAt: Int64)], forImageID id: Int64) async throws {
        try await catalog?.setHistory(steps, forImageID: id)
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
