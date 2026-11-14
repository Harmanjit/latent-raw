import XCTest
import GRDB
@testable import Catalog

/// What `latent-cli export` reads for each photo: the catalog's edit when
/// the folder has a database, the sidecar's when it has only sidecars.
final class HeadlessSourcesTests: XCTestCase {
    private var folder: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: folder)
    }

    private func touch(_ name: String) throws {
        try Data("not really a photo".utf8).write(to: folder.appendingPathComponent(name))
    }

    func testFolderWithoutCatalogReadsSidecarsAndLeavesOutCompanions() async throws {
        for name in ["b.cr2", "a.nef", "a.jpg", "notes.txt", ".hidden.nef"] { try touch(name) }
        let xmp = folder.appendingPathComponent("_latent/xmp")
        try fm.createDirectory(at: xmp, withIntermediateDirectories: true)
        var fields = XMPSidecar.Fields(rating: 4, rotation: 1, keywords: ["harbour"], sourceHash: "xxh64:0",
                                       editStackJSON: #"{"schema":1}"#)
        fields.title = "Evening"
        try XMPSidecar.write(fields, to: xmp.appendingPathComponent("b.cr2.xmp"))

        let resolved = try await HeadlessSources.resolve([folder])
        XCTAssertEqual(resolved.sources.map(\.record.relPath), ["a.nef", "b.cr2"])
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("_latent/catalog.sqlite").path),
                       "no catalog is created")
        XCTAssertTrue(resolved.notes.contains { $0.contains("RAW+JPEG") })

        let a = resolved.sources[0], b = resolved.sources[1]
        XCTAssertEqual(a.origin, .none)
        XCTAssertNil(a.editStackJSON)
        XCTAssertEqual(b.origin, .sidecar)
        XCTAssertEqual(b.editStackJSON, #"{"schema":1}"#)
        XCTAssertEqual(b.keywords, ["harbour"])
        XCTAssertEqual(b.record.rating, 4)
        XCTAssertEqual(b.record.userRotation, 1)
        XCTAssertEqual(b.record.title, "Evening")
        XCTAssertEqual(b.fileURL.lastPathComponent, "b.cr2")
    }

    func testFolderWithCatalogReadsTheDatabase() async throws {
        try touch("c.nef")
        do {
            let catalog = try Catalog.open(at: folder)
            // Not reconciled: the file isn't a real raw, so it is put in
            // the database directly.
            let file = folder.appendingPathComponent("c.nef")
            let id = try await catalog.dbQueue.write { db -> Int64 in
                var record = HeadlessSources.standaloneRecord(for: file, relPath: "c.nef")
                try record.insert(db)
                return record.id ?? -1
            }
            try await catalog.setEditStack(#"{"from":"catalog"}"#, forImageID: id)
            try await catalog.setRating(2, forImageID: id)
        }
        let resolved = try await HeadlessSources.resolve([folder])
        XCTAssertEqual(resolved.sources.count, 1)
        let c = try XCTUnwrap(resolved.sources.first)
        XCTAssertEqual(c.origin, .catalog)
        XCTAssertEqual(c.editStackJSON, #"{"from":"catalog"}"#)
        XCTAssertEqual(c.record.rating, 2)
        XCTAssertEqual(c.root.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testFilesAreResolvedOnceAndNonPhotosAreNoted() async throws {
        for name in ["d.nef", "readme.md"] { try touch(name) }
        let d = folder.appendingPathComponent("d.nef")
        let resolved = try await HeadlessSources.resolve([d, d, folder.appendingPathComponent("readme.md")])
        XCTAssertEqual(resolved.sources.map(\.record.relPath), ["d.nef"])
        XCTAssertTrue(resolved.notes.contains { $0.contains("readme.md") })
    }

    func testMissingPathFails() async {
        do {
            _ = try await HeadlessSources.resolve([folder.appendingPathComponent("gone.nef")])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("gone.nef"))
        }
    }
}
