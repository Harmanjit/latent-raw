import XCTest
@testable import Catalog

final class ExportNamingTests: XCTestCase {
    private func record(_ name: String, captured: Int64? = 1_789_321_260, camera: String? = "Nikon D750",
                        rating: Int = 3) -> ImageRecord {
        ImageRecord(id: 1, relPath: name, preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                    xxhash: Data(count: 8), captureTime: captured, camera: camera, lens: nil, lensId: nil,
                    iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                    orientation: nil, rating: rating, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    func testTokens() {
        let utc = TimeZone(identifier: "UTC")!
        let r = record("Day 2/DSC_0042.NEF")
        let ctx = ExportNaming.Context(index: 4, start: 10, padding: 3, catalogName: "Shoot")
        XCTAssertEqual(ExportNaming.fileName(template: "{name}", record: r, context: ctx, timeZone: utc), "DSC_0042")
        XCTAssertEqual(ExportNaming.fileName(template: "{date}-{seq}", record: r, context: ctx, timeZone: utc), "2026-09-13-014")
        XCTAssertEqual(ExportNaming.fileName(template: "{Camera}_{rating}star", record: r, context: ctx, timeZone: utc),
                       "NikonD750_3star", "tokens are case-insensitive")
        XCTAssertEqual(ExportNaming.fileName(template: "{folder}/{name}", record: r, context: ctx, timeZone: utc),
                       "Day 2_DSC_0042", "slashes never survive")
        XCTAssertEqual(ExportNaming.fileName(template: "{time}", record: r, context: ctx, timeZone: utc), "174100")
        // Root-level image: folder is the catalog name.
        XCTAssertEqual(ExportNaming.fileName(template: "{folder}", record: record("A.NEF"), context: ctx, timeZone: utc), "Shoot")
    }

    func testEmptyOrBadTemplateFallsBackToTheName() {
        let r = record("IMG.NEF")
        let ctx = ExportNaming.Context(index: 0)
        XCTAssertEqual(ExportNaming.fileName(template: "", record: r, context: ctx), "IMG")
        XCTAssertEqual(ExportNaming.fileName(template: "///", record: r, context: ctx), "___")
        XCTAssertEqual(ExportNaming.fileName(template: "   ", record: r, context: ctx), "IMG")
        XCTAssertEqual(ExportNaming.sanitized("..hidden:name"), "hidden_name")
    }

    func testCollisionPolicies() {
        let taken: Set<String> = ["/out/a.jpg", "/out/a-1.jpg"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        let url = URL(fileURLWithPath: "/out/a.jpg")
        XCTAssertEqual(ExportNaming.resolve(url, collision: .addNumber, exists: exists)?.path, "/out/a-2.jpg")
        XCTAssertEqual(ExportNaming.resolve(url, collision: .replace, exists: exists)?.path, "/out/a.jpg")
        XCTAssertNil(ExportNaming.resolve(url, collision: .skip, exists: exists))
        let free = URL(fileURLWithPath: "/out/b.jpg")
        XCTAssertEqual(ExportNaming.resolve(free, collision: .skip, exists: exists)?.path, "/out/b.jpg")
    }
}
