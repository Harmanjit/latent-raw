import XCTest
import Metal
import simd
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// The heal cache (docs/Retouch.md §6): a render whose stages 3 to 5
/// (neural denoise, noise reduction, spot removal) would read exactly
/// what an earlier render's did takes that render's healed texture and
/// skips the three stages. The key must miss on every field those stages
/// read and hit on everything after them, the preview's entry must
/// survive a tile of the same size, and a hit must actually be cheap.
///
/// The key tests run on the 64 x 48 linear fixture (a session in
/// milliseconds); the timing runs on a D750 raw and skips without one.
final class HealCacheTests: XCTestCase {
    private func openFixture(_ name: String = LinearFixtures.plain) throws -> (GPUContext, ImageSession, RenderPipeline) {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(name)), gpu: gpu)
        return (gpu, session, RenderPipeline(gpu: gpu))
    }

    /// A heal that stage 5 runs on every render of the fixture. Built once:
    /// a patch's id is part of its hash, and the editor's lists keep their
    /// ids from one render to the next, so a fresh patch each time would
    /// miss for a reason no slider tick ever gives.
    private let base: EditParameters = {
        var p = EditParameters()
        p.heals = [HealPatch(target: [0.5, 0.5], source: [0.3, 0.3], radius: 0.1)]
        return p
    }()

    /// Renders and says whether stages 3 to 5 were skipped.
    @discardableResult
    private func render(_ p: EditParameters, scale: RenderScale = .binned(quads: 1), output: RenderOutput? = nil,
                        session: ImageSession, pipeline: RenderPipeline) throws -> (texture: MTLTexture, cached: Bool) {
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
        let texture = try pipeline.render(session, scale: scale, parameters: p, output: output, info: &info)
        return (texture, info.healWasCached)
    }

    // MARK: - The key

    /// Every field stages 3 to 5 read: a change to any of them must miss.
    /// Each variant is looked up while the base entry is still there (a
    /// store only evicts afterwards), so a miss means the key differs.
    func testMissesOnEveryFieldTheStagesRead() throws {
        let (_, session, pipeline) = try openFixture()
        XCTAssertFalse(try render(base, session: session, pipeline: pipeline).cached, "first render")
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached, "second render hits")

        let variants: [(String, (inout EditParameters) -> Void)] = [
            ("white balance (the demosaic's multipliers)", { $0.whiteBalance = ColorKit.WhiteBalance(temperature: 3800, tint: 18) }),
            ("luminance noise reduction", { $0.denoiseLuminance = 0.5 }),
            ("colour noise reduction", { $0.denoiseColor = 0.5 }),
            ("neural denoise strength", { $0.aiDenoise = 0.5 }),
            ("a dust spot", { $0.dust = [HealPatch(target: [0.2, 0.2], source: [0.4, 0.2], radius: 0.05, feather: 0.5)] }),
            ("a user patch moved", { $0.heals[0].target = [0.55, 0.5] }),
            ("a user patch's mode", { $0.heals[0].mode = .clone }),
            ("a user patch's feather", { $0.heals[0].feather = 0.9 }),
            ("a second user patch", { $0.heals.append(HealPatch(target: [0.7, 0.7], source: [0.3, 0.3], radius: 0.05)) }),
            ("a red eye", { $0.redEyes = [RedEyeSpot(centre: [0.5, 0.5], radius: 0.1)] }),
            ("blemishes with Remove Blemishes on", {
                $0.touchUp.blemishRemoval = true
                $0.touchUp.blemishes = [HealPatch(target: [0.6, 0.4], source: [0.6, 0.6], radius: 0.05, feather: 0.5)]
            }),
        ]
        for (name, change) in variants {
            var p = base
            change(&p)
            XCTAssertFalse(try render(p, session: session, pipeline: pipeline).cached, "\(name) must miss")
            // Back to the base, which the variant's store evicted (same
            // pooled texture), so it is stored again for the next variant.
            XCTAssertFalse(try render(base, session: session, pipeline: pipeline).cached)
            XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached)
        }

        // The render's own shape is in the demosaic's key.
        XCTAssertFalse(try render(base, scale: .binned(quads: 2), session: session, pipeline: pipeline).cached, "another bin factor")
        XCTAssertFalse(try render(base, scale: .full, session: session, pipeline: pipeline).cached, "full resolution")
        XCTAssertFalse(try render(base, scale: .region(x: 0, y: 0, width: 40, height: 40), session: session, pipeline: pipeline).cached, "a region")
        // This fixture has a lens profile, so a region render demosaics
        // the window the lens pass reads, which on a 64 x 48 sensor is
        // the same whole window for any region: the healed window serves
        // another region too, and the lens pass cuts each region from it.
        XCTAssertNotNil(session.lensCorrection)
        XCTAssertTrue(try render(base, scale: .region(x: 8, y: 0, width: 40, height: 40), session: session, pipeline: pipeline).cached,
                      "another region with the same source window")
    }

    /// Without lens correction a region is demosaiced as asked, so another
    /// region is another key.
    func testAnotherRegionMissesWithoutLensCorrection() throws {
        let (_, session, pipeline) = try openFixture(LinearFixtures.orientation6)
        XCTAssertNil(session.lensCorrection)
        let region = RenderScale.region(x: 0, y: 0, width: 40, height: 40)
        XCTAssertFalse(try render(base, scale: region, session: session, pipeline: pipeline).cached)
        XCTAssertTrue(try render(base, scale: region, session: session, pipeline: pipeline).cached)
        XCTAssertFalse(try render(base, scale: .region(x: 8, y: 0, width: 40, height: 40), session: session, pipeline: pipeline).cached,
                       "another region")
        XCTAssertFalse(try render(base, scale: .region(x: 0, y: 0, width: 32, height: 40), session: session, pipeline: pipeline).cached,
                       "another size")
    }

    /// Blemishes only count while Remove Blemishes is on: the list can
    /// change under an off switch without a miss, and the switch itself
    /// misses.
    func testBlemishesCountOnlyWhileRemoveBlemishesIsOn() throws {
        let (_, session, pipeline) = try openFixture()
        var off = base
        off.touchUp.blemishes = [HealPatch(target: [0.6, 0.4], source: [0.6, 0.6], radius: 0.05, feather: 0.5)]
        try render(off, session: session, pipeline: pipeline)
        var changed = off
        changed.touchUp.blemishes[0].target = [0.7, 0.4]
        XCTAssertTrue(try render(changed, session: session, pipeline: pipeline).cached, "the list under an off switch")
        var on = off
        on.touchUp.blemishRemoval = true
        XCTAssertFalse(try render(on, session: session, pipeline: pipeline).cached, "the switch")
    }

    /// Everything after stage 5 hits: the colour and tone stages, locals,
    /// presence, sharpening, the touch-up sliders, and on a binned render
    /// the lens corrections too (a region render widens its demosaic for
    /// them, which is the demosaic key's business).
    func testHitsOnEverythingAfterStageFive() throws {
        let (_, session, pipeline) = try openFixture()
        try render(base, session: session, pipeline: pipeline)
        let variants: [(String, (inout EditParameters) -> Void)] = [
            ("exposure", { $0.exposureEV = 1.2 }),
            ("contrast and grey point", { $0.contrast = 2.2; $0.greyPoint = 0.16 }),
            ("highlight recovery", { $0.highlightRecovery = 0.3; $0.highlightThreshold = 0.7 }),
            ("tone ranges", { $0.toneRanges = ToneRanges(highlights: -0.5, shadows: 0.4, whites: 0.2, blacks: -0.2) }),
            ("tone curve", { $0.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.3, 0.2), SIMD2(1, 1)]) }),
            ("HSL and vibrance", { $0.hsl.saturation[0] = 0.4; $0.vibrance = 0.5 }),
            ("split toning", { $0.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.3, highlightHue: 45, highlightSaturation: 0.25, balance: 0) }),
            ("a local adjustment", { $0.locals = [LocalAdjustment(name: "x", shape: .radial(centre: [0.5, 0.5], radii: [0.3, 0.3], feather: 0.5), exposureEV: 0.5)] }),
            ("crop", { $0.crop = CropParameters(centre: [0.5, 0.5], size: [0.8, 0.8], angle: 3) }),
            ("presence", { $0.texture = 0.5; $0.clarity = 0.3; $0.dehaze = 0.2 }),
            ("sharpening", { $0.sharpenAmount = 1; $0.sharpenRadius = 1.5 }),
            ("defringe", { $0.defringePurple = 0.5 }),
            ("lens switches", { $0.lensDistortion = false; $0.lensTCA = false; $0.lensVignetting = false }),
            ("manual lens and keystone", { $0.manualDistortion = 0.1; $0.manualVignetting = 0.3; $0.perspective = PerspectiveCorrection(vertical: 0.2, horizontal: 0) }),
            ("touch-up sliders and faces", {
                $0.touchUp.faces = [TouchUpFace(boundingBox: SIMD4(0.2, 0.2, 0.4, 0.4))]
                $0.touchUp.skinSmoothing = 50
            }),
            ("demosaic method (a linear source is never demosaiced)", { $0.demosaic = .bilinear }),
        ]
        for (name, change) in variants {
            var p = base
            change(&p)
            XCTAssertTrue(try render(p, session: session, pipeline: pipeline).cached, "\(name) must hit")
        }
        // The destination isn't the edit's business either.
        XCTAssertTrue(try render(base, output: .sceneLinear, session: session, pipeline: pipeline).cached, "scene-linear output")
        XCTAssertTrue(try render(base, output: .edrDisplay(headroom: 2), session: session, pipeline: pipeline).cached, "EDR output")
        var overlay = RenderOutput.file(.sRGB)
        overlay.spotVisualisation = SpotVisualisation(threshold: 0.5, radiusSensorPx: 4)
        XCTAssertTrue(try render(base, output: overlay, session: session, pipeline: pipeline).cached, "Visualise Spots")
    }

    /// The key's fields are exactly the plan's; a stage that starts
    /// reading something else has to come through here.
    func testKeyHoldsTheFieldsStagesThreeToFiveRead() {
        let key = ImageSession.HealKey(
            stageKey: RenderPipeline.stageKey(plan: .binned(quads: 1), source: .bayer, multipliers: SIMD4(2, 1, 1.2, 1),
                                              demosaic: .rcd),
            aiDenoise: 0, aiDenoiseModel: nil, denoiseLuminance: 0, denoiseColor: 0,
            dust: [], blemishes: [], heals: [], redEyes: [])
        XCTAssertEqual(Mirror(reflecting: key).children.compactMap(\.label),
                       ["stageKey", "aiDenoise", "aiDenoiseModel", "denoiseLuminance", "denoiseColor",
                        "dust", "blemishes", "heals", "redEyes"])
    }

    // MARK: - The store

    /// The preview and a tile of the same size write different roles, so
    /// the tile can't take the preview's texture from under its entry.
    func testPreviewEntrySurvivesATileOfTheSameSize() throws {
        let (_, session, pipeline) = try openFixture()
        let preview = RenderScale.binned(quads: 1)                       // 32 x 24
        let tile = RenderScale.region(x: 0, y: 0, width: 32, height: 24) // the same size, full resolution
        let first = try render(base, scale: preview, session: session, pipeline: pipeline)
        XCTAssertFalse(first.cached)
        XCTAssertEqual(first.texture.width, 32)
        XCTAssertTrue(try render(base, scale: preview, session: session, pipeline: pipeline).cached)
        let tiled = try render(base, scale: tile, session: session, pipeline: pipeline)
        XCTAssertFalse(tiled.cached)
        XCTAssertEqual(tiled.texture.width, 32)
        XCTAssertTrue(try render(base, scale: preview, session: session, pipeline: pipeline).cached, "the preview's entry survived")
        XCTAssertTrue(try render(base, scale: tile, session: session, pipeline: pipeline).cached, "and so did the tile's")
    }

    /// Two previews with different heals share one pooled texture, so the
    /// second's store must evict the first's entry: a hit on it would show
    /// the second's pixels.
    func testStoreEvictsTheEntryWhoseTextureItReuses() throws {
        let (_, session, pipeline) = try openFixture()
        var other = base
        other.heals[0].target = [0.6, 0.6]
        try render(base, session: session, pipeline: pipeline)
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached)
        let second = try render(other, session: session, pipeline: pipeline)
        XCTAssertFalse(second.cached)
        let again = try render(base, session: session, pipeline: pipeline)
        XCTAssertFalse(again.cached, "the base entry pointed at the texture the other render wrote")
        XCTAssertTrue(again.texture === second.texture, "one pooled texture for the role")
    }

    /// Only a render that ran the heal stage stores anything: noise
    /// reduction alone leaves a texture in a role other stages reuse, and
    /// the demosaic alone is the stage cache's.
    func testOnlyAHealedRenderIsStored() throws {
        let (_, session, pipeline) = try openFixture()
        var denoised = EditParameters()
        denoised.denoiseLuminance = 0.5
        for p in [EditParameters(), denoised] {
            XCTAssertFalse(try render(p, session: session, pipeline: pipeline).cached)
            XCTAssertFalse(try render(p, session: session, pipeline: pipeline).cached, "nothing to serve")
        }
    }

    /// Dropping the pooled textures drops the entries; dropping one pool's
    /// drops that pool's; a new neural denoise result drops them all, as
    /// the key names the model but not its pixels.
    func testClearedWithThePoolAndByANewDenoiseResult() throws {
        let (gpu, session, pipeline) = try openFixture()
        try render(base, session: session, pipeline: pipeline)
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached)

        session.releasePooledTextures()
        XCTAssertFalse(try render(base, session: session, pipeline: pipeline).cached, "cleared with the pool")
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached)

        session.releasePooledTextures(in: .magnifier)
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached, "another pool's release leaves the view's entry")
        // The magnifier's render finds the view's entry (the key doesn't
        // name the pool, as the stage cache's doesn't); once the view's
        // pool goes, so does the entry, and the magnifier stored nothing.
        XCTAssertTrue(try session.withTexturePool(.magnifier) { try render(base, session: session, pipeline: pipeline).cached })
        session.releasePooledTextures(in: .view)
        XCTAssertFalse(try session.withTexturePool(.magnifier) { try render(base, session: session, pipeline: pipeline).cached })
        XCTAssertTrue(try session.withTexturePool(.magnifier) { try render(base, session: session, pipeline: pipeline).cached })
        session.releasePooledTextures(in: .magnifier)
        XCTAssertFalse(try session.withTexturePool(.magnifier) { try render(base, session: session, pipeline: pipeline).cached })

        try render(base, session: session, pipeline: pipeline)
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
        d.storageMode = .shared
        session.setAIDenoised(gpu.device.makeTexture(descriptor: d), model: "test")
        XCTAssertFalse(try render(base, session: session, pipeline: pipeline).cached, "a new denoise result")
        XCTAssertTrue(try render(base, session: session, pipeline: pipeline).cached)
        session.setAIDenoised(nil, model: nil)
        XCTAssertFalse(try render(base, session: session, pipeline: pipeline).cached, "and its removal")
    }

    // MARK: - A hit is cheap

    /// D750, 200 dust spots and a few user patches at the viewport's
    /// preview size: the second render skips about a thousand heal
    /// dispatches, gives the same pixels, and is several times faster.
    /// Also the demosaic method on a real raw, which the linear fixture
    /// can't show.
    func testHitSkipsTheStage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        p.dust = (0..<HealPatch.maximumDustCount).map { i in
            let x = 0.05 + 0.9 * Float(i % 20) / 19, y = 0.05 + 0.9 * Float(i / 20) / 9
            return HealPatch(target: [x, y], source: [x + 0.004, y], radius: 0.002, feather: 0.5, mode: .heal)
        }
        p.heals = [HealPatch(target: [0.5, 0.5], source: [0.6, 0.6], radius: 0.03),
                   HealPatch(target: [0.3, 0.7], source: [0.2, 0.2], radius: 0.02, mode: .clone)]
        let scale = RenderScale.binned(quads: 2)

        // Warm the demosaic and the pipelines, so the two timings differ
        // only by the heal stage.
        try render(EditParameters(), scale: scale, session: session, pipeline: pipeline)
        let clock = ContinuousClock()
        let missStart = clock.now
        let miss = try render(p, scale: scale, session: session, pipeline: pipeline)
        let missTime = clock.now - missStart
        let hitStart = clock.now
        let hit = try render(p, scale: scale, session: session, pipeline: pipeline)
        let hitTime = clock.now - hitStart
        XCTAssertFalse(miss.cached)
        XCTAssertTrue(hit.cached)
        print(String(format: "heal cache: 202 patches at %dx%d, miss %.1f ms, hit %.1f ms", miss.texture.width, miss.texture.height,
                     Double(missTime.components.attoseconds) / 1e15 + Double(missTime.components.seconds) * 1e3,
                     Double(hitTime.components.attoseconds) / 1e15 + Double(hitTime.components.seconds) * 1e3))
        XCTAssertLessThan(hitTime, missTime / 2, "a hit skips the heal dispatches")
        XCTAssertEqual(try TextureReadback.float16Pixels(of: hit.texture, gpu: gpu),
                       try TextureReadback.float16Pixels(of: miss.texture, gpu: gpu), "same pixels")

        var bilinear = p
        bilinear.demosaic = .bilinear
        let tile = RenderScale.region(x: 1000, y: 1000, width: 512, height: 512)
        try render(p, scale: tile, session: session, pipeline: pipeline)
        XCTAssertTrue(try render(p, scale: tile, session: session, pipeline: pipeline).cached)
        XCTAssertFalse(try render(bilinear, scale: tile, session: session, pipeline: pipeline).cached, "the demosaic method")
    }
}
