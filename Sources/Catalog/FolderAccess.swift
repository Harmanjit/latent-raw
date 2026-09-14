import Foundation
import GRDB

/// Questions about a folder that come before any catalog work: what is
/// inside it (for the sidebar tree), whether it can be opened at all, which
/// catalog already owns it, and how to say what went wrong.
///
/// Everything here reads the disk, possibly a network share, so call it off
/// the main thread. Stateless and thread-safe.
public enum FolderAccess {
    // MARK: - Listing

    /// Visible subfolders, sorted as Finder sorts names. Hidden folders,
    /// packages, symbolic links and catalog containers are left out: a
    /// catalog is one folder and never follows a link out of it (as
    /// `reconcile` doesn't), and `_latent` is Latent's own. Empty when the
    /// folder can't be read, so an unreadable folder simply has nothing to
    /// expand.
    ///
    /// Reads with `readdir`: each entry carries its type, so the thousands
    /// of photos in a typical folder are skipped without a `stat` each.
    public static func subfolders(of folder: URL) -> [URL] {
        var named: [(url: URL, name: String)] = []
        forEachSubfolder(of: folder) { url, name in
            named.append((url, name))
            return true
        }
        return named.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.url)
    }

    /// True as soon as one visible subfolder is found, for the sidebar's
    /// disclosure triangles. Stops reading at the first one.
    public static func hasSubfolders(_ folder: URL) -> Bool {
        var found = false
        forEachSubfolder(of: folder) { _, _ in
            found = true
            return false
        }
        return found
    }

    /// Whether `folder` holds a catalog container of its own.
    public static func hasCatalog(_ folder: URL) -> Bool {
        [Catalog.containerName, Catalog.legacyContainerName].contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path,
                                                  isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Names never shown as subfolders, whatever their attributes say.
    static func isExcludedName(_ name: String) -> Bool {
        name.hasPrefix(".") || name == Catalog.containerName || name == Catalog.legacyContainerName
    }

    private static let folderKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey,
                                                          .isSymbolicLinkKey, .nameKey]

    /// Calls `body` with each visible subfolder and its name, in directory
    /// order, until it returns false.
    private static func forEachSubfolder(of folder: URL, _ body: (URL, String) -> Bool) {
        guard let directory = opendir(folder.path) else { return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            // Links report DT_LNK and are skipped here; DT_UNKNOWN (some file
            // systems don't fill the type in) is checked below.
            let type = Int32(entry.pointee.d_type)
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name == "." || name == ".." || isExcludedName(name) { continue }
            let url = folder.appendingPathComponent(name, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: folderKeys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  values.isPackage != true, values.isHidden != true else { continue }
            if !body(url, name) { return }
        }
    }

    // MARK: - Trouble

    /// Why a folder can't be opened, in terms the user can act on.
    public enum Trouble: Equatable, Sendable {
        /// The sandbox (or file permissions) refused. Under the sandbox this
        /// is a folder outside everything the user has chosen or added.
        case notPermitted
        /// On a disk or network share that isn't mounted.
        case notConnected
        /// Moved, renamed or deleted.
        case missing
        /// On a read-only volume, where the catalog can't be created.
        case readOnly
        case other(String)
    }

    /// Opens the directory itself rather than asking whether it exists: the
    /// sandbox lets the app see that a folder exists long before it lets it
    /// read one. Nil when the folder opens.
    public static func problem(opening folder: URL,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Trouble? {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 {
            close(fd)
            return nil
        }
        let code = errno
        return trouble(posix: code, folder: folder, exists: exists) ?? .other(String(cString: strerror(code)))
    }

    /// Sorts an error from opening a folder or its catalog into a `Trouble`,
    /// looking through underlying errors: Foundation wraps the POSIX error
    /// the sandbox actually returned.
    public static func trouble(for error: any Error, folder: URL,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Trouble {
        var next: (any Error)? = error
        while let current = next {
            if let database = current as? DatabaseError {
                switch database.resultCode {
                case .SQLITE_PERM, .SQLITE_AUTH: return .notPermitted
                case .SQLITE_READONLY: return .readOnly
                default: break
                }
            }
            let ns = current as NSError
            if ns.domain == NSCocoaErrorDomain {
                switch ns.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .notPermitted
                case NSFileWriteVolumeReadOnlyError: return .readOnly
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    return isOnDisconnectedVolume(folder.path, exists: exists) ? .notConnected : .missing
                default: break
                }
            }
            if ns.domain == NSPOSIXErrorDomain, let found = trouble(posix: Int32(ns.code), folder: folder, exists: exists) {
                return found
            }
            next = ns.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return .other(String(describing: error))
    }

    private static func trouble(posix code: Int32, folder: URL, exists: (String) -> Bool) -> Trouble? {
        switch code {
        case EPERM, EACCES: .notPermitted
        case EROFS: .readOnly
        case ENOENT, ENOTDIR: isOnDisconnectedVolume(folder.path, exists: exists) ? .notConnected : .missing
        default: nil
        }
    }

    /// Whether `path` lies on a volume under /Volumes that isn't mounted
    /// now: an external disk unplugged, or a network share not connected.
    public static func isOnDisconnectedVolume(_ path: String,
                                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return false }
        return !exists("/Volumes/" + parts[2])
    }

    /// One or two plain sentences for the status bar.
    public static func message(for trouble: Trouble, folder: URL) -> String {
        let name = "“\(FileManager.default.displayName(atPath: folder.path))”"
        return switch trouble {
        case .notPermitted:
            "Latent doesn’t have permission to open \(name). Choose Open Folder… and select it, "
                + "or add a folder that contains it to the sidebar."
        case .notConnected:
            "\(name) is on a disk or network share that isn’t connected. Connect it, then try again."
        case .missing:
            "\(name) can’t be found. It may have been moved, renamed or deleted."
        case .readOnly:
            "\(name) is on a read-only disk, and Latent keeps its catalog inside the folder, so it can’t open it."
        case .other(let reason):
            "\(name) can’t be opened: \(reason)"
        }
    }

    // MARK: - Ownership

    /// A folder that is an included subfolder of another folder's catalog.
    public struct Membership: Equatable, Sendable {
        /// The folder holding the catalog.
        public let root: URL
        /// The subfolder's path within it, "Day 2/Morning".
        public let relPath: String
    }

    /// The catalog `folder` already belongs to, when an enclosing folder's
    /// catalog includes it (DESIGN.md §5.2).
    ///
    /// Opening such a folder on its own would give it a container, and the
    /// enclosing catalog would then treat it as independent and drop its
    /// images. Only the nearest enclosing catalog counts: one further up
    /// already treats that one as independent. Reads that catalog's
    /// database read-only; a folder with a catalog of its own, or none
    /// above it, belongs to nobody.
    public static func owningCatalog(of folder: URL) -> Membership? {
        let folder = folder.standardizedFileURL
        guard !hasCatalog(folder) else { return nil }
        var parts = [folder.lastPathComponent]
        var ancestor = folder.deletingLastPathComponent()
        while ancestor.path != "/" {
            if hasCatalog(ancestor) {
                let relPath = parts.reversed().joined(separator: "/")
                guard let modes = try? subfolderModes(ofCatalogIn: ancestor),
                      isIncluded(relPath, defaultMode: modes.defaultMode, modes: modes.modes) else { return nil }
                return Membership(root: ancestor, relPath: relPath)
            }
            parts.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
        }
        return nil
    }

    /// Whether reconciling would reach `relPath`: every folder on the way
    /// down must be included, by its own recorded mode or, where none is
    /// recorded yet, by the catalog's default.
    static func isIncluded(_ relPath: String, defaultMode: SubfolderMode, modes: [String: SubfolderMode]) -> Bool {
        var prefix = ""
        for part in relPath.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            guard (modes[prefix] ?? defaultMode) == .included else { return false }
        }
        return !prefix.isEmpty
    }

    private static func subfolderModes(ofCatalogIn root: URL) throws -> (defaultMode: SubfolderMode, modes: [String: SubfolderMode]) {
        let container = [Catalog.containerName, Catalog.legacyContainerName]
            .map { root.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("catalog.sqlite").path) }
        guard let container else { throw CocoaError(.fileNoSuchFile) }
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: container.appendingPathComponent("catalog.sqlite").path,
                                      configuration: config)
        return try queue.read { db in
            let defaultMode = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?",
                                                  arguments: [Catalog.defaultSubfolderModeKey])
                .flatMap(SubfolderMode.init(rawValue:)) ?? .ask
            var modes: [String: SubfolderMode] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT rel_path, mode FROM subfolders") {
                if let mode = SubfolderMode(rawValue: row["mode"]) { modes[row["rel_path"]] = mode }
            }
            return (defaultMode, modes)
        }
    }

    // MARK: - Paths

    /// Path components, so /a/b and /a/b/ compare equal and /a/bc is not
    /// inside /a/b.
    static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    }

    public static func samePath(_ a: URL, _ b: URL) -> Bool {
        components(a) == components(b)
    }

    /// The folders from `root` down to `target`, both included; nil when
    /// `target` isn't inside `root`.
    public static func chain(from root: URL, to target: URL) -> [URL]? {
        let rootParts = components(root), targetParts = components(target)
        guard targetParts.count >= rootParts.count, Array(targetParts.prefix(rootParts.count)) == rootParts else {
            return nil
        }
        var url = root.standardizedFileURL
        var chain = [url]
        for part in targetParts.dropFirst(rootParts.count) {
            url = url.appendingPathComponent(part, isDirectory: true)
            chain.append(url)
        }
        return chain
    }

    /// Which root to reveal `target` under: the deepest one containing it,
    /// so a favourite inside another favourite wins.
    public static func bestRoot(for target: URL, among roots: [URL]) -> Int? {
        roots.indices
            .filter { chain(from: roots[$0], to: target) != nil }
            .max { components(roots[$0]).count < components(roots[$1]).count }
    }
}
