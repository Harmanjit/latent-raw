import XCTest
@testable import Catalog

/// The `lens_overrides` table: a choice is stored, replaced, removed, and
/// survives reopening the catalog; each change reports what it replaced,
/// which is what undo puts back.
final class LensOverrideCatalogTests: XCTestCase {
    func testChoicesAreStoredReplacedAndRemoved() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let catalog = try Catalog.open(at: tmp)
        let empty = try await catalog.lensOverrides()
        XCTAssertEqual(empty, [])

        let first = try await catalog.exchangeLensOverride("Lens A", camera: "Nikon D750", lensID: "35mm")
        XCTAssertNil(first, "nothing was there")
        let second = try await catalog.exchangeLensOverride("Lens B", camera: "Nikon D750", lensID: "35mm")
        XCTAssertEqual(second, "Lens A")
        try await catalog.exchangeLensOverride("Lens C", camera: "Nikon D750", lensID: "50mm")
        let rows = try await catalog.lensOverrides()
        XCTAssertEqual(rows, [LensOverrideRow(camera: "Nikon D750", lensID: "35mm", lensfunModel: "Lens B"),
                              LensOverrideRow(camera: "Nikon D750", lensID: "50mm", lensfunModel: "Lens C")])

        // Undo puts back what the change replaced; nil removes the row.
        let removed = try await catalog.exchangeLensOverride(nil, camera: "Nikon D750", lensID: "50mm")
        XCTAssertEqual(removed, "Lens C")

        let reopened = try Catalog.open(at: tmp)
        let kept = try await reopened.lensOverrides()
        XCTAssertEqual(kept, [LensOverrideRow(camera: "Nikon D750", lensID: "35mm", lensfunModel: "Lens B")])
    }
}
