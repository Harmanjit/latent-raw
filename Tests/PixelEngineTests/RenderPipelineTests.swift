import XCTest
@testable import PixelEngine
@testable import RawCore
import ColorKit

// Render sanity checks on real sample files, which aren't committed (see
// TestAssets/README.md); they skip until the files are dropped in locally.
// Pixel-exact comparisons against references are in GoldenImageTests.
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
    /// own border (where RCD mirrors its reads instead of seeing the pixels outside).
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
        let margin = 11   // how far in RCD's reads past the edge can reach
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

    /// Exposure changes must reuse the demosaic; white balance changes
    /// must not (the multipliers feed the demosaic input).
    func testStageCacheSkipsDemosaicWhenOnlyToneChanges() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop a D750 NEF at \(path) — see TestAssets/README.md")

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let scale = RenderScale.region(x: 1000, y: 800, width: 512, height: 384)

        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        var params = EditParameters()

        _ = try pipeline.render(session, scale: scale, parameters: params, info: &info)
        XCTAssertFalse(info.demosaicWasCached, "first render can't be cached")

        params.exposureEV = 1.0
        _ = try pipeline.render(session, scale: scale, parameters: params, info: &info)
        XCTAssertTrue(info.demosaicWasCached, "exposure doesn't touch the demosaic")

        params.whiteBalance = ColorKit.WhiteBalance(temperature: 4000, tint: 0)
        _ = try pipeline.render(session, scale: scale, parameters: params, info: &info)
        XCTAssertFalse(info.demosaicWasCached, "white balance changes the demosaic input")

        // A different region misses too, even with identical parameters.
        let elsewhere = RenderScale.region(x: 2000, y: 800, width: 512, height: 384)
        _ = try pipeline.render(session, scale: elsewhere, parameters: params, info: &info)
        XCTAssertFalse(info.demosaicWasCached)

        // Back to the first region: its texture was overwritten by the
        // second (same size, same pool slot), so the cache must know that.
        params.exposureEV = 2.0
        _ = try pipeline.render(session, scale: scale, parameters: params, info: &info)
        XCTAssertFalse(info.demosaicWasCached, "stale entry must have been evicted")
    }

    /// EDR output must exceed 1.0 where the scene is bright, never exceed
    /// the headroom, and leave the file path bounded at 1.0.
    func testEDROutputUsesHeadroom() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop a D750 NEF at \(path) — see TestAssets/README.md")

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let scale = RenderScale.binned(quads: 4)
        // Push exposure so the sky definitely clears paper white.
        var params = EditParameters()
        params.exposureEV = 2

        func maxComponent(_ output: RenderOutput) throws -> Float {
            let tex = try pipeline.render(session, scale: scale, parameters: params, output: output)
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            var m: Float = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                m = max(m, Float(px[i]), Float(px[i + 1]), Float(px[i + 2]))
            }
            return m
        }

        let sdr = try maxComponent(.file(.sRGB))
        XCTAssertLessThanOrEqual(sdr, 1.0)

        let edr = try maxComponent(.edrDisplay(headroom: 2))
        XCTAssertGreaterThan(edr, 1.0, "bright scene should use the headroom")
        XCTAssertLessThanOrEqual(edr, 2.0 + 1e-3, "never above the headroom")
    }

    /// Every pixel lands in exactly one bin of each scope, so the totals
    /// must equal the pixel count — the cheapest check that the binning
    /// arithmetic isn't dropping or double-counting anything.
    func testScopesCountEveryPixelOnce() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                           "Drop a D750 NEF at \(path) — see TestAssets/README.md")

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let scopes = try ScopeCalculator(gpu: gpu)

        let tex = try pipeline.render(session, scale: .binned(quads: 4),
                                      parameters: .neutral, output: .edrDisplay(headroom: 2))
        let pixels = UInt64(tex.width * tex.height)

        let wave = try XCTUnwrap(scopes.computeWaveform(from: tex, inputIsLinear: true))
        for channel in [wave.red, wave.green, wave.blue] {
            XCTAssertEqual(channel.reduce(UInt64(0)) { $0 + UInt64($1) }, pixels)
        }
        XCTAssertGreaterThan(wave.peak, 0)

        let vector = try XCTUnwrap(scopes.computeVectorscope(from: tex, inputIsLinear: true))
        XCTAssertEqual(vector.counts.reduce(UInt64(0)) { $0 + UInt64($1) }, pixels)

        // A real photo is mostly low-saturation: the centre of the
        // vectorscope should hold far more than a corner.
        let n = Vectorscope.size
        let centre = vector.counts[(n / 2) * n + n / 2]
        let corner = vector.counts[0]
        XCTAssertGreaterThan(centre, corner)
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
