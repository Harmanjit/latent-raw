import Foundation

/// The filter bar's settings remembered per source, for the opt-in
/// "Remember Filter per Source" (filter bar › Filter presets menu).
///
/// A source is an open folder (its catalog) or one collection inside it:
/// `key(folder:collection:)` names it. With the option on, the Library
/// remembers the filter whenever it changes, and coming back to a source
/// brings back what it had there; a source never seen shows everything,
/// so another folder's filter never hides photos it says nothing about.
///
/// Kept in the preferences rather than each catalog (the app saves
/// `encoded()` in UserDefaults), so a read-only folder remembers too and
/// the catalog schema is untouched. Only the most recently used
/// `capacity` sources are kept, and a neutral filter isn't stored at all.
public struct FilterSourceMemory: Equatable, Sendable {
    /// How many sources are kept; the least recently remembered go first.
    public static let capacity = 100

    /// Source key → its filter. The Recently Added view's ids are never
    /// kept: they are a moment's list, not a setting.
    public private(set) var filters: [String: LibraryFilter] = [:]
    /// The keys of `filters`, least recently remembered first.
    public private(set) var order: [String] = []

    public init() {}

    /// The key naming a folder, or one collection in it (nil: the whole
    /// folder). Nil without a folder: there is nothing to remember then.
    /// Collection ids restart in every catalog, so the folder is part of
    /// the key.
    public static func key(folder: URL?, collection: Int64?) -> String? {
        guard let folder else { return nil }
        let path = folder.standardizedFileURL.path
        if let collection { return "\(path)#collection-\(collection)" }
        return "\(path)#folder"
    }

    /// Records `filter` as the one `key` shows. A neutral filter removes
    /// the entry instead, so coming back shows everything, as it would.
    public mutating func remember(_ filter: LibraryFilter, for key: String) {
        var filter = filter
        filter.recentlyAddedIDs = nil
        order.removeAll { $0 == key }
        guard filter != LibraryFilter() else {
            filters[key] = nil
            return
        }
        filters[key] = filter
        order.append(key)
        while order.count > Self.capacity {
            filters[order.removeFirst()] = nil
        }
    }

    /// What `key` showed last, or a neutral filter for a source never seen.
    public func filter(for key: String) -> LibraryFilter {
        filters[key] ?? LibraryFilter()
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var order: [String]
        var filters: [String: LibraryFilter]
    }

    /// The memory as JSON, for UserDefaults.
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Stored(order: order, filters: filters))
    }

    /// What `encoded` wrote; anything unreadable gives an empty memory.
    /// Keys missing from the order, or orders without a filter, are dropped.
    public static func decode(_ data: Data?) -> FilterSourceMemory {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return FilterSourceMemory()
        }
        var memory = FilterSourceMemory()
        for key in stored.order {
            if let filter = stored.filters[key] { memory.remember(filter, for: key) }
        }
        return memory
    }
}
