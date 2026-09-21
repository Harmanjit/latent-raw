import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// Stage 5 through the whole pipeline with the dust list: the full 200
/// spots render, and they are healed before the touch-up blemishes and
/// the user's patches, so a later patch reads the dust-healed image
/// (docs/Retouch.md §4). On the 1200 x 800 ramp fixture, whose pixels are
/// known: a clone patch copies exactly, so what a patch reads shows in
/// what it writes.
final class DustRenderTests: XCTestCase {
    private func openRamp() throws -> (GPUContext, ImageSession, RenderPipeline) {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.ramp)), gpu: gpu)
        return (gpu, session, RenderPipeline(gpu: gpu))
    }

    /// A pixel lookup on a scene-linear render.
    private func rendered(_ p: EditParameters, scale: RenderScale = .full, session: ImageSession, pipeline: RenderPipeline,
                          gpu: GPUContext) throws -> (at: (Int, Int) -> SIMD3<Float>, info: RenderInfo) {
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        let texture = try pipeline.render(session, scale: scale, parameters: p, output: .sceneLinear, info: &info)
        let px = try TextureReadback.float16Pixels(of: texture, gpu: gpu)
        let w = texture.width, h = texture.height
        return ({ x, y in
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
            return SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]))
        }, info)
    }

    /// A hard-edged clone from `source` onto `target` (fixture pixels).
    private func clone(_ target: SIMD2<Float>, from source: SIMD2<Float>, radius: Float = 16) -> HealPatch {
        HealPatch(target: target / SIMD2(1200, 800), source: source / SIMD2(1200, 800), radius: radius / 800, feather: 0, mode: .clone)
    }

    /// 200 clones of the fixture's flat patch onto the ramp, on a grid: all
    /// 200 land, at full resolution and binned, and nothing between them
    /// moves.
    func testTwoHundredDustSpotsRender() throws {
        let (gpu, session, pipeline) = try openRamp()
        let targets = (0..<HealPatch.maximumDustCount).map { i in SIMD2<Float>(420 + Float(i % 20) * 38, 60 + Float(i / 20) * 72) }
        var p = EditParameters()
        p.dust = targets.map { clone($0, from: SIMD2(200, 200), radius: 6) }
        XCTAssertEqual(p.allHealPatches.count, 200)

        let base = try rendered(EditParameters(), session: session, pipeline: pipeline, gpu: gpu)
        let flat = base.at(200, 200)
        XCTAssertGreaterThan(simd_length(flat - base.at(420, 60)), 0.05, "the flat patch differs from the ramp")
        let full = try rendered(p, session: session, pipeline: pipeline, gpu: gpu)
        XCTAssertFalse(full.info.healWasCached)
        for (i, t) in targets.enumerated() {
            XCTAssertLessThan(simd_length(full.at(Int(t.x), Int(t.y)) - flat), 0.01, "spot \(i + 1) healed")
        }
        // Halfway between two spots the ramp is as it was.
        XCTAssertLessThan(simd_length(full.at(439, 60) - base.at(439, 60)), 1e-3)
        XCTAssertLessThan(simd_length(full.at(100, 700) - base.at(100, 700)), 1e-3)

        // The preview renders the same list at 600 x 400.
        let preview = try rendered(p, scale: .binned(quads: 1), session: session, pipeline: pipeline, gpu: gpu)
        let previewBase = try rendered(EditParameters(), scale: .binned(quads: 1), session: session, pipeline: pipeline, gpu: gpu)
        let previewFlat = previewBase.at(100, 100)
        for t in [targets[0], targets[99], targets[199]] {
            XCTAssertLessThan(simd_length(preview.at(Int(t.x / 2), Int(t.y / 2)) - previewFlat), 0.02)
        }
        XCTAssertTrue(try rendered(p, session: session, pipeline: pipeline, gpu: gpu).info.healWasCached, "then the cache serves it")
    }

    /// A dust spot clones ramp pixels onto the flat patch; a blemish and a
    /// user patch then clone that spot elsewhere. Dust comes first, so
    /// both copy the dust-healed ramp pixels; with the same patches in the
    /// other lists the copy is of the flat patch, before the dust healed
    /// it, and a blemish is only healed while Remove Blemishes is on.
    func testDustIsHealedBeforeBlemishesAndUserPatchesReadIt() throws {
        let (gpu, session, pipeline) = try openRamp()
        let spot = SIMD2<Float>(240, 160)      // inside the flat patch
        let rampSource = SIMD2<Float>(720, 480)
        let blemishTarget = SIMD2<Float>(960, 560), userTarget = SIMD2<Float>(960, 240)
        let dust = clone(spot, from: rampSource)
        let blemish = clone(blemishTarget, from: spot)
        let user = clone(userTarget, from: spot)

        let base = try rendered(EditParameters(), session: session, pipeline: pipeline, gpu: gpu)
        let flat = base.at(Int(spot.x), Int(spot.y)), ramp = base.at(Int(rampSource.x), Int(rampSource.y))
        XCTAssertGreaterThan(simd_length(flat - ramp), 0.05)

        var ordered = EditParameters()
        ordered.dust = [dust]
        ordered.touchUp.blemishRemoval = true
        ordered.touchUp.blemishes = [blemish]
        ordered.heals = [user]
        XCTAssertEqual(ordered.allHealPatches, [dust, blemish, user])
        let healed = try rendered(ordered, session: session, pipeline: pipeline, gpu: gpu)
        XCTAssertLessThan(simd_length(healed.at(Int(spot.x), Int(spot.y)) - ramp), 0.01, "the spot shows the ramp")
        XCTAssertLessThan(simd_length(healed.at(Int(userTarget.x), Int(userTarget.y)) - ramp), 0.01,
                          "the user patch copied the dust-healed spot")
        XCTAssertLessThan(simd_length(healed.at(Int(blemishTarget.x), Int(blemishTarget.y)) - ramp), 0.01,
                          "so did the blemish")

        // The same three patches with the spot last: the copies are of the
        // flat patch as it was.
        var reversed = EditParameters()
        reversed.dust = [user]
        reversed.touchUp.blemishRemoval = true
        reversed.touchUp.blemishes = [blemish]
        reversed.heals = [dust]
        let unhealed = try rendered(reversed, session: session, pipeline: pipeline, gpu: gpu)
        XCTAssertLessThan(simd_length(unhealed.at(Int(spot.x), Int(spot.y)) - ramp), 0.01)
        XCTAssertLessThan(simd_length(unhealed.at(Int(userTarget.x), Int(userTarget.y)) - flat), 0.01)
        XCTAssertLessThan(simd_length(unhealed.at(Int(blemishTarget.x), Int(blemishTarget.y)) - flat), 0.01)

        // Remove Blemishes off: the blemish list is kept but not healed.
        var off = ordered
        off.touchUp.blemishRemoval = false
        XCTAssertEqual(off.allHealPatches, [dust, user])
        let kept = try rendered(off, session: session, pipeline: pipeline, gpu: gpu)
        XCTAssertLessThan(simd_length(kept.at(Int(blemishTarget.x), Int(blemishTarget.y))
                                      - base.at(Int(blemishTarget.x), Int(blemishTarget.y))), 1e-3)
        XCTAssertLessThan(simd_length(kept.at(Int(userTarget.x), Int(userTarget.y)) - ramp), 0.01)
    }
}
