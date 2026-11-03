import Foundation

/// Hierarchical keywords, as Lightroom writes them.
///
/// A keyword is stored as its whole path from the top of the hierarchy,
/// levels joined by a vertical bar: "Places|France|Paris". That is exactly
/// the form of Lightroom's `lr:hierarchicalSubject`, so the sidecar can
/// carry it as is, and a flat keyword is just a path of one level, so every
/// keyword already in a catalog is already a valid path.
///
/// The keywords table keeps the path in `name` rather than splitting it
/// over `parent_id`: every query, the filter index, undo and copying
/// images between folders already deal in keyword names, and a path in
/// one string keeps all of them working unchanged. The hierarchy is worked
/// out from the paths whenever it is shown (`KeywordTree`).
public enum KeywordPath {
    /// Between levels in a stored path.
    public static let separator: Character = "|"

    /// The levels of a path, outermost first.
    public static func components(_ path: String) -> [String] {
        path.split(separator: separator, omittingEmptySubsequences: true).map(String.init)
    }

    /// The innermost level: "Paris" for "Places|France|Paris".
    public static func leaf(_ path: String) -> String {
        components(path).last ?? path
    }

    /// The path one level up, or nil at the top.
    public static func parent(_ path: String) -> String? {
        let parts = components(path)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: String(separator))
    }

    /// Every path above this one, outermost first: "Places", "Places|France".
    public static func ancestors(_ path: String) -> [String] {
        let parts = components(path)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts.prefix($0).joined(separator: String(separator)) }
    }

    public static func isHierarchical(_ path: String) -> Bool {
        components(path).count > 1
    }

    /// Whether an image tagged `path` counts as tagged `filter`: the same
    /// keyword, or one anywhere below it, as Lightroom finds every photo of
    /// Paris when you click France.
    public static func path(_ path: String, isWithin filter: String) -> Bool {
        path == filter || path.hasPrefix(filter + String(separator))
    }

    /// For people: "Places › France › Paris".
    public static func display(_ path: String) -> String {
        components(path).joined(separator: " › ")
    }

    /// As typed in a keyword field: "Places > France > Paris". Parsing it
    /// gives the same path back.
    public static func entryText(_ path: String) -> String {
        components(path).joined(separator: " > ")
    }

    /// Paths from what someone typed: keywords separated by commas, each
    /// either a plain word or levels joined by ">" (Lightroom's way of
    /// typing a hierarchy) or "|". Spaces around levels are dropped, empty
    /// levels and empty keywords ignored, repeats kept once, in order.
    public static func parse(_ entry: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in entry.split(separator: ",") {
            guard let path = normalized(String(item)), seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    /// One keyword as typed or stored, tidied into a path; nil if nothing is left.
    public static func normalized(_ keyword: String) -> String? {
        let parts = keyword.split(whereSeparator: { $0 == ">" || $0 == separator })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: String(separator))
    }

    // MARK: Sidecars

    /// What goes in dc:subject for these keywords: every level of every
    /// path, once each, sorted. Other applications read only dc:subject, and
    /// expect "France" and "Places" there for a photo tagged Paris, as
    /// Lightroom writes them.
    public static func flatSubjects(_ paths: [String]) -> [String] {
        var names = Set<String>()
        for path in paths { names.formUnion(components(path)) }
        return names.sorted()
    }

    /// The keywords a sidecar holds. Its hierarchical list, when it has one,
    /// is the truth; a dc:subject entry that is not a level of any of those
    /// paths was added by an application that writes dc:subject only, and
    /// is kept as a keyword of its own. With no hierarchical list the
    /// subjects are the keywords, as before.
    public static func merge(subjects: [String], hierarchical: [String]) -> [String] {
        let paths = hierarchical.compactMap(normalized)
        guard !paths.isEmpty else { return subjects }
        var covered = Set<String>()
        for path in paths { covered.formUnion(components(path)) }
        var seen = Set<String>()
        var result: [String] = []
        for keyword in paths + subjects.filter({ !covered.contains($0) }) where seen.insert(keyword).inserted {
            result.append(keyword)
        }
        return result
    }

    // MARK: Completion

    /// Existing keywords that complete `typed`, best first: those whose
    /// innermost level starts with it, then those with any level starting
    /// with it, then any containing it; alphabetical within each. Case and
    /// accents are ignored. A path typed with ">" matches on its whole path.
    public static func suggestions(for typed: String, in available: [String], limit: Int = 8) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let wantsPath = needle.contains(">") || needle.contains(separator)
        let target = wantsPath ? (normalized(needle) ?? needle) : needle
        var ranked: [(rank: Int, path: String)] = []
        for path in available {
            let rank: Int?
            if wantsPath {
                rank = path.range(of: target, options: options.union(.anchored)) != nil ? 0
                    : path.range(of: target, options: options) != nil ? 2 : nil
            } else if leaf(path).range(of: needle, options: options.union(.anchored)) != nil {
                rank = 0
            } else if components(path).contains(where: { $0.range(of: needle, options: options.union(.anchored)) != nil }) {
                rank = 1
            } else if path.range(of: needle, options: options) != nil {
                rank = 2
            } else {
                rank = nil
            }
            if let rank { ranked.append((rank, path)) }
        }
        return ranked.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank
                : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.prefix(limit).map(\.path)
    }

    /// The text of a keyword field with its last, half-typed keyword
    /// replaced by `path`, ready for the next: "sky, Pla" becomes
    /// "sky, Places > France > Paris, ".
    public static func completing(_ text: String, with path: String) -> String {
        var items = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if items.isEmpty { items = [""] }
        items[items.count - 1] = entryText(path)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: ", ") + ", "
    }

    /// The keyword being typed: what follows the last comma.
    public static func lastToken(_ text: String) -> String {
        let last = text.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return last.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Renaming

    /// `path` after the keyword at `old` (and so everything under it) is
    /// renamed or moved to `new`; unchanged when it is not within `old`.
    public static func replacing(_ old: String, with new: String, in path: String) -> String {
        guard self.path(path, isWithin: old) else { return path }
        return new + path.dropFirst(old.count)
    }
}

