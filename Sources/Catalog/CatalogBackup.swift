import Foundation
import GRDB

/// Copies of a folder's catalog database, kept in `_latent/backups/`
/// (darktable keeps dated snapshots of its library the same way).
///
/// The sidecars hold every edit, rating and keyword, so a lost database
/// can always be rebuilt from them; what only the database holds is the
/// rest: collections, subfolder decisions, stacks and the like. A backup
/// is made with SQLite's online backup API, so it is a consistent copy
/// even of a database in WAL mode, and it is made:
///
/// - when the catalog opens, at most once a day (`backUpIfDue`), and only
///   for a catalog that holds photos, so creating one makes no backup;
/// - always just before the schema is migrated (`backUpBeforeMigration`),
///   so a newer Latent never leaves the only copy in a form an older one
///   can't read.
///
/// Backups rotate among `slotCount` fixed files, `catalog-backup-1.sqlite`
/// to `-5`: a new one fills a missing slot or else overwrites the oldest.
/// Nothing is ever deleted.
///
/// Restoring (`restore`) needs the catalog closed: the current database is
/// renamed to `catalog-replaced-<date>.sqlite`, kept, and the backup is
/// copied into its place.
public enum CatalogBackup {
    public static let slotCount = 5
    public static let folderName = "backups"
    /// How long after the newest backup the next one on opening is due.
    public static let dailyInterval: TimeInterval = 24 * 60 * 60

    /// One backup file.
    public struct Slot: Sendable, Equatable, Identifiable {
        /// 1 to `slotCount`.
        public let number: Int
        public let url: URL
        /// When it was written.
        public let date: Date
        public var id: Int { number }
    }

    public enum RestoreError: Error, CustomStringConvertible {
        case missingBackup(URL)
        public var description: String {
            switch self {
            case .missingBackup(let url): "the backup \(url.lastPathComponent) is no longer there"
            }
        }
    }

    public static func folder(in container: URL) -> URL {
        container.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func slotURL(_ number: Int, in container: URL) -> URL {
        folder(in: container).appendingPathComponent("catalog-backup-\(number).sqlite")
    }

    /// The backups there are, newest first.
    public static func slots(in container: URL) -> [Slot] {
        (1...slotCount).compactMap { number -> Slot? in
            let url = slotURL(number, in: container)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate, (values.fileSize ?? 0) > 0 else { return nil }
            return Slot(number: number, url: url, date: date)
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.number < $1.number }
    }

    /// The file the next backup goes into: the first slot not yet written,
    /// else the one written longest ago.
    static func nextSlot(in container: URL) -> URL {
        let existing = slots(in: container)
        if let free = (1...slotCount).first(where: { number in !existing.contains { $0.number == number } }) {
            return slotURL(free, in: container)
        }
        return existing.last!.url
    }

    /// Whether the daily backup is due: no backup yet, or the newest is a
    /// day old. A clock set back counts as due too.
    public static func isDue(in container: URL, now: Date = Date()) -> Bool {
        guard let newest = slots(in: container).first else { return true }
        let age = now.timeIntervalSince(newest.date)
        return age >= dailyInterval || age < -60
    }

    /// Copies `source` into the next slot and returns the slot's file.
    @discardableResult
    public static func backUp(_ source: some DatabaseReader, container: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder(in: container), withIntermediateDirectories: true)
        let destination = nextSlot(in: container)
        do {
            try copy(source, into: destination)
        } catch {
            // A slot SQLite can't open (cut short by a crash, say) is
            // emptied in place, never deleted, and written again.
            guard fm.fileExists(atPath: destination.path) else { throw error }
            try Data().write(to: destination)
            try copy(source, into: destination)
        }
        // The backup's date is when it was made, whatever SQLite left.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return destination
    }

    private static func copy(_ source: some DatabaseReader, into destination: URL) throws {
        let target = try DatabaseQueue(path: destination.path)
        try source.backup(to: target)
        try target.close()
    }

    /// The daily backup on opening: made when one is due and the catalog
    /// holds at least one photo. Returns the file written, or nil.
    @discardableResult
    public static func backUpIfDue(_ source: some DatabaseReader, container: URL, now: Date = Date()) throws -> URL? {
        guard isDue(in: container, now: now) else { return nil }
        let hasPhotos = try source.read { db in
            try db.tableExists("images") && (try Int.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM images)") ?? 0) != 0
        }
        guard hasPhotos else { return nil }
        return try backUp(source, container: container)
    }

    /// The backup before a migration: made when `migrator` has migrations
    /// this database hasn't had and it has had at least one (a new,
    /// empty database needs no backup). Returns the file written, or nil.
    @discardableResult
    static func backUpBeforeMigration(_ queue: DatabaseQueue, migrator: DatabaseMigrator,
                                      container: URL) throws -> URL? {
        let (applied, complete) = try queue.read { db in
            (try migrator.appliedIdentifiers(db), try migrator.hasCompletedMigrations(db))
        }
        guard !applied.isEmpty, !complete else { return nil }
        return try backUp(queue, container: container)
    }

    /// Puts `slot`'s backup in place of the catalog database in `container`,
    /// which must not be open. The current database (and its `-wal` and
    /// `-shm` files) is renamed to `catalog-replaced-<date>.sqlite`, never
    /// deleted, and its new name returned; nil when there was none.
    @discardableResult
    public static func restore(_ slot: Slot, container: URL, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: slot.url.path) else { throw RestoreError.missingBackup(slot.url) }
        let database = container.appendingPathComponent("catalog.sqlite")
        var replaced: URL?
        if fm.fileExists(atPath: database.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let stamp = formatter.string(from: now)
            var target = container.appendingPathComponent("catalog-replaced-\(stamp).sqlite")
            var attempt = 2
            while fm.fileExists(atPath: target.path) {
                target = container.appendingPathComponent("catalog-replaced-\(stamp)-\(attempt).sqlite")
                attempt += 1
            }
            try fm.moveItem(at: database, to: target)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: database.path + suffix) {
                try? fm.moveItem(atPath: database.path + suffix, toPath: target.path + suffix)
            }
            replaced = target
        }
        do {
            try fm.copyItem(at: slot.url, to: database)
        } catch {
            // Put the replaced database back rather than leave none.
            if let replaced {
                try? fm.moveItem(at: replaced, to: database)
                for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: replaced.path + suffix) {
                    try? fm.moveItem(atPath: replaced.path + suffix, toPath: database.path + suffix)
                }
            }
            throw error
        }
        return replaced
    }
}

extension Catalog {
    /// This catalog's backups, newest first (CatalogBackup).
    public nonisolated var backups: [CatalogBackup.Slot] { CatalogBackup.slots(in: containerPath) }

    /// Makes a backup now, whether or not one is due.
    @discardableResult
    public func backUpNow() throws -> URL {
        try CatalogBackup.backUp(dbQueue, container: containerPath)
    }

    /// Closes the database, so its file can be replaced by a backup. Every
    /// later call on this catalog fails; open the folder again for a new one.
    public func closeDatabase() throws {
        try dbQueue.close()
    }
}
