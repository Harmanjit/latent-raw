import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The tone equalizer's stage on a real D750 raw (the golden one on CI):
/// off is exactly off, the gain is colour-neutral and goes where the bands
/// say, and a 100 % tile reads the same whole-image mask as the preview.
final class ToneEqualizerRenderTests: XCTestCase {
    private var gpu: GPUContext!
    private var file: RawFile!
    private var session: ImageSession!
    private var pipeline: RenderPipeline!

    private static let region = RenderScale.region(x: 2000, y: 1500, width: 384, height: 256)

    override func setUpWithError() throws {
        let path = try TestAssets.d750Path()
        gpu = try GPUContext()
        file = try RawFile(path: path)
        session = try ImageSession(file: file, gpu: gpu)
        pipeline = RenderPipeline(gpu: gpu)
    }

    private struct Image {
        var pixels: [Float16]
        var width: Int, height: Int
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
        }
        func luma(_ x: Int, _ y: Int) -> Float { simd_dot(rgb(x, y), SIMD3(0.2627, 0.6780, 0.0593)) }
        var meanLuma: Float {
            var s: Float = 0
            for y in 0..<height { for x in 0..<width { s += luma(x, y) } }
            return s / Float(width * height)
        }
    }

    private func render(_ p: EditParameters, scale: RenderScale = ToneEqualizerRenderTests.region,
                        output: RenderOutput = .file(.sRGB), in session: ImageSession? = nil,
                        info: UnsafeMutablePointer<RenderInfo>? = nil) throws -> Image {
        let tex = try pipeline.render(session ?? self.session, scale: scale, parameters: p, output: output, info: info)
        return Image(pixels: try TextureReadback.float16Pixels(of: tex, gpu: gpu), width: tex.width, height: tex.height)
    }

    private var lifted: EditParameters {
        var p = EditParameters()
        p.toneEqualizer = ToneEqualizer(bands: [1.5, 1.5, 1.5, 1.2, 0.8, 0.4, 0, 0, 0])
        return p
    }

    // MARK: - Off is off

    func testNeutralAndAnalysisLeaveThePictureAlone() throws {
        let plain = try render(EditParameters())
        var output = RenderOutput.file(.sRGB)
        output.toneEqualizerAnalysis = true
        let analysed = try render(EditParameters(), output: output)
        XCTAssertEqual(plain.pixels, analysed.pixels, "working out the mask changes no pixel")
        XCTAssertNotNil(session.toneEqualizerMask, "but it is made, for the panel")
        // Mask settings alone, every band at 0: still nothing.
        var p = EditParameters()
        p.toneEqualizer.maskExposure = 2
        p.toneEqualizer.smoothing = 0.9
        XCTAssertEqual(try render(p).pixels, plain.pixels)
    }

    // MARK: - What it does

    func testLiftingTheShadowsBrightensAndKeepsColour() throws {
        let before = try render(EditParameters(), output: .sceneLinear)
        let after = try render(lifted, output: .sceneLinear)
        XCTAssertGreaterThan(after.meanLuma, before.meanLuma * 1.05)
        // A gain on all three channels: a dark pixel's chromaticity stays.
        var checked = 0
        for y in stride(from: 0, to: before.height, by: 7) {
            for x in stride(from: 0, to: before.width, by: 7) {
                let a = before.rgb(x, y), b = after.rgb(x, y)
                guard before.luma(x, y) > 0.002, before.luma(x, y) < 0.2, a.min() > 0.0005 else { continue }
                let ra = a / simd_reduce_add(a), rb = b / simd_reduce_add(b)
                XCTAssertEqual(ra.x, rb.x, accuracy: 0.01)
                XCTAssertEqual(ra.z, rb.z, accuracy: 0.01)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testDarkeningTheHighlightsLeavesTheShadows() throws {
        var p = EditParameters()
        p.toneEqualizer = ToneEqualizer(bands: [0, 0, 0, 0, 0, -0.5, -1.5, -2, -2])
        let before = try render(EditParameters(), scale: .binned(quads: 8), output: .sceneLinear)
        let after = try render(p, scale: .binned(quads: 8), output: .sceneLinear)
        XCTAssertLessThan(after.meanLuma, before.meanLuma)
        // The darkest pixels barely move.
        var darkBefore: Float = 0, darkAfter: Float = 0
        for y in 0..<before.height { for x in 0..<before.width where before.luma(x, y) < 0.004 {
            darkBefore += before.luma(x, y); darkAfter += after.luma(x, y)
        } }
        XCTAssertGreaterThan(darkBefore, 0)
        XCTAssertEqual(darkAfter / darkBefore, 1, accuracy: 0.1)
    }

    // MARK: - One mask for the whole image

    /// A tile in a session that never rendered the whole image makes the
    /// mask itself; the result matches a tile in a session whose preview
    /// made it first.
    func testTileMatchesWhetherOrNotThePreviewCameFirst() throws {
        _ = try render(lifted, scale: .binned(quads: 4))
        let afterPreview = try render(lifted)
        let fresh = try ImageSession(file: file, gpu: gpu)
        let alone = try render(lifted, in: fresh)
        XCTAssertNotNil(fresh.toneEqualizerMask)
        var diff: Float = 0
        for i in stride(from: 0, to: afterPreview.pixels.count, by: 4) {
            diff += abs(Float(afterPreview.pixels[i + 1]) - Float(alone.pixels[i + 1]))
        }
        XCTAssertLessThan(diff / Float(afterPreview.pixels.count / 4), 0.01)
    }

    /// The gain a tile gets is the gain the preview shows there.
    func testTileGainMatchesThePreview() throws {
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
        let previewBefore = try render(EditParameters(), scale: .binned(quads: 4), output: .sceneLinear, info: &info)
        let previewAfter = try render(lifted, scale: .binned(quads: 4), output: .sceneLinear)
        let tileBefore = try render(EditParameters(), output: .sceneLinear)
        let tileAfter = try render(lifted, output: .sceneLinear)
        // The tile's rectangle in preview pixels.
        let span = 8
        let x0 = 2000 / span, y0 = 1500 / span, w = 384 / span, h = 256 / span
        var pb: Float = 0, pa: Float = 0
        for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { pb += previewBefore.luma(x, y); pa += previewAfter.luma(x, y) } }
        let previewGain = pa / pb
        let tileGain = tileAfter.meanLuma / tileBefore.meanLuma
        XCTAssertGreaterThan(previewGain, 1.02, "the region is lifted at all")
        XCTAssertEqual(tileGain, previewGain, accuracy: previewGain * 0.04)
    }

    // MARK: - Show Mask

    func testShowMaskIsGreyAndTheSnapshotReadsIt() throws {
        var output = RenderOutput.edrDisplay(headroom: 1)
        output.toneEqualizerMaskView = true
        let shown = try render(lifted, scale: .binned(quads: 8), output: output)
        let c = shown.rgb(shown.width / 2, shown.height / 2)
        XCTAssertEqual(c.x, c.y, accuracy: 1e-3)
        XCTAssertEqual(c.y, c.z, accuracy: 1e-3)
        let snapshot = try XCTUnwrap(session.toneEqualizerMask)
        XCTAssertEqual(snapshot.values.count, snapshot.width * snapshot.height)
        XCTAssertEqual(max(snapshot.width, snapshot.height), ToneEqualizerStage.gridLongSide)
        let centre = try XCTUnwrap(snapshot.maskEV(atNormalized: SIMD2(0.5, 0.5)))
        XCTAssertTrue((-16...4).contains(centre), "\(centre)")
    }
}
