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

    /// The region path must produce exactly the same pixels as the
    /// corresponding crop of a whole-image render, away from the region's
    /// own border (where RCD's clamped edge reads legitimately differ).
    /// This is what makes tiled 100% zoom trustworthy: the tile isn't an
    /// approximation of the export, it *is* the export, cropped.
    func testRegionRenderMatchesFullResolutionCrop() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop a D750 NEF at \(path) — see TestAssets/README.md")

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        // Odd origin on purpose: the pipeline must snap it to even.
        let requested = (x: 1001, y: 803, w: 512, h: 384)

        let full = try pipeline.render(session, scale: .full, parameters: .neutral)
        let fullPixels = try TextureReadback.float16Pixels(of: full, gpu: gpu)

        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        let region = try pipeline.render(
            session,
            scale: .region(x: requested.x, y: requested.y, width: requested.w, height: requested.h),
            parameters: .neutral, info: &info)
        let regionPixels = try TextureReadback.float16Pixels(of: region, gpu: gpu)

        XCTAssertTrue(info.isFullResolution)
        XCTAssertEqual(Int(info.sensorRect.origin.x), 1000, "origin should snap down to even")
        XCTAssertEqual(Int(info.sensorRect.origin.y), 802)
        XCTAssertEqual(region.width, requested.w)
        XCTAssertEqual(region.height, requested.h)

        let ox = Int(info.sensorRect.origin.x), oy = Int(info.sensorRect.origin.y)
        let margin = 8   // RCD reaches 4 pixels out; be generous
        var maxDiff: Float = 0
        for y in margin..<(region.height - margin) {
            for x in margin..<(region.width - margin) {
                let r = (y * region.width + x) * 4
                let f = ((y + oy) * full.width + (x + ox)) * 4
                for c in 0..<3 {
                    maxDiff = max(maxDiff, abs(Float(regionPixels[r + c]) - Float(fullPixels[f + c])))
                }
            }
        }
        XCTAssertLessThanOrEqual(maxDiff, 1e-3,
                                 "region interior differs from the full render by \(maxDiff)")
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
