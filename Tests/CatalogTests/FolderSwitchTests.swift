import XCTest
@testable import Catalog

/// Saves that land after another folder has opened. The editor hands an
/// edit over by catalog id, and the write runs a moment later; in the
/// next folder's catalog that id is a different photo.
@MainActor
final class FolderSwitchTests: XCTestCase {
    nonisolated(unsafe) var first: URL!
    nonisolated(unsafe) var second: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("latent-switch-\(UUID().uuidString)", isDirectory: true)
        first = base.appendingPathComponent("First", isDirectory: true)
        second = base.appendingPathComponent("Second", isDirectory: true)
        for (folder, name) in [(first!, "A.NEF"), (second!, "Z.NEF")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: ReconcileTests.sampleNEF, toPath: folder.appendingPathComponent(name).path)
        }
    }

    override func tearDownWithError() throws {
        if let first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    }

    func testEditSavedAfterASwitchLandsInItsOwnCatalog() async throws {
        let library = Library()
        try await library.open(folder: first)
        let oldCatalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first)

        try await library.open(folder: second)
        let z = try XCTUnwrap(library.images.first)
        XCTAssertEqual(a.id, z.id, "the hazard: each catalog's first image has the same id")

        let json = "{\"schema\":1}"
        try await library.saveEditStack(json, schemaVersion: 1, processVersion: "1.0", forImageID: a.id!, in: oldCatalog)
        try await library.setHistory([(json, 1)], forImageID: a.id!, in: oldCatalog)
        try await library.setSnapshots([("Look", json)], forImageID: a.id!, in: oldCatalog)

        let stored = try await oldCatalog.editStack(forImageID: a.id!)
        XCTAssertEqual(stored, json)
        let history = try await oldCatalog.history(forImageID: a.id!)
        XCTAssertEqual(history.count, 1)
        let untouched = try await library.editStack(for: z)
        XCTAssertNil(untouched, "the open catalog's photo with the same id is left alone")
        let snapshots = try await library.snapshots(for: z)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertFalse(library.editedImageIDs.contains(z.id!), "the grid's edited badges follow the open catalog")
    }
}
