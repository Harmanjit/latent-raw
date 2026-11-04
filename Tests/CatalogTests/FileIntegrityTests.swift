import XCTest
@testable import Catalog

/// Verify Files and Find Duplicates (FileIntegrity): the classification,
/// the uncached hash, what is recorded and when it stops counting, and the
/// duplicate groups, virtual copies left out.
@MainActor
final class FileIntegrityTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-integrity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Pure parts

    func testClassifyTellsChangedFromDamaged() {
        let hash = Data([1, 2, 3])
        var hashed = false
        let changed = FileIntegrity.classify(storedSize: 10, storedMtime: 5, storedHash: hash, fileSize: 11, fileMtime: 5) {
            hashed = true
            return hash
        }
        XCTAssertEqual(changed, .changed)
        XCTAssertFalse(hashed, "a changed file is never read")
        XCTAssertEqual(FileIntegrity.classify(storedSize: 10, storedMtime: 5, storedHash: hash, fileSize: 10, fileMtime: 6) { hash },
                       .changed)
        XCTAssertEqual(FileIntegrity.classify(storedSize: 10, storedMtime: 5, storedHash: hash, fileSize: 10, fileMtime: 5) { hash },
                       .verified)
        XCTAssertEqual(FileIntegrity.classify(storedSize: 10, storedMtime: 5, storedHash: hash, fileSize: 10, fileMtime: 5) { Data([9]) },
                       .damaged)
    }

    func testUncachedHashMatchesTheCatalogsHash() throws {
        let url = folder.appendingPathComponent("bytes.bin")
        var bytes = [UInt8](repeating: 0, count: 1_000_003)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: (index &* 2_654_435_761) >> 7) }
        try Data(bytes).write(to: url)
        XCTAssertEqual(try FileIntegrity.uncachedXXH64(ofFileAt: url), try FileHash.xxh64(ofFileAt: url))
        let empty = folder.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(try FileIntegrity.uncachedXXH64(ofFileAt: empty), FileHash.xxh64(Data()))
    }

    func testReportSummary() {
        func check(_ status: FileIntegrity.Status) -> FileIntegrity.Check {
            FileIntegrity.Check(imageID: 1, relPath: "a.NEF", fileName: "a.NEF", status: status, size: 1, mtime: 1)
        }
        let report = FileVerificationReport(checks: [check(.verified), check(.verified), check(.damaged), check(.changed)],
                                            elapsed: 14.2, planned: 4)
        XCTAssertEqual(report.summary, "Verified 2 files in 14 s · 1 damaged · 1 changed since the last scan")
        let cancelled = FileVerificationReport(checks: [check(.verified)], cancelled: true, elapsed: 75, planned: 9)
        XCTAssertEqual(cancelled.summary, "Verification cancelled · Verified 1 file of 9 in 1 min 15 s")
    }

    // MARK: A real folder

    /// A.NEF, B.NEF (a different file of the same moment) and C.NEF (a
    /// byte-identical copy of A).
    private func openLibrary() async throws -> Library {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        try TestAssets.copyD750(to: folder.appendingPathComponent("C.NEF"))
        let library = Library()
        library.undoManager = UndoManager()
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 3)
        return library
    }

    private func record(_ library: Library, _ name: String) throws -> ImageRecord {
        try XCTUnwrap(library.images.first { $0.fileName == name })
    }

    private func verify(_ library: Library) async throws -> [String: FileIntegrity.Status] {
        let catalog = try XCTUnwrap(library.catalog)
        let checks = library.verificationTargets().map { FileIntegrity.check($0, fileURL: library.fileURL(for: $0)!) }
        try await library.recordVerification(checks, in: catalog)
        return Dictionary(uniqueKeysWithValues: checks.map { ($0.fileName, $0.status) })
    }

    /// Overwrites one byte in the middle of the file and puts its
    /// modification date back: what a failing disk does.
    private func corrupt(_ url: URL) throws {
        let fm = FileManager.default
        let date = try XCTUnwrap(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let size = try XCTUnwrap(try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber).uint64Value
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: size / 2)
        let old = try XCTUnwrap(try handle.read(upToCount: 1))
        try handle.seek(toOffset: size / 2)
        try handle.write(contentsOf: Data([old[0] ^ 0xFF]))
        try handle.close()
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testVerifyFindsSilentCorruptionAndForgetsItOnceTheFileChanges() async throws {
        let library = try await openLibrary()
        let catalog = try XCTUnwrap(library.catalog)
        let first = try await verify(library)
        XCTAssertEqual(first, ["A.NEF": .verified, "B.NEF": .verified, "C.NEF": .verified])
        XCTAssertTrue(library.damagedImageIDs.isEmpty)
        let b = try record(library, "B.NEF")
        let verifiedAt = try await catalog.lastVerified(imageID: b.id!)
        XCTAssertNotNil(verifiedAt)

        try corrupt(folder.appendingPathComponent("B.NEF"))
        try await library.refresh()
        let second = try await verify(library)
        XCTAssertEqual(second["B.NEF"], .damaged, "same size and date, different bytes")
        XCTAssertEqual(library.damagedImageIDs, [b.id!])

        // A virtual copy shares the file, so it is badged too, and verifying
        // it reads the master's file once.
        let copies = try await library.createVirtualCopies(of: [b])
        let withCopy = try await catalog.damagedImageIDs()
        XCTAssertEqual(withCopy, [b.id!, copies[0]])
        library.setSelection([copies[0]], primary: copies[0])
        XCTAssertEqual(library.verificationTargets().map(\.fileName), ["B.NEF"])
        library.setSelection([], primary: nil)

        // Opening the folder again keeps the mark.
        try await library.refresh()
        XCTAssertTrue(library.damagedImageIDs.contains(b.id!))

        // Changed on purpose (here: appended to, so its size moved): a new
        // file as far as verification goes, until Refresh records it.
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("A.NEF"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()
        let third = try await verify(library)
        XCTAssertEqual(third["A.NEF"], .changed)

        // Restored from a backup: the size or date moves, so the damaged
        // mark stops counting as soon as reconcile sees the new file.
        let bURL = folder.appendingPathComponent("B.NEF")
        try FileManager.default.removeItem(at: bURL)
        try TestAssets.copyD750(to: bURL, variant: 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: bURL.path)
        try await library.refresh()
        XCTAssertFalse(library.damagedImageIDs.contains(b.id!))
    }

    func testMissingFileIsReportedNotDamaged() async throws {
        let library = try await openLibrary()
        let c = try record(library, "C.NEF")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("C.NEF"))
        XCTAssertEqual(FileIntegrity.check(c, fileURL: library.fileURL(for: c)!).status, .missing)
    }

    func testDuplicatesGroupIdenticalFilesButNotVirtualCopies() async throws {
        let library = try await openLibrary()
        let a = try record(library, "A.NEF"), b = try record(library, "B.NEF"), c = try record(library, "C.NEF")
        _ = try await library.createVirtualCopies(of: [a, b])
        XCTAssertEqual(library.images.count, 5)

        var groups = library.duplicateGroups()
        XCTAssertEqual(groups.exact.map { $0.records.map(\.fileName) }, [["A.NEF", "C.NEF"]])
        // C counts once, through A; B is the same moment but another file.
        XCTAssertEqual(groups.near.map { $0.records.map(\.fileName) }, [["A.NEF", "B.NEF"]])
        XCTAssertEqual(DuplicateFinder.allButFirst(groups.exact), [c.id!])

        // An edited copy is the one to keep.
        try await library.catalog!.setEditStack(#"{"exposure":0.5}"#, forImageID: c.id!)
        try await library.refresh()
        groups = library.duplicateGroups()
        XCTAssertEqual(groups.exact.first?.records.map(\.fileName), ["C.NEF", "A.NEF"])
        XCTAssertEqual(DuplicateFinder.allButFirst(groups.exact), [a.id!])
    }
}
