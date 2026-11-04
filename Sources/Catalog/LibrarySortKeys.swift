import Foundation

extension Array where Element == ImageRecord {
    /// `sorted(by:)` for the built-in keys, by position rather than by record.
    ///
    /// Sorting the records themselves moved every record (some thirty
    /// fields, a dozen of them strings) at each step, and the file-name
    /// order worked out both names afresh at every comparison: about 1.4
    /// million name extractions for a 20,000-image folder. This reads each
    /// key once, sorts positions, then gathers the records. The order is
    /// exactly the same, keys first and then the path, which is unique.
    ///
    /// Nil for a key it doesn't handle; the caller sorts those itself.
    func keyedSorted(by sort: LibrarySort) -> [ImageRecord]? {
        if sort.key == .captureTime {
            return sortedByPosition(map(\.captureTime), ascending: sort.ascending)
        }
        if sort.key == .modified {
            return sortedByPosition(map { Optional($0.mtime) }, ascending: sort.ascending)
        }
        if sort.key == .rating {
            return sortedByPosition(map { $0.rating > 0 ? $0.rating : nil }, ascending: sort.ascending)
        }
        if sort.key == .fileName {
            let names = map(\.sourceFileName)
            let paths = map(\.relPath)
            let ascending = sort.ascending
            let order = Array<Int>(indices).sorted { i, j in
                let c = names[i].localizedStandardCompare(names[j])
                if c == .orderedSame { return paths[i] < paths[j] }
                return ascending ? c == .orderedAscending : c == .orderedDescending
            }
            return order.map { self[$0] }
        }
        return nil
    }

    /// Nil keys last either way, equal keys by path (as `orderOptional`).
    private func sortedByPosition<T: Comparable>(_ keys: [T?], ascending: Bool) -> [ImageRecord] {
        let paths = map(\.relPath)
        let order = Array<Int>(indices).sorted { i, j in
            switch (keys[i], keys[j]) {
            case (nil, nil): return paths[i] < paths[j]
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if x == y { return paths[i] < paths[j] }
                return ascending ? x < y : x > y
            }
        }
        return order.map { self[$0] }
    }
}
