import Foundation

/// Each sort key's direction, remembered as Finder remembers a column's,
/// and the choice kept between launches.
///
/// One direction for every key made Rating open on the unrated images
/// after an ascending sort by name, and left File name running Z to A after
/// the newest-first capture time. Now a key comes back the way it was last
/// left, or in its natural direction the first time.
public struct LibrarySortMemory: Equatable, Sendable {
    /// Directions of the keys that aren't showing, by key.
    public private(set) var ascendingByKey: [LibrarySortKey: Bool] = [:]

    public init() {}

    /// Where a key starts: newest first for the dates and most stars first
    /// for rating, as a shoot is reviewed; A to Z and the user's own
    /// arrangement front to back.
    public static func naturalAscending(_ key: LibrarySortKey) -> Bool {
        switch key {
        case .captureTime, .modified, .rating: false
        case .fileName, .custom: true
        }
    }

    public func ascending(for key: LibrarySortKey) -> Bool {
        ascendingByKey[key] ?? Self.naturalAscending(key)
    }

    /// The sort after choosing `key`: the current key's direction is
    /// remembered and the new key's comes back. Choosing the key already
    /// showing changes nothing.
    public mutating func switching(from current: LibrarySort, to key: LibrarySortKey) -> LibrarySort {
        guard key != current.key else { return current }
        ascendingByKey[current.key] = current.ascending
        return LibrarySort(key: key, ascending: ascending(for: key))
    }

    // MARK: - Persistence

    /// The shown sort and every remembered direction as a property-list
    /// dictionary, for UserDefaults: `["key": "rating", "ascending":
    /// ["rating": false, "fileName": true]]`. The shown key's own direction
    /// is in the same map.
    public func stored(showing sort: LibrarySort) -> [String: Any] {
        var directions = Dictionary(uniqueKeysWithValues: ascendingByKey.map { ($0.key.rawValue, $0.value) })
        directions[sort.key.rawValue] = sort.ascending
        return ["key": sort.key.rawValue, "ascending": directions]
    }

    /// What `stored` wrote. Unknown keys (from a later version) and values
    /// of the wrong type are ignored; nothing usable gives the default sort.
    public static func restore(_ stored: [String: Any]?) -> (sort: LibrarySort, memory: LibrarySortMemory) {
        var memory = LibrarySortMemory()
        for (raw, value) in stored?["ascending"] as? [String: Bool] ?? [:] {
            if let key = LibrarySortKey(rawValue: raw) { memory.ascendingByKey[key] = value }
        }
        guard let raw = stored?["key"] as? String, let key = LibrarySortKey(rawValue: raw) else {
            return (.default, memory)
        }
        let sort = LibrarySort(key: key, ascending: memory.ascending(for: key))
        memory.ascendingByKey[key] = nil
        return (sort, memory)
    }
}
