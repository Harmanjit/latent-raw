import XCTest
@testable import Catalog

/// The import pass (Reconcile step 4): new and changed files hashed and
/// read a few at once, metadata read in the same pass for files that can't
/// be renames and after the plan for the rest. Runs on CI with the golden
/// D750 raw.
final class ImportPassTests: XCTestCase {
    var folder: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        _ = try TestAssets.d750URL()
        folder = fm.temporaryDirectory
            .appendingPathComponent("latent-import-pass-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? fm.removeItem(at: folder) }
    }

    private func url(_ relPath: String) -> URL { folder.appendingPathComponent(relPath) }

    /// What one file read on its own, one at a time, makes of it: the rows
    /// the parallel pass writes must be exactly these.
    private func sequentialRecord(_ relPath: String, tags: String?) throws -> ImageRecord {
        let values = try url(relPath).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = Catalog.DiskFile(relPath: relPath, size: Int64(values.fileSize ?? 0),
                                    mtime: ImageRecord.milliseconds(values.contentModificationDate ?? .distantPast),
                                    finderTags: tags)
        let hash = ImageRecord.hashData(FileHash.xxh64(try Data(contentsOf: url(relPath), options: .mappedIfSafe)))
        return try Catalog.makeRecord(for: file, at: url(relPath), hash: hash)
    }

    func testParallelImportWritesTheSameRowsAsOneAtATime() async throws {
        let names = (0..<9).map { "DSC_\($0).NEF" }
        for (i, name) in names.enumerated() { try TestAssets.copyD750(to: url(name), variant: i) }
        let catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.added, names.count, "\(report)")
        XCTAssertEqual(report.failures.count, 0, "\(report.failures)")
        for name in names {
            let rowRead = try await catalog.image(forRelPath: name)
            var row = try XCTUnwrap(rowRead)
            let expected = try sequentialRecord(name, tags: row.finderTags)
            row.id = nil
            XCTAssertEqual(row, expected, name)
        }
    }

    /// A new file the same size as a row that lost its file could be that
    /// file renamed, so its metadata waits for the plan. When its content
    /// turns out to be new, it is still read and the row complete.
    func testNewFileTheSizeOfARemovedOneIsStillRead() async throws {
        try TestAssets.copyD750(to: url("A.NEF"), variant: 1)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try fm.removeItem(at: url("A.NEF"))
        try TestAssets.copyD750(to: url("B.NEF"), variant: 2)   // same length, other bytes

        let report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1, "\(report)")
        XCTAssertEqual(report.removed, 1, "\(report)")
        XCTAssertEqual(report.renamed, 0, "\(report)")
        XCTAssertEqual(report.failures.count, 0, "\(report.failures)")
        let rowRead = try await catalog.image(forRelPath: "B.NEF")
        var row = try XCTUnwrap(rowRead)
        XCTAssertNotNil(row.camera)
        XCTAssertEqual(row.exifExtrasVersion, ExifExtras.version)
        row.id = nil
        XCTAssertEqual(row, try sequentialRecord("B.NEF", tags: row.finderTags))
    }

    /// A rename alongside new files of other sizes: the renamed row keeps
    /// what the user did, the new ones get full rows.
    func testRenameAndNewFilesInOnePass() async throws {
        try TestAssets.copyD750(to: url("A.NEF"), variant: 1)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let beforeRead = try await catalog.image(forRelPath: "A.NEF")
        let before = try XCTUnwrap(beforeRead)
        try fm.moveItem(at: url("A.NEF"), to: url("Renamed.NEF"))
        try TestAssets.copyD750(to: url("New10.NEF"), variant: 10)
        try TestAssets.copyD750(to: url("New100.NEF"), variant: 100)

        let report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1, "\(report)")
        XCTAssertEqual(report.added, 2, "\(report)")
        XCTAssertEqual(report.failures.count, 0, "\(report.failures)")
        let renamedRead = try await catalog.image(forRelPath: "Renamed.NEF")
        let renamed = try XCTUnwrap(renamedRead)
        XCTAssertEqual(renamed.id, before.id)
        for name in ["New10.NEF", "New100.NEF"] {
            let rowRead = try await catalog.image(forRelPath: name)
            var row = try XCTUnwrap(rowRead)
            row.id = nil
            XCTAssertEqual(row, try sequentialRecord(name, tags: row.finderTags), name)
        }
    }

    /// A file that can't be read fails alone; the others are catalogued.
    func testUnreadableFileFailsAlone() async throws {
        for i in 0..<4 { try TestAssets.copyD750(to: url("OK\(i).NEF"), variant: i) }
        try Data("not a raw".utf8).write(to: url("Broken.NEF"))
        let catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 4, "\(report)")
        XCTAssertEqual(report.failures.map(\.relPath), ["Broken.NEF"])
    }

    // MARK: - ImportWorkers

    func testWorkersReturnResultsInOrderAndStayWithinWidth() {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var running = 0
            var peak = 0
            func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
            func leave() { lock.lock(); running -= 1; lock.unlock() }
        }
        let gauge = Gauge()
        let results = ImportWorkers.map(count: 50, width: 3) { index, buffer -> Int in
            gauge.enter()
            defer { gauge.leave() }
            XCTAssertEqual(buffer.count, FileHash.chunkSize)
            usleep(1000)
            return index * 2
        }
        XCTAssertEqual(results, (0..<50).map { $0 * 2 })
        XCTAssertLessThanOrEqual(gauge.peak, 3)
        XCTAssertEqual(ImportWorkers.map(count: 0, width: 4) { i, _ in i }, [])
    }
}
