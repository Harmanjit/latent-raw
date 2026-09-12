import Foundation
import Combine
import CoreGraphics

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
    @Published public private(set) var images: [ImageRecord] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var statusText = "No folder open"
    @Published public private(set) var thumbnailsDone = 0
    @Published public private(set) var thumbnailsTotal = 0
    /// Subfolders rawhead found but has no decision for (DESIGN.md §5.2).
    @Published public private(set) var undecidedSubfolders: [String] = []
    /// Bumped whenever thumbnails land, so a grid knows to refresh cells.
    @Published public private(set) var thumbnailVersion = 0
    @Published public var selectedImageID: Int64? {
        didSet { if selectedImageID != oldValue { Task { await reloadSelectedKeywords() } } }
    }

    public private(set) var catalog: Catalog?

    private let thumbnailCache = NSCache<NSNumber, CGImage>()
    private var thumbnailTask: Task<Void, Never>?

    public init() {
        thumbnailCache.countLimit = 2000
    }

    public var selectedImage: ImageRecord? {
        images.first { $0.id == selectedImageID }
    }

    public var selectedIndex: Int? {
        images.firstIndex { $0.id == selectedImageID }
    }

    public func fileURL(for record: ImageRecord) -> URL? {
        folderURL?.appendingPathComponent(record.relPath)
    }

    // MARK: - Opening

    /// Opens (or creates) the catalog in `folder`, reconciles, shows the
    /// images, then generates thumbnails in the background.
    public func open(folder: URL) async throws {
        thumbnailTask?.cancel()
        isBusy = true
        statusText = "Opening \(folder.lastPathComponent)…"
        defer { isBusy = false }

        let catalog = try Catalog.open(at: folder)
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
        if let selected = selectedImageID, !images.contains(where: { $0.id == selected }) {
            selectedImageID = nil
        }
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
                let report = try await catalog.generateMissingThumbnails { done, total in
                    Task { @MainActor in
                        self?.thumbnailsDone = done
                        self?.thumbnailsTotal = total
                        // Refresh the grid every few, and at the end, rather
                        // than per file — cells reload cheaply but not for free.
                        if done % 8 == 0 || done == total { self?.thumbnailVersion += 1 }
                    }
                }
                await MainActor.run {
                    if let self, !report.failures.isEmpty {
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
        selectedKeywords = (try? await catalog.keywords(forImageID: id)) ?? []
    }

    /// Runs a catalog change for the selected image, then refreshes that
    /// one row locally so the UI updates without a full reload.
    private func changeSelected(_ change: @Sendable (Catalog, Int64) async throws -> Void) async throws {
        guard let id = selectedImageID, let catalog else { return }
        try await change(catalog, id)
        if let index = images.firstIndex(where: { $0.id == id }),
           let fresh = try await catalog.image(forRelPath: images[index].relPath) {
            images[index] = fresh
        }
        await reloadSelectedKeywords()
    }

    public func setRating(_ rating: Int) async throws {
        try await changeSelected { try await $0.setRating(rating, forImageID: $1) }
    }

    public func setFlag(_ flag: ImageFlag) async throws {
        try await changeSelected { try await $0.setFlag(flag, forImageID: $1) }
    }

    public func setKeywords(_ keywords: [String]) async throws {
        try await changeSelected { try await $0.setKeywords(keywords, forImageID: $1) }
    }

    /// Adds quarter turns clockwise (negative for counter-clockwise).
    public func rotateSelected(by quarterTurns: Int) async throws {
        guard let current = selectedImage else { return }
        let next = current.userRotation + quarterTurns
        try await changeSelected { try await $0.setUserRotation(next, forImageID: $1) }
    }

    // MARK: - Navigation

    /// Moves the selection by `offset`, clamped to the list. Returns the
    /// newly selected image, or nil if nothing changed.
    @discardableResult
    public func moveSelection(by offset: Int) -> ImageRecord? {
        guard !images.isEmpty else { return nil }
        let current = selectedIndex ?? (offset > 0 ? -1 : images.count)
        let target = min(max(current + offset, 0), images.count - 1)
        guard target != selectedIndex else { return nil }
        selectedImageID = images[target].id
        return images[target]
    }

    public func selectNext() -> ImageRecord? { moveSelection(by: 1) }
    public func selectPrevious() -> ImageRecord? { moveSelection(by: -1) }
}
