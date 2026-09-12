import Foundation
import GRDB

public enum CatalogError: Error {
    case volumeDetectionFailed
}

/// One catalog = one `_rawhead/` folder next to a set of photos. An actor
/// because each catalog owns a single DatabaseQueue and all access to it
/// should be serialized through here (DESIGN.md §11: "each catalog is an
/// actor that owns its database connection").
public actor Catalog {
    public let rootPath: URL          // the photo folder itself, not _rawhead/
    public let containerPath: URL     // .../_rawhead
    private let dbQueue: DatabaseQueue

    private init(rootPath: URL, containerPath: URL, dbQueue: DatabaseQueue) {
        self.rootPath = rootPath
        self.containerPath = containerPath
        self.dbQueue = dbQueue
    }

    /// Opens (or creates) the catalog for `folder`. Journal mode is chosen
    /// per DESIGN.md §5.3: WAL on local/external volumes, rollback journal
    /// on network shares, because WAL is unreliable over SMB/NFS.
    public static func open(at folder: URL) throws -> Catalog {
        let container = folder.appendingPathComponent("_rawhead", isDirectory: true)
        let fm = FileManager.default

        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: container.path, isDirectory: &isDir) {
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
            try fm.createDirectory(at: container.appendingPathComponent("xmp"),
                                    withIntermediateDirectories: true)
            try fm.createDirectory(at: container.appendingPathComponent("thumbnails"),
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: container.appendingPathComponent(".metadata_never_index").path,
                           contents: nil)
            // Exclude thumbnails/ from Time Machine (DESIGN.md §5.1); xmp/ and
            // catalog.sqlite are left backed up.
            var thumbsURL = container.appendingPathComponent("thumbnails")
            var excludable = URLResourceValues()
            excludable.isExcludedFromBackup = true
            try? thumbsURL.setResourceValues(excludable)
        }

        let dbPath = container.appendingPathComponent("catalog.sqlite").path
        var config = Configuration()
        config.prepareDatabase { db in
            let isNetworkVolume = try Catalog.isOnNetworkVolume(folder)
            try db.execute(sql: "PRAGMA journal_mode = \(isNetworkVolume ? "DELETE" : "WAL")")
        }

        let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try Schema.migrator().migrate(dbQueue)

        return Catalog(rootPath: folder, containerPath: container, dbQueue: dbQueue)
    }

    private static func isOnNetworkVolume(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
        return !(values.volumeIsLocal ?? true)
    }

    /// Reconciliation entry point (DESIGN.md §5.3): compares the directory
    /// listing and each sidecar's mtime against what's recorded, re-parsing
    /// only what changed. Not implemented yet — Phase 2.
    public func reconcile() async throws {
        // TODO(Phase 2): list `rootPath` (respecting subfolder modes),
        // diff against `images` by rel_path/size/mtime, diff sidecars by
        // sidecar_mtime, re-parse only what's stale, handle the renamed-file
        // case via xxhash lookup (DESIGN.md §5.3).
    }
}
