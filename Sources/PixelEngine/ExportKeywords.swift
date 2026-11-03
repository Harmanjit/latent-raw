import Foundation

extension ExportMetadata {
    /// The keywords as an exported file carries them. The catalog keeps a
    /// hierarchical keyword as its whole path ("Places|France|Paris", see
    /// Catalog's KeywordPath); IPTC keywords are flat, so each level is
    /// written as a keyword of its own, as Lightroom exports the levels
    /// above a keyword. Repeats are kept once, in order.
    static func flattenedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            for level in keyword.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !level.isEmpty && seen.insert(level).inserted {
                result.append(level)
            }
        }
        return result
    }
}