/// One keyword in the Keyword List: its level's name, its full path, how
/// many photos carry it or a keyword below it, and the keywords below.
public struct KeywordTree: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    /// Photos tagged with this keyword or any keyword inside it.
    public var count: Int
    public var children: [KeywordTree]

    public var id: String { path }

    public init(name: String, path: String, count: Int, children: [KeywordTree] = []) {
        self.name = name
        self.path = path
        self.count = count
        self.children = children
    }

    /// The hierarchy of every keyword in `index` (image id → paths). A level
    /// that only exists as part of a longer path ("Places" in
    /// "Places|France") is listed too, counting the photos beneath it.
    public static func build(from index: [Int64: Set<String>]) -> [KeywordTree] {
        var photos: [String: Set<Int64>] = [:]
        for (id, paths) in index {
            for path in paths {
                guard let path = KeywordPath.normalized(path) else { continue }
                photos[path, default: []].insert(id)
                for ancestor in KeywordPath.ancestors(path) { photos[ancestor, default: []].insert(id) }
            }
        }
        var childrenOf: [String: [String]] = [:]
        var roots: [String] = []
        for path in photos.keys {
            if let parent = KeywordPath.parent(path) { childrenOf[parent, default: []].append(path) } else { roots.append(path) }
        }
        func node(_ path: String) -> KeywordTree {
            KeywordTree(name: KeywordPath.leaf(path), path: path, count: photos[path]?.count ?? 0,
                        children: sorted(childrenOf[path] ?? []).map(node))
        }
        return sorted(roots).map(node)
    }

    private static func sorted(_ paths: [String]) -> [String] {
        paths.sorted { KeywordPath.leaf($0).localizedStandardCompare(KeywordPath.leaf($1)) == .orderedAscending }
    }

    /// The tree cut down to keywords whose name contains `text`, with the
    /// levels above them kept so they still show where they belong.
    public static func filter(_ trees: [KeywordTree], matching text: String) -> [KeywordTree] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return trees }
        return trees.compactMap { tree in
            let children = filter(tree.children, matching: needle)
            let matches = tree.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            guard matches || !children.isEmpty else { return nil }
            var copy = tree
            copy.children = matches ? tree.children : children
            return copy
        }
    }
}
