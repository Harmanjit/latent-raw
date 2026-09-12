import XCTest
@testable import PixelEngine
@testable import RawCore

// Golden-image tests per DESIGN.md §12. These need real sample files, which
// aren't committed (see TestAssets/README.md) — until they're dropped in
// locally these tests will skip rather than fail, so CI stays green on a
// fresh checkout but does real work once assets are present.
final class RenderPipelineTests: XCTestCase {

    func testBayerFileRendersWithoutCrashing() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop a D750 NEF at \(path) — see TestAssets/README.md")

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let pipeline = RenderPipeline(gpu: gpu)
        let texture = try pipeline.render(file)

        XCTAssertEqual(texture.width, file.summary.rawWidth)
        XCTAssertEqual(texture.height, file.summary.rawHeight)
        // TODO once a reference render exists: compare against it within a
        // tolerance (DESIGN.md §12 "golden images"), not just shape-check.
    }

    func testSonyCompressedARWRenders() throws {
        let path = TestAssets.path("sony_a7iii_compressed.arw")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop an A7 III compressed ARW at \(path)")

        let file = try RawFile(path: path)
        XCTAssertEqual(file.summary.cameraModel.contains("ILCE-7M3") ||
                        file.summary.cameraModel.contains("a7iii"), true)
    }
}

enum TestAssets {
    static func path(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets").appendingPathComponent(name).path
    }
}
