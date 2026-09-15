import Foundation

/// Help's search: case- and accent-insensitive, as Find is.
public enum HelpSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The query as searched: surrounding spaces don't count, and a query
    /// of only spaces is no search.
    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many times `query` appears in `text`.
    public static func matchCount(of query: String, in text: String) -> Int {
        let query = normalized(query)
        guard !query.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: options, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// Where `query` appears in `text`, for highlighting.
    public static func ranges(of query: String, in text: AttributedString) -> [Range<AttributedString.Index>] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<AttributedString.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text[searchStart...].range(of: query, options: options) {
            ranges.append(found)
            searchStart = found.upperBound
        }
        return ranges
    }
}
