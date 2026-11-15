import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

/// `RenderOutput.coarseBlurs` (docs/Performance-Plan.md fix 25): a drag
/// tick's presence and local detail blurs come from a coarser copy. Off,
/// nothing changes; on, the picture stays close; and it only applies to
/// an edit with something to blur.
final class CoarseBlurTests: XCTestCase {
    func testDownsampleFactor() {
        XCTAssertEqual(RenderPipeline.blurDownsampleFactor(sigma: 2, limit: RenderPipeline.fullBlurSigma), 1)
        XCTAssertEqual(RenderPipeline.blurDownsampleFactor(sigma: 24, limit: RenderPipeline.fullBlurSigma), 4)
        XCTAssertEqual(RenderPipeline.blurDownsampleFactor(sigma: 4, limit: RenderPipeline.coarseBlurSigma), 2)
        XCTAssertEqual(RenderPipeline.blurDownsampleFactor(sigma: 24, limit: RenderPipeline.coarseBlurSigma), 16)
        XCTAssertEqual(RenderPipeline.blurDownsampleFactor(sigma: 500, limit: RenderPipeline.coarseBlurSigma), 16, "capped")
    }

    func testAppliesOnlyToAnEditWithBlurs() {
        var p = EditParameters()
        XCTAssertFalse(RenderPipeline.coarseBlursApply(to: p))
        p.exposureEV = 1; p.sharpenAmount = 0.5
        XCTAssertFalse(RenderPipeline.coarseBlursApply(to: p))
        p.clarity = 0.3
        XCTAssertTrue(RenderPipeline.coarseBlursApply(to: p))
        var local = EditParameters()
        var radial = LocalAdjustment(name: "r", shape: .radial(centre: [0.5, 0.5], radii: [0.3, 0.3], feather: 0.5))
        radial.clarity = 0.4
        local.locals = [radial]
        XCTAssertTrue(RenderPipeline.coarseBlursApply(to: local))
    }

    func testCoarseRenderStaysCloseAndOffIsUnchanged() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.whiteBalance = session.asShotWhiteBalance
        p.clarity = 0.4; p.texture = 0.3; p.dehaze = 0.2
        var radial = LocalAdjustment(name: "r", shape: .radial(centre: [0.5, 0.5], radii: [0.3, 0.3], feather: 0.5))
        radial.clarity = 0.5
        p.locals = [radial]
        let scale = RenderScale.region(x: 2000, y: 1500, width: 1024, height: 768)
        let base = RenderOutput.edrDisplay(headroom: 1)
        func pixels(_ output: RenderOutput) throws -> [Float16] {
            try TextureReadback.float16Pixels(of: try pipeline.render(session, scale: scale, parameters: p, output: output), gpu: gpu)
        }
        let full = try pixels(base)
        var coarse = base
        coarse.coarseBlurs = true
        let draft = try pixels(coarse)
        XCTAssertEqual(try pixels(base), full, "off is the full render")
        XCTAssertNotEqual(draft, full, "the draft takes the coarser blurs")
        XCTAssertEqual(draft.count, full.count)
        var sum: Double = 0, worst: Float = 0
        for i in full.indices where i % 4 != 3 {
            let d = abs(Float(draft[i]) - Float(full[i]))
            sum += Double(d); worst = max(worst, d)
        }
        let mean = sum / Double(full.count / 4 * 3)
        print(String(format: "coarse blurs: mean %.5f, worst %.4f", mean, worst))
        XCTAssertLessThan(mean, 0.01, "a drag shows nearly the same picture")
    }
}
