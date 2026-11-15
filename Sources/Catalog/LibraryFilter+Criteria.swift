import Foundation

// The filter bar's newer criteria: rating range, excluded labels, the
// Unedited and No keywords states, the wider search, the shooting-data and
// date ranges, and the file and copy kinds. Each one's neutral value is
// its default, so a LibraryFilter that never touches them filters exactly
// as it did before they existed.

/// How the rating stars are read.
public enum RatingOperator: String, Codable, CaseIterable, Sendable {
    /// `minRating` stars or more: the stars' own meaning, the default.
    case atLeast
    /// Exactly `minRating` stars (0 = unrated).
    case exactly
    /// `maxRating` stars or fewer.
    case atMost
    /// From `minRating` to `maxRating` stars, both included.
    case between

    public var title: String {
        switch self {
        case .atLeast: "At least"
        case .exactly: "Exactly"
        case .atMost: "At most"
        case .between: "Between"
        }
    }
}

/// Where the filter bar's search box looks.
public enum TextSearchScope: String, Codable, CaseIterable, Sendable {
    /// File name, title or caption, the whole text as one piece: the
    /// search box as it always was.
    case names
    /// Every searchable field (name, path, title, caption, creator,
    /// copyright, camera, lens, keywords), with search syntax: words are
    /// all required, "quoted phrases" match as one, -word excludes.
    case everything

    public var title: String {
        switch self {
        case .names: "File Name, Title and Caption"
        case .everything: "All Searchable Fields"
        }
    }
}

/// The filter bar's File kind choice.
public enum FileKindFilter: String, Codable, CaseIterable, Sendable {
    case any, raw, notRaw, rawJPEGPair

    public var title: String {
        switch self {
        case .any: "Any File"
        case .raw: "Raw"
        case .notRaw: "Not Raw"
        case .rawJPEGPair: "RAW+JPEG Pair"
        }
    }

    /// Raw by the File type sort's own grouping (LibrarySortOrders):
    /// every camera raw, and DNG.
    public static func isRaw(_ record: ImageRecord) -> Bool {
        let type = LibrarySortKey.fileType(of: record)
        return type == "Raw" || type == "DNG"
    }
}

/// The filter bar's Kind choice, over virtual copies.
public enum CopyKindFilter: String, Codable, CaseIterable, Sendable {
    case any, masters, virtualCopies, hasVirtualCopies

    public var title: String {
        switch self {
        case .any: "Any Photo"
        case .masters: "Masters"
        case .virtualCopies: "Virtual Copies"
        case .hasVirtualCopies: "Has Virtual Copies"
        }
    }
}

/// The search box's text in the All Searchable Fields scope, parsed once
/// per filter change: words, "quoted phrases", and -excluded terms, all
/// lowercased.
public struct SearchQuery: Equatable, Sendable {
    public var included: [String] = []
    public var excluded: [String] = []

    public init(_ text: String) {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var negated = false
            if chars[i] == "-", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                negated = true
                i += 1
            }
            var term = ""
            if chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { term.append(chars[i]); i += 1 }
                i += 1   // past the closing quote, or the end
            } else {
                while i < chars.count, !chars[i].isWhitespace { term.append(chars[i]); i += 1 }
            }
            let cleaned = term.trimmingCharacters(in: .whitespaces).lowercased()
            // A lone "-" is not a term.
            guard !cleaned.isEmpty, cleaned != "-" else { continue }
            if negated { excluded.append(cleaned) } else { included.append(cleaned) }
        }
    }

    public var isEmpty: Bool { included.isEmpty && excluded.isEmpty }

    /// Whether a lowercased haystack (`LibraryFilter.searchHaystack`) has
    /// every included term and none of the excluded ones.
    public func matches(_ haystack: String) -> Bool {
        for term in included where !haystack.contains(term) { return false }
        for term in excluded where haystack.contains(term) { return false }
        return true
    }
}

