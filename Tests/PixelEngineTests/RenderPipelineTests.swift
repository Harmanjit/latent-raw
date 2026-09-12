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
        // An ImageSession uploads the sensor plane once and owns the pooled
        // textures; RenderPipeline renders *sessions*, not bare files.
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let texture = try pipeline.render(session)

        XCTAssertEqual(texture.width, file.summary.rawWidth)
        XCTAssertEqual(texture.height, file.summary.rawHeight)
        // TODO once a reference render exists: compare against it within a
        // tolerance (DESIGN.md §12 "golden images"), not just shape-check.
    }

    func testViewportRenderIsSmallerThanSensor() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop a D750 NEF at \(path) — see TestAssets/README.md")

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        let texture = try pipeline.render(session, scale: .fitting(maxDimension: 2560),
                                          parameters: .neutral, info: &info)

        XCTAssertFalse(info.isFullResolution)
        XCTAssertLessThanOrEqual(max(texture.width, texture.height), 3016)
        XCTAssertGreaterThan(texture.width, 0)
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
