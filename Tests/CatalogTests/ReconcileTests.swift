import XCTest
@testable import Catalog

/// End-to-end reconciliation against a real raw file. Skips without a
/// D750 raw (see TestAssets/README.md).
final class ReconcileTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        let sample = try TestAssets.d750Path()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: sample,
                                         toPath: folder.appendingPathComponent("A.NEF").path)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testFullLifecycle() async throws {
        let catalog = try Catalog.open(at: folder)

        // New file: hashed, metadata read, inserted.
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.failures.count, 0, "\(report.failures)")
        var images = try await catalog.allImages()
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].relPath, "A.NEF")
        XCTAssertEqual(images[0].camera, "Nikon D750")
        XCTAssertEqual(images[0].width, 6032)
        XCTAssertNotNil(images[0].iso)
        XCTAssertTrue(images[0].hashString.hasPrefix("xxh64:"))

        // Nothing changed: nothing opened, nothing written.
        report = try await catalog.reconcile()
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(report.added + report.modified + report.renamed + report.removed, 0)

        // A sidecar appears (as if written by Latent or another app).
        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        try XMPSidecar.write(.init(rating: 4, label: "Green", keywords: ["test", "d750"],
                                   sourceHash: images[0].hashString), to: sidecar)
        report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 1)
        images = try await catalog.allImages()
        XCTAssertEqual(images[0].rating, 4)
        XCTAssertEqual(images[0].label, "Green")
        let keywords = try await catalog.keywords(forImageID: images[0].id!)
        XCTAssertEqual(keywords, ["d750", "test"])

        // Unchanged sidecar isn't re-read.
        report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 0)

        // Rename on disk: recognised by hash, row and sidecar follow.
        try FileManager.default.moveItem(at: folder.appendingPathComponent("A.NEF"),
                                         to: folder.appendingPathComponent("B.NEF"))
        report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.removed, 0)
        images = try await catalog.allImages()
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].relPath, "B.NEF")
        XCTAssertEqual(images[0].rating, 4, "rating survives a rename")
        let movedSidecar = await catalog.sidecarURL(forRelPath: "B.NEF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        // File deleted: row goes, sidecar stays (sidecars are truth).
        try FileManager.default.removeItem(at: folder.appendingPathComponent("B.NEF"))
        report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 1)
        let remaining = try await catalog.imageCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSidecar.path))
    }

    func testSubfolderModes() async throws {
        let sub = folder.appendingPathComponent("Day 2", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try TestAssets.d750Path(),
                                         toPath: sub.appendingPathComponent("C.NEF").path)

        let catalog = try Catalog.open(at: folder)

        // Default is `ask`: the subfolder is reported, not entered.
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.undecidedSubfolders, ["Day 2"])

        try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
        report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.undecidedSubfolders, [])
        let paths = try await catalog.allImages().map(\.relPath).sorted()
        XCTAssertEqual(paths, ["A.NEF", "Day 2/C.NEF"])

        // A subfolder with its own container is never entered.
        let own = sub.appendingPathComponent("_latent", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 1, "Day 2 became independent, its image leaves this catalog")
    }

    /// The exit criterion for Phase 2: delete the database, reopen, and
    /// everything comes back from the sidecars.
    func testRebuildFromSidecars() async throws {
        var catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let images = try await catalog.allImages()
        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        try XMPSidecar.write(.init(rating: 5, keywords: ["keep"], sourceHash: images[0].hashString,
                                   editStackJSON: #"{"schema":1}"#), to: sidecar)
        _ = try await catalog.reconcile()

        let db = await catalog.containerPath.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog.open(at: URL(fileURLWithPath: "/tmp"))   // release the old queue
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + suffix))
        }

        catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.sidecarsRead, 1)
        let rebuilt = try await catalog.allImages()
        XCTAssertEqual(rebuilt[0].rating, 5)
        let rebuiltKeywords = try await catalog.keywords(forImageID: rebuilt[0].id!)
        XCTAssertEqual(rebuiltKeywords, ["keep"])
    }

    /// Symlinks are never followed: a linked folder or file could point
    /// anywhere on the disk, and a catalog is exactly one folder.
    func testSymlinksAreSkipped() async throws {
        let fm = FileManager.default
        let outside = fm.temporaryDirectory.appendingPathComponent("latent-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.copyItem(atPath: try TestAssets.d750Path(), toPath: outside.appendingPathComponent("Elsewhere.NEF").path)
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked-dir"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("Linked.NEF"),
                                  withDestinationURL: outside.appendingPathComponent("Elsewhere.NEF"))

        let catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        let names = try await catalog.allImages().map(\.relPath)
        XCTAssertFalse(names.contains { $0.contains("linked-dir") || $0 == "Linked.NEF" }, "\(names)")
        XCTAssertFalse(report.undecidedSubfolders.contains("linked-dir"))
    }

    // MARK: - Release safety

    /// Moves root/A.NEF into an included Day2 and gives it a rating,
    /// keywords and an edit; returns the catalog and the row's id.
    private func catalogWithEditedPhotoInDay2() async throws -> (Catalog, Int64) {
        let fm = FileManager.default
        let day2 = folder.appendingPathComponent("Day2", isDirectory: true)
        try fm.createDirectory(at: day2, withIntermediateDirectories: true)
        try fm.moveItem(at: folder.appendingPathComponent("A.NEF"), to: day2.appendingPathComponent("A.NEF"))
        let catalog = try Catalog.open(at: folder)
        try await catalog.setSubfolderMode(.included, forRelPath: "Day2")
        _ = try await catalog.reconcile()
        let found = try await catalog.image(forRelPath: "Day2/A.NEF")?.id
        let id = try XCTUnwrap(found)
        try await catalog.setRating(4, forImageID: id)
        try await catalog.setKeywords(["iceland", "trip"], forImageID: id)
        try await catalog.setEditStack(#"{"schema":1,"modules":{"exposure":{"ev":0.5}}}"#, forImageID: id)
        return (catalog, id)
    }

    private func assertKeepsEverything(_ catalog: Catalog, at relPath: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let row = try await catalog.image(forRelPath: relPath)
        let id = try XCTUnwrap(row?.id, "no row at \(relPath)", file: file, line: line)
        XCTAssertEqual(row?.rating, 4, file: file, line: line)
        let keywords = try await catalog.keywords(forImageID: id)
        XCTAssertEqual(keywords, ["iceland", "trip"], file: file, line: line)
        let edit = try await catalog.editStack(forImageID: id)
        XCTAssertEqual(edit, #"{"schema":1,"modules":{"exposure":{"ev":0.5}}}"#, file: file, line: line)
    }

    /// S1: a Finder rename of an included subfolder, in the default Ask
    /// mode, used to delete its rows in the same pass (the new name is only
    /// listed as undecided), and Include brought the photos back blank.
    func testRenamedIncludedSubfolderKeepsItsPhotosUntilDecided() async throws {
        let (catalog, id) = try await catalogWithEditedPhotoInDay2()
        try FileManager.default.moveItem(at: folder.appendingPathComponent("Day2"),
                                         to: folder.appendingPathComponent("Day3"))
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.undecidedSubfolders, ["Day3"])
        XCTAssertEqual(report.removed, 0, "rows wait for the decision on Day3")
        let held = try await catalog.image(forRelPath: "Day2/A.NEF")
        XCTAssertNotNil(held)

        try await catalog.setSubfolderMode(.included, forRelPath: "Day3")
        report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1, "\(report)")
        XCTAssertEqual(report.added, 0)
        let renamedID = try await catalog.image(forRelPath: "Day3/A.NEF")?.id
        XCTAssertEqual(renamedID, id, "the row itself survives")
        try await assertKeepsEverything(catalog, at: "Day3/A.NEF")
    }

    /// S1, second guard: when the rows did go (the renamed folder was made
    /// independent first), a photo that comes back finds its orphaned
    /// sidecar by content and takes everything back from it.
    func testOrphanedSidecarIsAdoptedByTheSamePhotoUnderANewFolder() async throws {
        let (catalog, _) = try await catalogWithEditedPhotoInDay2()
        try FileManager.default.moveItem(at: folder.appendingPathComponent("Day2"),
                                         to: folder.appendingPathComponent("Day3"))
        try await catalog.setSubfolderMode(.independent, forRelPath: "Day3")
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 1)

        try await catalog.setSubfolderMode(.included, forRelPath: "Day3")
        report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        try await assertKeepsEverything(catalog, at: "Day3/A.NEF")
        let old = await catalog.sidecarURL(forRelPath: "Day2/A.NEF")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the sidecar moved, not copied")
    }

    /// S5: a file rewritten in place by another app keeps its row, and its
    /// sidecar now names the new content, so a rebuild applies it instead
    /// of setting it aside.
    func testFileChangedInPlaceRewritesItsSidecarHash() async throws {
        var catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let found = try await catalog.image(forRelPath: "A.NEF")?.id
        let id = try XCTUnwrap(found)
        try await catalog.setRating(4, forImageID: id)

        let file = folder.appendingPathComponent("A.NEF")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

        let report = try await catalog.reconcile()
        XCTAssertEqual(report.modified, 1, "\(report)")
        let changedRow = try await catalog.image(forRelPath: "A.NEF")
        let row = try XCTUnwrap(changedRow)
        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar).sourceHash, row.hashString)

        let db = await catalog.containerPath.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog.open(at: URL(fileURLWithPath: "/tmp"))   // release the old queue
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + suffix))
        }
        catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let rebuiltRating = try await catalog.image(forRelPath: "A.NEF")?.rating
        XCTAssertEqual(rebuiltRating, 4)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sidecar.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.contains("orphaned") }, "\(leftovers)")
    }

    /// S14: one included subfolder that can't be listed is a failure of
    /// that subfolder, not of the whole folder, and its rows stay.
    func testUnreadableIncludedSubfolderIsReportedAndKeepsItsRows() async throws {
        let fm = FileManager.default
        let sub = folder.appendingPathComponent("Day 2", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.moveItem(at: folder.appendingPathComponent("A.NEF"), to: sub.appendingPathComponent("C.NEF"))
        let catalog = try Catalog.open(at: folder)
        try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
        _ = try await catalog.reconcile()
        let before = try await catalog.image(forRelPath: "Day 2/C.NEF")
        XCTAssertNotNil(before)

        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: sub.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.failures.contains { $0.relPath == "Day 2" }, "\(report.failures)")
        let after = try await catalog.image(forRelPath: "Day 2/C.NEF")
        XCTAssertNotNil(after)
    }

    /// Keywords are stored without the characters XML can't hold, so the
    /// sidecar written from them reads back (#100).
    func testKeywordsAreStoredWithoutXMLIllegalCharacters() async throws {
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let found = try await catalog.image(forRelPath: "A.NEF")?.id
        let id = try XCTUnwrap(found)
        try await catalog.setKeywords(["ice\u{0B}land", "\u{0C}"], forImageID: id)
        let stored = try await catalog.keywords(forImageID: id)
        XCTAssertEqual(stored, ["iceland"])
    }

    /// An ISO no Int can hold must not trap the import.
    func testISOOutsideIntRangeIsDropped() {
        XCTAssertEqual(Catalog.isoValue(200), 200)
        XCTAssertNil(Catalog.isoValue(0))
        XCTAssertNil(Catalog.isoValue(.infinity))
        XCTAssertNil(Catalog.isoValue(.nan))
        XCTAssertNil(Catalog.isoValue(1e300))
    }
}
