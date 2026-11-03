import Foundation

/// What the grid shows. Empty/zero fields mean "don't filter on this", so
/// the default value shows everything. Modelled on Lightroom's filter bar
/// and darktable's collect module: rating threshold, flag set, a few
/// attribute pickers and a text search, all combined with AND.
public struct LibraryFilter: Equatable, Sendable {
    /// Show images rated at least this many stars (0 = any).
    public var minRating = 0
    /// Show only these flag states; empty = any.
    public var flags: Set<ImageFlag> = []
    /// Show only images with a stored edit.
    public var editedOnly = false
    public var camera: String?
    public var lens: String?
    public var keyword: String?
    /// Case-insensitive substring of the file name, title or caption.
    public var text = ""
    /// Show only files carrying the Finder tag of this name.
    public var finderTag: String?
    /// Show only images with one of these colour labels (or none, or a
    /// custom one); empty = any.
    public var labels: Set<LabelFilterChoice> = []
    /// The Recently Added view: only these rows, the photos the last scan
    /// that found anything new added (`Library.showRecentlyAdded`). Nil
    /// shows every photo.
    public var recentlyAddedIDs: Set<Int64>?

    public init() {}

    public var isActive: Bool {
        minRating > 0 || !flags.isEmpty || editedOnly || camera != nil
            || lens != nil || keyword != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty
            || finderTag != nil || !labels.isEmpty || recentlyAddedIDs != nil
    }

    /// Whether `record` passes every active criterion. Keywords and the
    /// edited flag live outside the record, so the caller supplies them.
    public func matches(_ record: ImageRecord, isEdited: Bool, keywords: Set<String>) -> Bool {
        if let recentlyAddedIDs, !(record.id.map(recentlyAddedIDs.contains) ?? false) { return false }
        if record.rating < minRating { return false }
        if !flags.isEmpty, !flags.contains(ImageFlag(rawValue: record.flag) ?? .none) { return false }
        if editedOnly, !isEdited { return false }
        if let camera, record.camera != camera { return false }
        if let lens, record.lens != lens { return false }
        // A keyword finds the photos tagged with any keyword inside it too.
        if let keyword, !keywords.contains(where: { KeywordPath.path($0, isWithin: keyword) }) { return false }
        if let finderTag, !FinderTag.stored(record.finderTags, contains: finderTag) { return false }
        if !labels.isEmpty, !labels.contains(where: { $0.matches(record.label) }) { return false }
        let needle = text.trimmingCharacters(in: .whitespaces)
        // The name, or the title or caption the photographer gave it.
        if !needle.isEmpty, ![record.fileName, record.title ?? "", record.caption ?? ""]
            .contains(where: { $0.range(of: needle, options: .caseInsensitive) != nil }) {
            return false
        }
        return true
    }
}

public enum LibrarySortKey: String, CaseIterable, Sendable {
    case captureTime, fileName, rating, modified
    /// The arrangement the user makes by dragging (see `CustomOrder`).
    case custom

    public var title: String {
        switch self {
        case .captureTime: "Capture time"
        case .fileName: "File name"
        case .rating: "Rating"
        case .modified: "Modified"
        case .custom: "Custom"
        }
    }
}

public struct LibrarySort: Equatable, Sendable {
    public var key: LibrarySortKey
    public var ascending: Bool

    public init(key: LibrarySortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// Newest first, the way a shoot is reviewed.
    public static let `default` = LibrarySort(key: .captureTime, ascending: false)
}

public extension Array where Element == ImageRecord {
    /// Stable sort by the chosen key, with the path as the tie-breaker so
    /// two frames shot in the same second keep a fixed order. Images with
    /// no value for the key (no capture time, unrated) sort last either
    /// way, so they never crowd the top of a descending list.
    ///
    /// `customPositions` is the saved arrangement for the Custom key
    /// (`CustomOrder.positions`); other keys ignore it.
    func sorted(by sort: LibrarySort, customPositions: [String: Int] = [:]) -> [ImageRecord] {
        if sort.key == .custom {
            return CustomOrder.arranged(self, positions: customPositions, ascending: sort.ascending)
        }
        let sorted = self.sorted { a, b in
            switch sort.key {
            case .captureTime:
                return orderOptional(a.captureTime, b.captureTime, a, b, ascending: sort.ascending)
            case .rating:
                return orderOptional(a.rating > 0 ? a.rating : nil, b.rating > 0 ? b.rating : nil,
                                     a, b, ascending: sort.ascending)
            case .modified:
                return orderOptional(a.mtime, b.mtime, a, b, ascending: sort.ascending)
            case .fileName:
                // By the file's own name, so a virtual copy (its path is the
                // master's with a suffix) falls just after its master.
                let c = a.sourceFileName.localizedStandardCompare(b.sourceFileName)
                if c == .orderedSame { return a.relPath < b.relPath }
                return sort.ascending ? c == .orderedAscending : c == .orderedDescending
            case .custom:
                return false   // handled above
            }
        }
        return sorted
    }
}

/// Orders two optional keys with nil last, then by path for stability.
private func orderOptional<T: Comparable>(_ x: T?, _ y: T?, _ a: ImageRecord, _ b: ImageRecord,
                                          ascending: Bool) -> Bool {
    switch (x, y) {
    case (nil, nil): return a.relPath < b.relPath
    case (nil, _): return false
    case (_, nil): return true
    case let (x?, y?):
        if x == y { return a.relPath < b.relPath }
        return ascending ? x < y : x > y
    }
}
