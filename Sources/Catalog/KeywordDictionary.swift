import Foundation

/// Every keyword path Latent has seen or been given, across every folder:
/// darktable's tag dictionary, without a master catalog. Each folder's
/// catalog still holds its own photos' keywords; this only remembers the
/// names, so a keyword used in one folder is offered in the next.
///
/// Stored as JSON in Application Support (`keyword-dictionary.json`). The
/// Keyword List can show its unused keywords with a count of zero, and it
/// imports and exports a plain keyword list: one path per line, levels
/// separated by "|" (Lightroom's and darktable's text form takes ">" too).
public struct KeywordDictionary: Codable, Equatable, Sendable {
    public var version = 1
    /// Normalised paths (see `KeywordPath`). A path's ancestors are implied.
    public private(set) var paths: Set<String> = []

    public init() {}

    public init<Paths: Sequence>(paths: Paths) where Paths.Element == String {
        insert(paths)
    }

    /// Adds paths; returns whether anything was new.
    @discardableResult
    public mutating func insert<Paths: Sequence>(_ new: Paths) -> Bool where Paths.Element == String {
        var changed = false
        for path in new {
            guard let path = KeywordPath.normalized(path) else { continue }
            if paths.insert(path).inserted { changed = true }
        }
        return changed
    }

    /// Renames or moves a keyword and everything inside it, as the
    /// catalog's Rename does. Returns whether anything changed.
    @discardableResult
    public mutating func rename(_ old: String, to new: String) -> Bool {
        guard let old = KeywordPath.normalized(old), let new = KeywordPath.normalized(new), old != new else { return false }
        let affected = paths.filter { KeywordPath.path($0, isWithin: old) }
        // A level that only exists as an ancestor still moves.
        let implied = paths.contains { KeywordPath.ancestors($0).contains(old) }
        guard !affected.isEmpty || implied else { return false }
        paths.subtract(affected)
        paths.formUnion(affected.map { KeywordPath.replacing(old, with: new, in: $0) })
        if affected.isEmpty { paths.insert(new) }
        return true
    }

    /// Forgets a keyword and everything inside it.
    @discardableResult
    public mutating func remove(_ path: String) -> Bool {
        guard let path = KeywordPath.normalized(path) else { return false }
        let before = paths.count
        paths = paths.filter { !KeywordPath.path($0, isWithin: path) }
        return paths.count != before
    }

    /// Every path with the levels above them, as the Keyword List shows them.
    public var allPaths: Set<String> {
        var result = paths
        for path in paths { result.formUnion(KeywordPath.ancestors(path)) }
        return result
    }

    // MARK: Text

    /// One path per line, levels joined by "|", sorted. Only the innermost
    /// paths are written: their ancestors come back with them.
    public var text: String {
        let leaves = paths.filter { path in !paths.contains { $0 != path && KeywordPath.path($0, isWithin: path) } }
        return leaves.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
            + (leaves.isEmpty ? "" : "\n")
    }

    /// The paths of a keyword list: one per line, levels joined by "|" or
    /// ">". Blank lines and lines starting with "#" are skipped, and a
    /// line's surrounding spaces and tabs don't count.
    public static func paths(fromText text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let path = KeywordPath.normalized(trimmed),
                  seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    // MARK: Storage

    /// Application Support/keyword-dictionary.json (in the app's container).
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("keyword-dictionary.json")
    }

    /// The dictionary at `url`; empty when there is none or it can't be read.
    public static func load(from url: URL) -> KeywordDictionary {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(KeywordDictionary.self, from: data) else { return KeywordDictionary() }
        // Tidied again: a hand-edited file may hold untidy names.
        return KeywordDictionary(paths: decoded.paths)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    enum CodingKeys: String, CodingKey { case version, paths }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        paths = Set(try c.decodeIfPresent([String].self, forKey: .paths) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(paths.sorted(), forKey: .paths)
    }
}

extension KeywordTree {
    /// The folder's hierarchy (as `build(from:)`) with `extra` paths added
    /// where the folder has none, each with a count of zero: the Keyword
    /// List with dictionary keywords shown.
    public static func build(from index: [Int64: Set<String>], including extra: Set<String>) -> [KeywordTree] {
        guard !extra.isEmpty else { return build(from: index) }
        var photos: [String: Set<Int64>] = [:]
        for (id, paths) in index {
            for path in paths {
                guard let path = KeywordPath.normalized(path) else { continue }
                photos[path, default: []].insert(id)
                for ancestor in KeywordPath.ancestors(path) { photos[ancestor, default: []].insert(id) }
            }
        }
        for path in extra {
            guard let path = KeywordPath.normalized(path) else { continue }
            for level in KeywordPath.ancestors(path) + [path] where photos[level] == nil { photos[level] = [] }
        }
        var childrenOf: [String: [String]] = [:]
        var roots: [String] = []
        for path in photos.keys {
            if let parent = KeywordPath.parent(path) { childrenOf[parent, default: []].append(path) } else { roots.append(path) }
        }
        func byLeaf(_ paths: [String]) -> [String] {
            paths.sorted { KeywordPath.leaf($0).localizedStandardCompare(KeywordPath.leaf($1)) == .orderedAscending }
        }
        func node(_ path: String) -> KeywordTree {
            KeywordTree(name: KeywordPath.leaf(path), path: path, count: photos[path]?.count ?? 0,
                        children: byLeaf(childrenOf[path] ?? []).map(node))
        }
        return byLeaf(roots).map(node)
    }
}
