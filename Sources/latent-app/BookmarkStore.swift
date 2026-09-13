import Foundation

/// Remembers folders across launches in a way a sandboxed app is allowed
/// to reopen: security-scoped bookmarks rather than paths.
///
/// A path in UserDefaults is useless under the App Sandbox: the app can
/// name the folder but not touch it. A bookmark made with the security
/// scope carries the user's permission from the open panel forward, and
/// resolving it later grants access again once `startAccessing` is
/// called. Outside the sandbox (a `swift run` build) the same calls work
/// and simply have nothing to enforce.
enum BookmarkStore {
    static func save(_ url: URL, key: String) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Fall back to the path so a non-sandboxed build still works.
            UserDefaults.standard.set(url, forKey: key)
        }
    }

    /// Resolves and starts accessing. The access stays open for the life
    /// of the process; these are one folder each, so nothing leaks.
    static func resolve(key: String) -> URL? {
        if let data = UserDefaults.standard.data(forKey: key) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale { save(url, key: key) }
                return url
            }
            return nil
        }
        return UserDefaults.standard.url(forKey: key)
    }

    static func clear(key: String) { UserDefaults.standard.removeObject(forKey: key) }

    static let lastFolder = "latent.lastFolderBookmark"
    static let exportDestination = "latent.exportDestination"
    static let defaultExportFolder = "latent.defaultExportFolder"
}
