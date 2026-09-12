import XCTest
@testable import Catalog

final class CatalogTests: XCTestCase {
    func testOpenCreatesContainerLayout() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let catalog = try Catalog.open(at: tmp)
        let container = tmp.appendingPathComponent("_rawhead")

        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("catalog.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("xmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent("thumbnails").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(".metadata_never_index").path))
        _ = catalog
    }
}
