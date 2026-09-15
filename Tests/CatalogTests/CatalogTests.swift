import XCTest
@testable import Catalog

final class CatalogTests: XCTestCase {
    func testOpenCreatesContainerLayout() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let catalog = try Catalog.open(at: tmp)
        let container = tmp.appendingPathComponent("_latent")

        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("catalog.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("xmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("thumbnails").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(".metadata_never_index").path))
        _ = catalog
    }

    /// A folder catalogued before the rename has a `_rawhead/` container.
    /// Opening it must adopt that folder rather than start an empty one.
    func testOpenAdoptsLegacyContainer() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Build a catalog, then rename its container to the old name.
        _ = try Catalog.open(at: tmp)
        let new = tmp.appendingPathComponent(Catalog.containerName)
        let old = tmp.appendingPathComponent(Catalog.legacyContainerName)
        let marker = "sentinel"
        try marker.write(to: new.appendingPathComponent("xmp/marker.xmp"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: new, to: old)

        _ = try Catalog.open(at: tmp)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "legacy container should be gone")
        let kept = try String(contentsOf: new.appendingPathComponent("xmp/marker.xmp"), encoding: .utf8)
        XCTAssertEqual(kept, marker, "contents must survive the rename")
    }

    /// A database SQLite can't read is moved aside with its journal files
    /// and a fresh one takes its place; nothing is deleted.
    func testDamagedDatabaseIsSetAsideAndRebuilt() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        do {
            let catalog = try Catalog.open(at: tmp)
            try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
            XCTAssertNil(catalog.damagedDatabaseSetAside)
        }
        let container = tmp.appendingPathComponent(Catalog.containerName)
        let database = container.appendingPathComponent("catalog.sqlite")
        let garbage = Data(repeating: 0x5A, count: 8192)
        try garbage.write(to: database)
        try Data("stale journal".utf8).write(to: URL(fileURLWithPath: database.path + "-wal"))

        do {
            let reopened = try Catalog.open(at: tmp)
            let aside = try XCTUnwrap(reopened.damagedDatabaseSetAside)
            XCTAssertTrue(aside.lastPathComponent.hasPrefix("catalog.damaged-"), aside.lastPathComponent)
            XCTAssertEqual(aside.pathExtension, "sqlite")
            XCTAssertEqual(try Data(contentsOf: aside), garbage, "the damaged file is kept as it was")
            XCTAssertTrue(fm.fileExists(atPath: aside.path + "-wal"), "its journal goes with it")
            let choice = try await reopened.subfolderMode(forRelPath: "Day 2")
            XCTAssertNil(choice, "the fresh database starts without subfolder choices")
            let count = try await reopened.imageCount()
            XCTAssertEqual(count, 0)
        }

        // Opening again is ordinary: nothing more is set aside.
        XCTAssertNil(try Catalog.open(at: tmp).damagedDatabaseSetAside)
    }

    /// The point of setting the database aside: ratings and edits come back
    /// from the sidecars on the next reconcile.
    func testRebuiltCatalogRecoversSidecarMetadata() async throws {
        let sample = try TestAssets.d750Path()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(atPath: sample, toPath: tmp.appendingPathComponent("A.NEF").path)

        do {
            let catalog = try Catalog.open(at: tmp)
            _ = try await catalog.reconcile()
            let images = try await catalog.allImages()
            let id = try XCTUnwrap(images.first?.id)
            try await catalog.setRating(4, forImageID: id)
            try await catalog.setKeywords(["rome"], forImageID: id)
        }
        let database = tmp.appendingPathComponent("\(Catalog.containerName)/catalog.sqlite")
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: database.path + suffix) }
        try Data("not a database at all".utf8).write(to: database)

        let rebuilt = try Catalog.open(at: tmp)
        XCTAssertNotNil(rebuilt.damagedDatabaseSetAside)
        let report = try await rebuilt.reconcile()
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.sidecarsRead, 1)
        let images = try await rebuilt.allImages()
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image.rating, 4)
        let keywords = try await rebuilt.keywords(forImageID: image.id!)
        XCTAssertEqual(keywords, ["rome"])
    }
}
