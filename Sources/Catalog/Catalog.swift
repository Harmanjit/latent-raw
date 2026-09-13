import Foundation
import GRDB

public enum CatalogError: Error {
    case volumeDetectionFailed
}

/// One catalog = one `_latent/` folder next to a set of photos. An actor
/// because each catalog owns a single DatabaseQueue and all access to it
/// should be serialized through here (DESIGN.md §11: "each catalog is an
/// actor that owns its database connection").
public actor Catalog {
    public let rootPath: URL          // the photo folder itself, not _latent/
    public let containerPath: URL     // .../_latent
    let dbQueue: DatabaseQueue

    public static let containerName = "_latent"
    /// The container name before the app was renamed (September 2026).
    /// `open(at:)` renames it in place, so folders catalogued by the old
    /// build keep their database, sidecars and thumbnails.
    public static let legacyContainerName = "_rawhead"

    private init(rootPath: URL, containerPath: URL, dbQueue: DatabaseQueue) {
        self.rootPath = rootPath
        self.containerPath = containerPath
        self.dbQueue = dbQueue
    }

    /// Opens (or creates) the catalog for `folder`. Journal mode is chosen
    /// per DESIGN.md §5.3: WAL on local/external volumes, rollback journal
    /// on network shares, because WAL is unreliable over SMB/NFS.
    public static func open(at folder: URL) throws -> Catalog {
        let folder = folder.standardizedFileURL
        let container = folder.appendingPathComponent(containerName, isDirectory: true)
        let fm = FileManager.default

        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: container.path, isDirectory: &isDir) {
            let legacy = folder.appendingPathComponent(legacyContainerName, isDirectory: true)
            if fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue {
                try fm.moveItem(at: legacy, to: container)
            }
        }
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

    // MARK: - Paths

    public var xmpDirectory: URL { containerPath.appendingPathComponent("xmp", isDirectory: true) }
    public var thumbnailDirectory: URL { containerPath.appendingPathComponent("thumbnails", isDirectory: true) }

    /// Absolute path of an image from its catalog-relative path.
    public func fileURL(forRelPath relPath: String) -> URL {
        rootPath.appendingPathComponent(relPath)
    }

    /// Sidecars mirror the image's subpath and keep the full filename
    /// (DESIGN.md §5.1): `xmp/Day 2/DSC_0107.NEF.xmp`.
    public func sidecarURL(forRelPath relPath: String) -> URL {
        xmpDirectory.appendingPathComponent(relPath + ".xmp")
    }

    public func thumbnailURL(forRelPath relPath: String) -> URL {
        thumbnailDirectory.appendingPathComponent(relPath + ".heic")
    }

    // MARK: - Queries

    /// Every image, newest capture first, then by path for stability.
    public func allImages() throws -> [ImageRecord] {
        try dbQueue.read { db in
            try ImageRecord
                .order(Column("capture_time").desc, Column("rel_path"))
                .fetchAll(db)
        }
    }

    public func image(forRelPath relPath: String) throws -> ImageRecord? {
        try dbQueue.read { db in
            try ImageRecord.filter(Column("rel_path") == relPath).fetchOne(db)
        }
    }

    public func imageCount() throws -> Int {
        try dbQueue.read { db in try ImageRecord.fetchCount(db) }
    }

    /// Keywords attached to an image, alphabetical.
    public func keywords(forImageID id: Int64) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT k.name FROM keywords k
                JOIN image_keywords ik ON ik.keyword_id = k.id
                WHERE ik.image_id = ? ORDER BY k.name
                """, arguments: [id])
        }
    }

    /// Every keyword assignment in one query, image id → names. Loaded
    /// with the image list so the grid can filter by keyword without a
    /// round trip per image.
    public func allImageKeywords() throws -> [Int64: Set<String>] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ik.image_id AS image_id, k.name AS name FROM image_keywords ik
                JOIN keywords k ON k.id = ik.keyword_id
                """)
            var index: [Int64: Set<String>] = [:]
            for row in rows {
                index[row["image_id"], default: []].insert(row["name"])
            }
            return index
        }
    }

    // MARK: - Settings and subfolder modes

    public func setting(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, to value: String?) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }

    static let defaultSubfolderModeKey = "default_subfolder_mode"

    /// What to do with a subfolder Latent hasn't seen before. `ask` by
    /// default: silently swallowing a subfolder into a catalog, or
    /// silently ignoring one, are both surprising.
    public func defaultSubfolderMode() throws -> SubfolderMode {
        try setting(Self.defaultSubfolderModeKey).flatMap(SubfolderMode.init(rawValue:)) ?? .ask
    }

    public func setDefaultSubfolderMode(_ mode: SubfolderMode) throws {
        try setSetting(Self.defaultSubfolderModeKey, to: mode.rawValue)
    }

    public func subfolderMode(forRelPath relPath: String) throws -> SubfolderMode? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT mode FROM subfolders WHERE rel_path = ?",
                                arguments: [relPath])
        }.flatMap(SubfolderMode.init(rawValue:))
    }

    public func setSubfolderMode(_ mode: SubfolderMode, forRelPath relPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO subfolders (rel_path, mode) VALUES (?, ?)",
                           arguments: [relPath, mode.rawValue])
        }
    }
}
