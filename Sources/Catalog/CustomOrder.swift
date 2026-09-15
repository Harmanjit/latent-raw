import Foundation

/// The Custom sort: an arrangement the user makes by dragging thumbnails.
///
/// Stored as a list of catalog-relative paths in `_latent/custom-order.json`,
/// one file per catalog, rather than in `catalog.sqlite`. The database is a
/// cache that can be set aside and rebuilt from the sidecars (DESIGN.md
/// §5.3); an order kept only there would be lost with it, as the subfolder
/// choices are. Nor does it go into each image's XMP: a drag moves the
/// positions of every image after the drop point, and rewriting hundreds of
/// sidecars (and re-reading them on the next reconcile) for one gesture is
/// the opposite of cheap. One small file, written atomically once per drop,
/// survives a rebuild and travels with the folder.
///
/// Paths rather than image ids, because ids restart when a catalog is
/// rebuilt; paths are what the sidecars key on too. Images in included
/// subfolders sit in the same arrangement as the root's.
public enum CustomOrder {
    public static let fileName = "custom-order.json"

    /// The position of each placed path, for sorting. A path listed twice
    /// keeps its first place.
    public static func positions(_ order: [String]) -> [String: Int] {
        var position: [String: Int] = [:]
        position.reserveCapacity(order.count)
        for (index, path) in order.enumerated() where position[path] == nil { position[path] = index }
        return position
    }

    /// `records` in the arrangement: the ones `order` lists, in its order,
    /// then every image it doesn't list yet (new files) by name, as the
    /// File name sort orders them. Descending shows the whole arrangement
    /// back to front.
    public static func arranged(_ records: [ImageRecord], positions: [String: Int], ascending: Bool) -> [ImageRecord] {
        let result = records.sorted { a, b in
            switch (positions[a.relPath], positions[b.relPath]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return byName(a, b)
            }
        }
        return ascending ? result : result.reversed()
    }

    /// A to Z as Finder sorts names ("2" before "10"), path for ties.
    static func byName(_ a: ImageRecord, _ b: ImageRecord) -> Bool {
        let c = a.fileName.localizedStandardCompare(b.fileName)
        return c == .orderedSame ? a.relPath < b.relPath : c == .orderedAscending
    }

    /// `paths` with `moving` taken out and put back, in their current
    /// relative order, just before `target` (at the end for nil). A target
    /// that is itself moving stands for the first path after it that
    /// stays, so dropping a group onto its own gap leaves it where it was.
    public static func reordered(_ paths: [String], moving: [String], before target: String?) -> [String] {
        let movingSet = Set(moving)
        let moved = paths.filter(movingSet.contains)
        var rest = paths.filter { !movingSet.contains($0) }
        var insertAt = rest.count
        if let target, let start = paths.firstIndex(of: target),
           let staying = paths[start...].first(where: { !movingSet.contains($0) }),
           let index = rest.firstIndex(of: staying) {
            insertAt = index
        }
        rest.insert(contentsOf: moved, at: insertAt)
        return rest
    }

    /// The arrangement after the images at `moving` are dropped before
    /// `target` in the grid, as a full list of every image's path.
    ///
    /// `all` is every image in the catalog, not just the ones the filter
    /// shows: images the filter hides keep their places relative to the
    /// rest. In a descending view "before" on screen is after in the
    /// arrangement, so the move is made in the order the user sees and
    /// turned back. The result places every image, new files included, so
    /// the arrangement no longer shifts when another file arrives.
    public static func afterMove(all: [ImageRecord], order: [String], ascending: Bool,
                                 moving: [String], before target: String?) -> [String] {
        let seen = arranged(all, positions: positions(order), ascending: ascending).map(\.relPath)
        let moved = reordered(seen, moving: moving, before: target)
        return ascending ? moved : moved.reversed()
    }

    /// The arrangement after files are renamed or moved within the catalog:
    /// each new path takes its old path's place. Nil when no listed path
    /// changed, so nothing needs writing.
    public static func renamed(_ order: [String], _ renames: [(from: String, to: String)]) -> [String]? {
        let map = Dictionary(renames.filter { $0.from != $0.to }.map { ($0.from, $0.to) },
                             uniquingKeysWith: { first, _ in first })
        guard !map.isEmpty, order.contains(where: { map[$0] != nil }) else { return nil }
        let newPaths = Set(map.values)
        // A new path already listed elsewhere (a file replaced by the
        // renamed one) gives up that place to the renamed file.
        return order.compactMap { path in
            if let to = map[path] { return to }
            return newPaths.contains(path) ? nil : path
        }
    }

    // MARK: - File

    struct Stored: Codable {
        var version = 1
        var relPaths: [String]
    }

    static func read(from url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Stored.self, from: data).relPaths
    }

    /// Written to a temporary file and renamed over the old one, so a crash
    /// leaves either the previous arrangement or the new one. An empty
    /// order removes the file.
    static func write(_ order: [String], to url: URL) throws {
        if order.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(Stored(relPaths: order)).write(to: url, options: .atomic)
    }
}

extension Catalog {
    public var customOrderURL: URL { containerPath.appendingPathComponent(CustomOrder.fileName) }

    /// The saved arrangement, or empty when the user has never made one.
    /// An unreadable file reads as empty rather than failing the open: the
    /// grid falls back to name order, and the next drag writes a good file.
    public func customOrder() -> [String] {
        do {
            return try CustomOrder.read(from: customOrderURL)
        } catch {
            Self.logger.error("Custom order unreadable: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    public func setCustomOrder(_ order: [String]) throws {
        try CustomOrder.write(order, to: customOrderURL)
    }

    /// Moves renamed paths to their new names in the saved arrangement.
    /// Whatever renames or moves a file within the catalog calls this
    /// (reconcile does for renames it detects).
    public func renameInCustomOrder(_ renames: [(from: String, to: String)]) throws {
        guard !renames.isEmpty, let next = CustomOrder.renamed(try CustomOrder.read(from: customOrderURL), renames)
        else { return }
        try setCustomOrder(next)
    }
}
