import XCTest
import GRDB
@testable import Catalog

final class CatalogBackupTests: XCTestCase {
    private var folder: URL!
    private var container: URL { folder.appendingPathComponent(Catalog.containerName) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(Catalog.containerName),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A small database with one row saying `marker`.
    private func makeDatabase(_ name: String, marker: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: container.appendingPathComponent(name).path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS images (id INTEGER PRIMARY KEY, marker TEXT)")
            try db.execute(sql: "DELETE FROM images")
            try db.execute(sql: "INSERT INTO images (marker) VALUES (?)", arguments: [marker])
        }
        return queue
    }

    private func marker(at url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in try String.fetchOne(db, sql: "SELECT marker FROM images") }
    }

    private func setDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testBackupsRotateAmongFiveSlotsOverwritingTheOldest() throws {
        let source = try makeDatabase("source.sqlite", marker: "first")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var written: [URL] = []
        for n in 0..<5 {
            let url = try CatalogBackup.backUp(source, container: container)
            try setDate(base.addingTimeInterval(Double(n) * 3600), of: url)
            written.append(url)
        }
        XCTAssertEqual(Set(written).count, 5)
        XCTAssertEqual(CatalogBackup.slots(in: container).count, 5)
        XCTAssertEqual(CatalogBackup.slots(in: container).first?.url, written[4], "newest first")

        // The sixth overwrites the oldest, in place: still five files.
        try source.write { db in try db.execute(sql: "UPDATE images SET marker = 'second'") }
        let sixth = try CatalogBackup.backUp(source, container: container)
        XCTAssertEqual(sixth, written[0])
        XCTAssertEqual(try marker(at: sixth), "second")
        XCTAssertEqual(try marker(at: written[1]), "first")
        let files = try FileManager.default.contentsOfDirectory(atPath: CatalogBackup.folder(in: container).path)
            .filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(files.count, 5)
        XCTAssertEqual(CatalogBackup.slots(in: container).first?.url, sixth)
    }

    func testDamagedSlotIsOverwrittenInPlace() throws {
        let source = try makeDatabase("source.sqlite", marker: "good")
        let slot = CatalogBackup.slotURL(1, in: container)
        try FileManager.default.createDirectory(at: CatalogBackup.folder(in: container), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: slot)
        try setDate(Date(timeIntervalSince1970: 1_000), of: slot)
        // Slots 2 to 5 are newer, so slot 1 is the one to overwrite.
        for n in 2...5 {
            let url = CatalogBackup.slotURL(n, in: container)
            try CatalogBackup.backUp(source, container: container)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let next = try CatalogBackup.backUp(source, container: container)
        XCTAssertEqual(next, slot)
        XCTAssertEqual(try marker(at: slot), "good")
    }

    func testDailyBackupIsDueOncePerDay() throws {
        let source = try makeDatabase("source.sqlite", marker: "x")
        XCTAssertTrue(CatalogBackup.isDue(in: container))
        let now = Date()
        let url = try XCTUnwrap(try CatalogBackup.backUpIfDue(source, container: container, now: now))
        try setDate(now, of: url)
        XCTAssertFalse(CatalogBackup.isDue(in: container, now: now.addingTimeInterval(3600)))
        XCTAssertNil(try CatalogBackup.backUpIfDue(source, container: container, now: now.addingTimeInterval(3600)))
        XCTAssertTrue(CatalogBackup.isDue(in: container, now: now.addingTimeInterval(CatalogBackup.dailyInterval + 1)))
    }

    func testEmptyCatalogMakesNoDailyBackup() throws {
        let source = try DatabaseQueue(path: container.appendingPathComponent("empty.sqlite").path)
        try source.write { db in try db.execute(sql: "CREATE TABLE images (id INTEGER PRIMARY KEY)") }
        XCTAssertNil(try CatalogBackup.backUpIfDue(source, container: container))
        XCTAssertTrue(CatalogBackup.slots(in: container).isEmpty)
    }

    func testOpeningACatalogWithPhotosBacksItUpAndANewOneDoesNot() async throws {
        do {
            let catalog = try Catalog.open(at: folder)
            XCTAssertTrue(catalog.backups.isEmpty, "a new catalog has nothing worth backing up")
            try await catalog.dbQueue.write { db in
                var record = ImageRecord(id: nil, relPath: "a.nef", preservedName: nil, size: 1, mtime: 0,
                                         xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil,
                                         iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                                         orientation: nil, rating: 3, label: nil, flag: 0, sidecarMtime: nil,
                                         thumbKey: nil)
                try record.insert(db)
            }
        }
        let reopened = try Catalog.open(at: folder)
        XCTAssertEqual(reopened.backups.count, 1)
        // Not again the same day.
        let again = try Catalog.open(at: folder)
        XCTAssertEqual(again.backups.count, 1)
        _ = reopened
    }

    func testBackupBeforeMigrationOnlyWhenMigrationsArePending() throws {
        let path = container.appendingPathComponent("migrating.sqlite").path
        let queue = try DatabaseQueue(path: path)
        var first = DatabaseMigrator()
        first.registerMigration("one") { db in try db.execute(sql: "CREATE TABLE images (id INTEGER PRIMARY KEY)") }
        var second = first
        second.registerMigration("two") { db in try db.execute(sql: "ALTER TABLE images ADD COLUMN marker TEXT") }

        // A brand-new database: nothing to keep.
        XCTAssertNil(try CatalogBackup.backUpBeforeMigration(queue, migrator: first, container: container))
        try first.migrate(queue)
        // Up to date: no backup.
        XCTAssertNil(try CatalogBackup.backUpBeforeMigration(queue, migrator: first, container: container))
        // A newer schema waiting: a backup at the old one.
        let backup = try XCTUnwrap(try CatalogBackup.backUpBeforeMigration(queue, migrator: second, container: container))
        let copy = try DatabaseQueue(path: backup.path)
        let applied = try copy.read { db in try second.appliedIdentifiers(db) }
        XCTAssertEqual(applied, ["one"])
        try copy.close()
    }

    func testRestoreRenamesTheCurrentDatabaseAndCopiesTheBackupIn() throws {
        let current = try makeDatabase("catalog.sqlite", marker: "old")
        try CatalogBackup.backUp(current, container: container)
        try current.write { db in try db.execute(sql: "UPDATE images SET marker = 'new'") }
        try current.close()

        let slot = try XCTUnwrap(CatalogBackup.slots(in: container).first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let replaced = try XCTUnwrap(try CatalogBackup.restore(slot, container: container, now: now))
        XCTAssertTrue(replaced.lastPathComponent.hasPrefix("catalog-replaced-"))
        XCTAssertEqual(try marker(at: replaced), "new", "the replaced database is kept")
        XCTAssertEqual(try marker(at: container.appendingPathComponent("catalog.sqlite")), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.url.path), "the backup stays")

        // Restoring again in the same second keeps both replaced files.
        let second = try XCTUnwrap(try CatalogBackup.restore(slot, container: container, now: now))
        XCTAssertNotEqual(second, replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.path))
    }

    func testRestoringAMissingBackupChangesNothing() throws {
        _ = try makeDatabase("catalog.sqlite", marker: "kept")
        let gone = CatalogBackup.Slot(number: 3, url: CatalogBackup.slotURL(3, in: container), date: Date())
        XCTAssertThrowsError(try CatalogBackup.restore(gone, container: container))
        XCTAssertEqual(try marker(at: container.appendingPathComponent("catalog.sqlite")), "kept")
    }

    func testClosedCatalogCanBeRestoredAndReopened() async throws {
        do {
            let catalog = try Catalog.open(at: folder)
            try await catalog.setSubfolderMode(.included, forRelPath: "Day 1")
            try await catalog.backUpNow()
            try await catalog.setSubfolderMode(.independent, forRelPath: "Day 1")
            try await catalog.closeDatabase()
        }
        let slot = try XCTUnwrap(CatalogBackup.slots(in: container).first)
        try CatalogBackup.restore(slot, container: container)
        let reopened = try Catalog.open(at: folder)
        let mode = try await reopened.subfolderMode(forRelPath: "Day 1")
        XCTAssertEqual(mode, .included)
    }
}