/// What the newer criteria need from outside a record, worked out once per
/// pass over the list rather than per record.
public struct LibraryFilterContext: Sendable {
    /// The parsed search, for the All Searchable Fields scope.
    public var searchQuery: SearchQuery?
    /// Paths of masters that have at least one virtual copy.
    public var mastersWithCopies: Set<String> = []
    /// Ids of the raws of RAW+JPEG pairs and of their JPEGs.
    public var pairedIDs: Set<Int64> = []
    /// Every photo's search text by id (`LibraryFilter.searchHaystack`),
    /// when the caller keeps them (`Library.searchHaystacks`); a photo not
    /// in it has its text worked out as before.
    public var haystacks: [Int64: String]?
    /// The search box's text trimmed, for the File Name, Title and Caption
    /// scope: trimmed once per pass rather than once per photo.
    public var needle: String?

    public init(searchQuery: SearchQuery? = nil, mastersWithCopies: Set<String> = [], pairedIDs: Set<Int64> = []) {
        self.searchQuery = searchQuery
        self.mastersWithCopies = mastersWithCopies
        self.pairedIDs = pairedIDs
    }

    public static let empty = LibraryFilterContext()

    /// The context `filter` needs over `images`, given the RAW+JPEG pairs
    /// (raw id → its JPEGs). Only what the filter reads is worked out.
    public init(filter: LibraryFilter, images: [ImageRecord], pairedCompanions: [Int64: [ImageRecord]]) {
        if filter.textScope == .everything {
            searchQuery = SearchQuery(filter.text)
        } else {
            needle = filter.text.isEmpty ? "" : filter.text.trimmingCharacters(in: .whitespaces)
        }
        if filter.copyKind == .hasVirtualCopies {
            mastersWithCopies = Set(images.lazy.compactMap { VirtualCopy.parse($0.relPath)?.masterRelPath })
        }
        if filter.fileKind == .rawJPEGPair {
            var ids = Set(pairedCompanions.keys)
            for companions in pairedCompanions.values { ids.formUnion(companions.compactMap(\.id)) }
            pairedIDs = ids
        }
    }
}

extension LibraryFilter {
    /// Any of the newer criteria is set.
    public var hasAddedCriteria: Bool {
        ratingOperator != .atLeast && ratingIsConstrained
            || !excludedLabels.isEmpty || uneditedOnly || noKeywords
            || isoRange != nil || focalRange != nil || apertureRange != nil || shutterRange != nil
            || captureDateRange != nil || fileKind != .any || copyKind != .any
    }

    /// Whether the rating range, read by its operator, hides anything.
    public var ratingIsConstrained: Bool {
        switch ratingOperator {
        case .atLeast: minRating > 0
        case .exactly: true
        case .atMost: maxRating < 5
        case .between: minRating > 0 || maxRating < 5
        }
    }

    /// Whether `rating` passes the rating range under the operator.
    public func ratingPasses(_ rating: Int) -> Bool {
        let stars = min(max(rating, 0), 5)
        switch ratingOperator {
        case .atLeast: return rating >= minRating
        case .exactly: return stars == minRating
        case .atMost: return stars <= maxRating
        case .between: return stars >= min(minRating, maxRating) && stars <= max(minRating, maxRating)
        }
    }

    /// The filter reads the edited badge, which lives outside the record.
    public var readsEdits: Bool { editedOnly || uneditedOnly }

