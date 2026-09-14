import Foundation
import AppKit
import Catalog

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
        if let data = bookmark(for: url) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            // Fall back to the path so a non-sandboxed build still works.
            UserDefaults.standard.set(url, forKey: key)
        }
    }

    /// Resolves and starts accessing. The access stays open for the life
    /// of the process; these are one folder each, so nothing leaks.
    static func resolve(key: String) -> URL? {
        if let data = UserDefaults.standard.data(forKey: key) {
            guard let (url, stale) = resolveQuietly(data) else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            if stale { save(url, key: key) }
            return url
        }
        return UserDefaults.standard.url(forKey: key)
    }

    static func clear(key: String) { UserDefaults.standard.removeObject(forKey: key) }

    /// The folder a saved bookmark names, read from the bookmark itself
    /// without resolving it: how to name a folder whose disk is away.
    static func storedPath(key: String) -> URL? {
        UserDefaults.standard.data(forKey: key).flatMap(storedURL)
    }

    /// Bookmarks are resolved at launch, where nothing may mount a network
    /// share or put up a dialog on its own: a disk that isn't there simply
    /// fails to resolve. A security-scoped resolve that fails falls back to
    /// a plain one, for bookmarks made outside the sandbox.
    static func resolveQuietly(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        let quiet: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        if let url = try? URL(resolvingBookmarkData: data, options: quiet.union(.withSecurityScope),
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        if let url = try? URL(resolvingBookmarkData: data, options: quiet, relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        return nil
    }

    static func storedURL(_ data: Data) -> URL? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    static let lastFolder = "latent.lastFolderBookmark"
    static let exportDestination = "latent.exportDestination"
    static let defaultExportFolder = "latent.defaultExportFolder"
    static let favouriteFolders = "latent.favouriteFolderBookmarks"
}

/// A folder in the sidebar's Favourites.
struct FavouriteFolder: Identifiable, Equatable {
    var url: URL
    var bookmark: Data
    /// False while its disk or share isn't mounted, or the folder has gone:
    /// the row stays (it stands for the bookmark) but can't expand or open.
    var isAvailable: Bool
    var id: String { url.standardizedFileURL.path }
}

/// The favourite folders, shared by every window. Each is a security-scoped
/// bookmark whose access starts once, at launch or when added, and stays
/// open for the life of the process: that access is what lets the sidebar
/// list and open everything inside it.
@MainActor
final class FavouriteFolders: ObservableObject {
    static let shared = FavouriteFolders()

    @Published private(set) var folders: [FavouriteFolder] = []
    /// Paths whose security scope has been started, so a retry never
    /// starts one twice.
    private var accessing: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        for data in UserDefaults.standard.array(forKey: BookmarkStore.favouriteFolders) as? [Data] ?? [] {
            if let resolved = BookmarkStore.resolveQuietly(data) {
                startAccessing(resolved.url)
                let fresh = resolved.stale ? (BookmarkStore.bookmark(for: resolved.url) ?? data) : data
                folders.append(FavouriteFolder(url: resolved.url, bookmark: fresh, isAvailable: true))
            } else if let stored = BookmarkStore.storedURL(data) {
                folders.append(FavouriteFolder(url: stored, bookmark: data, isAvailable: false))
            }
        }
        persist()
        // A disk plugged in or a share connected may bring a favourite back;
        // one ejected takes its favourites away.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckVolumes() }
            })
        }
    }

    func contains(_ url: URL) -> Bool {
        folders.contains { FolderAccess.samePath($0.url, url) }
    }

    /// Adds a folder the user chose, dragged in or picked from the tree.
    /// Returns false if no bookmark could be made for it.
    @discardableResult
    func add(_ url: URL) -> Bool {
        guard !contains(url) else { return true }
        guard let data = BookmarkStore.bookmark(for: url) else { return false }
        startAccessing(url)
        folders.append(FavouriteFolder(url: url.standardizedFileURL, bookmark: data, isAvailable: true))
        persist()
        return true
    }

    /// Forgets the bookmark. Its access is left open until quit: the open
    /// catalog may be this folder or inside it.
    func remove(_ url: URL) {
        folders.removeAll { FolderAccess.samePath($0.url, url) }
        persist()
    }

    /// Resolves an unavailable favourite again, quietly, as a click on it
    /// asks. Returns its folder when it can be opened now.
    func retry(_ url: URL) -> URL? {
        guard let index = folders.firstIndex(where: { FolderAccess.samePath($0.url, url) }) else { return nil }
        guard !folders[index].isAvailable else { return folders[index].url }
        guard let resolved = BookmarkStore.resolveQuietly(folders[index].bookmark),
              FolderAccess.problem(opening: resolved.url) == nil else { return nil }
        startAccessing(resolved.url)
        folders[index].url = resolved.url
        folders[index].isAvailable = true
        if resolved.stale, let data = BookmarkStore.bookmark(for: resolved.url) {
            folders[index].bookmark = data
            persist()
        }
        return resolved.url
    }

    /// After a mount or unmount. Only favourites under /Volumes can be
    /// affected; a missing volume's folder fails to open at once, so this
    /// never waits on a disk.
    private func recheckVolumes() {
        for index in folders.indices where folders[index].url.path.hasPrefix("/Volumes/") {
            if folders[index].isAvailable {
                if FolderAccess.isOnDisconnectedVolume(folders[index].url.path) { folders[index].isAvailable = false }
            } else {
                _ = retry(folders[index].url)
            }
        }
    }

    private func startAccessing(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard !accessing.contains(key) else { return }
        if url.startAccessingSecurityScopedResource() { accessing.insert(key) }
    }

    private func persist() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: BookmarkStore.favouriteFolders)
    }
}
