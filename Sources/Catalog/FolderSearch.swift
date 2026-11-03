import Foundation

/// Finds folders by name inside the sidebar's favourites, for the search
/// field above the folder tree.
///
/// The tree lists a level only when it is opened, so a folder three levels
/// down has never been read; this walks down from each favourite with
/// `FolderAccess.subfolders` (the same rules: no hidden folders, packages,
/// links or catalog containers), level by level, so near folders come
/// first, and stops at a depth and a number of matches. Reads the disk:
/// call it off the main thread. Checks for cancellation between folders.
public enum FolderSearch {
    public struct Match: Equatable, Sendable, Identifiable {
        public var url: URL
        /// The favourite it was found in, for showing where it is.
        public var root: URL
        public var id: String { url.path }

        /// "Favourite › 2026 › Lisbon": the path from the favourite down.
        public var trail: String {
            let rootParts = root.standardizedFileURL.pathComponents
            let parts = url.standardizedFileURL.pathComponents
            let below = parts.count > rootParts.count ? Array(parts[rootParts.count...]) : []
            return ([root.lastPathComponent] + below.dropLast()).joined(separator: " › ")
        }
    }

    /// Folders whose name contains `query` (case and accents ignored),
    /// nearest first. A favourite that matches is listed too.
    public static func find(_ query: String, under roots: [URL], maxDepth: Int = 8, limit: Int = 200) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func matches(_ url: URL) -> Bool { url.lastPathComponent.range(of: needle, options: options) != nil }

        var results: [Match] = []
        var seen = Set<String>()
        var level: [(url: URL, root: URL)] = roots.map { ($0, $0) }
        for root in roots where matches(root) && seen.insert(root.standardizedFileURL.path).inserted {
            results.append(Match(url: root, root: root))
        }
        var depth = 0
        while !level.isEmpty, depth < maxDepth, results.count < limit {
            var next: [(url: URL, root: URL)] = []
            for (folder, root) in level {
                if Task.isCancelled { return results }
                for child in FolderAccess.subfolders(of: folder) {
                    // A favourite inside another is walked once.
                    guard seen.insert(child.standardizedFileURL.path).inserted else { continue }
                    if matches(child) {
                        results.append(Match(url: child, root: root))
                        if results.count >= limit { return results }
                    }
                    next.append((child, root))
                }
            }
            level = next
            depth += 1
        }
        return results
    }
}