    /// The filter reads keywords, which live outside the record.
    public var readsKeywords: Bool {
        keyword != nil || noKeywords
            || (textScope == .everything && !text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Every searchable field of a record in one lowercased string, fields
    /// apart on lines of their own so a phrase can't span two of them.
    public static func searchHaystack(_ record: ImageRecord, keywords: Set<String>) -> String {
        var parts = [record.fileName, record.relPath]
        for field in [record.title, record.caption, record.creator, record.copyright, record.camera, record.lens] {
            if let field, !field.isEmpty { parts.append(field) }
        }
        for keyword in keywords {
            parts.append(keyword.replacingOccurrences(of: String(KeywordPath.separator), with: " "))
        }
        return parts.joined(separator: "\n").lowercased()
    }

    func passesSearch(_ record: ImageRecord, keywords: Set<String>, context: LibraryFilterContext) -> Bool {
        let query = context.searchQuery ?? SearchQuery(text)
        guard !query.isEmpty else { return true }
        if let id = record.id, let haystack = context.haystacks?[id] { return query.matches(haystack) }
        return query.matches(Self.searchHaystack(record, keywords: keywords))
    }

    func passesAddedCriteria(_ record: ImageRecord, isEdited: Bool, keywords: Set<String>,
                             context: LibraryFilterContext) -> Bool {
        if uneditedOnly, isEdited { return false }
        if noKeywords, !keywords.isEmpty { return false }
        if !excludedLabels.isEmpty, excludedLabels.contains(where: { $0.matches(record.label) }) { return false }
        if let isoRange, !(record.iso.map { isoRange.contains(Double($0)) } ?? false) { return false }
        if let focalRange, !(record.focal.map(focalRange.contains) ?? false) { return false }
        if let apertureRange, !(record.aperture.map(apertureRange.contains) ?? false) { return false }
        if let shutterRange, !(record.shutter.map(shutterRange.contains) ?? false) { return false }
        if let captureDateRange {
            guard let time = record.captureTime,
                  captureDateRange.contains(Date(timeIntervalSince1970: TimeInterval(time))) else { return false }
        }
        switch fileKind {
        case .any: break
        case .raw: if !FileKindFilter.isRaw(record) { return false }
        case .notRaw: if FileKindFilter.isRaw(record) { return false }
        case .rawJPEGPair: if !(record.id.map(context.pairedIDs.contains) ?? false) { return false }
        }
        switch copyKind {
        case .any: break
        case .masters: if record.isVirtualCopy { return false }
        case .virtualCopies: if !record.isVirtualCopy { return false }
        case .hasVirtualCopies:
            if record.isVirtualCopy || !context.mastersWithCopies.contains(record.relPath) { return false }
        }
        return true
    }

    /// Whether a record changing from `old` to `new` could change whether it
    /// passes the newer criteria (`dependsOnChange` asks this too).
    func addedCriteriaDependOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
        if ratingOperator != .atLeast, ratingIsConstrained, old.rating != new.rating { return true }
        if !excludedLabels.isEmpty, old.label != new.label { return true }
        if isoRange != nil, old.iso != new.iso { return true }
        if focalRange != nil, old.focal != new.focal { return true }
        if apertureRange != nil, old.aperture != new.aperture { return true }
        if shutterRange != nil, old.shutter != new.shutter { return true }
        if captureDateRange != nil, old.captureTime != new.captureTime { return true }
        if fileKind != .any || copyKind != .any, old.relPath != new.relPath { return true }
        if textScope == .everything, !text.trimmingCharacters(in: .whitespaces).isEmpty,
           old.relPath != new.relPath || old.title != new.title || old.caption != new.caption
            || old.creator != new.creator || old.copyright != new.copyright
            || old.camera != new.camera || old.lens != new.lens {
            return true
        }
        return false
    }
}

extension Library {
    /// The photos the grid starts from before the filter bar: the folder,
    /// or the collection shown. The Ranges popover's histograms and the
    /// Keyword List's No keywords count are drawn from these.
    public var imagesInScope: [ImageRecord] {
        let shown = imagesShownInGrid()
        guard let scope = collections.activeScope else { return shown }
        let edited = editedImageIDs, index = keywordIndex, now = Date()
        return shown.filter { record in
            let isEdited = record.id.map(edited.contains) ?? false
            return scope.includes(record, isEdited: isEdited, keywords: record.id.flatMap { index[$0] } ?? [], now: now)
        }
    }

    /// How many of `records` carry no keyword.
    public func unkeywordedCount(in records: [ImageRecord]) -> Int {
        let index = keywordIndex
        return records.reduce(0) { count, record in
            count + ((record.id.flatMap { index[$0] }?.isEmpty ?? true) ? 1 : 0)
        }
    }
}
