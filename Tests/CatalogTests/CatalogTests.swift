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
}
