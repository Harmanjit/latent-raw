import XCTest
@testable import Catalog

/// Rating, flag, rotation and keywords: written to the row and the
/// sidecar, not re-read on the next reconcile, and recoverable from the
/// sidecar alone.
final class MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawhead-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                         toPath: folder.appendingPathComponent("A.NEF").path)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testEditsWriteSidecarAndSurviveRebuild() async throws {
        var catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let firstImage = try await catalog.allImages().first
        let id = try XCTUnwrap(firstImage?.id)

        try await catalog.setRating(4, forImageID: id)
        try await catalog.setFlag(.picked, forImageID: id)
        try await catalog.setUserRotation(5, forImageID: id)          // normalizes to 1
        try await catalog.setKeywords([" mountains", "sunset ", ""], forImageID: id)

        // The sidecar says what the row says.
        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        let fields = try XMPSidecar.read(from: sidecar)
        XCTAssertEqual(fields.rating, 4)
        XCTAssertEqual(fields.flag, ImageFlag.picked.rawValue)
        XCTAssertEqual(fields.rotation, 1)
        XCTAssertEqual(fields.keywords, ["mountains", "sunset"])

        // Reconcile sees the sidecar as already applied.
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 0)
        let maybeRow = try await catalog.image(forRelPath: "A.NEF")
        let row = try XCTUnwrap(maybeRow)
        XCTAssertEqual(row.rating, 4)
        XCTAssertEqual(row.flag, 1)
        XCTAssertEqual(row.userRotation, 1)

        // Delete the database; everything comes back from the sidecar.
        let db = await catalog.containerPath.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog.open(at: URL(fileURLWithPath: "/tmp"))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + suffix))
        }
        catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let maybeRebuilt = try await catalog.image(forRelPath: "A.NEF")
        let rebuilt = try XCTUnwrap(maybeRebuilt)
        XCTAssertEqual(rebuilt.rating, 4)
        XCTAssertEqual(rebuilt.flag, 1)
        XCTAssertEqual(rebuilt.userRotation, 1)
        let keywords = try await catalog.keywords(forImageID: rebuilt.id!)
        XCTAssertEqual(keywords, ["mountains", "sunset"])
    }

    func testEditStackRoundTripsThroughSidecar() async throws {
        var catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let firstImage = try await catalog.allImages().first
        let id = try XCTUnwrap(firstImage?.id)

        let json = #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}"#
        try await catalog.setEditStack(json, forImageID: id)
        let stored = try await catalog.editStack(forImageID: id)
        XCTAssertEqual(stored, json)
        let edited = try await catalog.editedImageIDs()
        XCTAssertEqual(edited, [id])

        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar).editStackJSON, json)

        // Rebuild from the sidecar alone.
        let db = await catalog.containerPath.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog.open(at: URL(fileURLWithPath: "/tmp"))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + suffix))
        }
        catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let rebuiltImage = try await catalog.image(forRelPath: "A.NEF")
        let rebuiltID = try XCTUnwrap(rebuiltImage?.id)
        let rebuiltJSON = try await catalog.editStack(forImageID: rebuiltID)
        XCTAssertEqual(rebuiltJSON, json)

        // Clearing removes the row and the sidecar's stack.
        try await catalog.setEditStack(nil, forImageID: rebuiltID)
        let cleared = try await catalog.editStack(forImageID: rebuiltID)
        XCTAssertNil(cleared)
        XCTAssertEqual(try XMPSidecar.read(from: sidecar).editStackJSON, "")
    }

    func testSnapshotsAndHistorySurviveSidecarRebuild() async throws {
        var catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let firstImage = try await catalog.allImages().first
        let id = try XCTUnwrap(firstImage?.id)

        let s1 = #"{"schema":1,"modules":{"exposure":{"ev":0.5}}}"#
        let s2 = #"{"schema":1,"modules":{"exposure":{"ev":-0.5}}}"#
        try await catalog.setSnapshots([("Bright", s1), ("Dark", s2)], forImageID: id)
        try await catalog.setHistory([(s1, 100), (s2, 200)], forImageID: id)

        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        let fields = try XMPSidecar.read(from: sidecar)
        XCTAssertTrue(fields.snapshotsJSON.contains("\"Bright\""))
        XCTAssertTrue(fields.historyJSON.contains("\"t\":200"))

        let db = await catalog.containerPath.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog.open(at: URL(fileURLWithPath: "/tmp"))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + suffix))
        }
        catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let rebuiltImage = try await catalog.image(forRelPath: "A.NEF")
        let rid = try XCTUnwrap(rebuiltImage?.id)
        let snaps = try await catalog.snapshots(forImageID: rid)
        XCTAssertEqual(snaps.map(\.name), ["Bright", "Dark"])
        XCTAssertTrue(snaps[0].stackJSON.contains("0.5"))
        let hist = try await catalog.history(forImageID: rid)
        XCTAssertEqual(hist.count, 2)
        XCTAssertEqual(hist[1].createdAt, 200)
    }

    @MainActor
    func testLibraryAppliesToSelection() async throws {
        let library = Library()
        try await library.open(folder: folder)
        XCTAssertEqual(library.selectNext()?.relPath, "A.NEF")

        try await library.setRating(3)
        try await library.rotateSelected(by: -1)
        try await library.setKeywords(["x"])
        XCTAssertEqual(library.selectedImage?.rating, 3)
        XCTAssertEqual(library.selectedImage?.userRotation, 3, "-1 wraps to 3")
        XCTAssertEqual(library.selectedKeywords, ["x"])
    }
}
