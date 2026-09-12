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
