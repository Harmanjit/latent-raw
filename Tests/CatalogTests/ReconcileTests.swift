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
}
