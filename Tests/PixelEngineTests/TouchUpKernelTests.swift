import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// The touch-up kernel (docs/Retouch.md §7, §11) on a synthetic face:
/// flat skin with pore-scale noise, a yellow patch of teeth and one eye,
/// with a fixture mask set laid over them. Runs the real stage on a
/// display-referred texture, as RedEyeTests and HealQualityTests run
/// theirs, and measures what each slider did inside its mask and that
/// nothing outside moved.
final class TouchUpKernelTests: XCTestCase {
    static let width = 384, height = 256
    static let faceID = UUID()

    /// Where the three regions sit, in normalised output coordinates:
    /// skin on the left, the eye top right, the teeth bottom right, each
    /// clear of the others so a measurement never straddles two masks.
    static let skinRect = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8)
    static let teethRect = CGRect(x: 0.6, y: 0.65, width: 0.25, height: 0.2)
    static let eyeRect = CGRect(x: 0.6, y: 0.15, width: 0.2, height: 0.3)
    /// The eye the fixture lays out in `eyeRect`: its half-res rectangle
    /// is 115…154 × 19…58, so the centre is (269, 77) in full pixels, the
    /// iris disc 0.32 and the pupil 0.16 of its 39 half-res pixels wide.
    static let eyeCentre = SIMD2<Double>(269, 77)
    static let irisRadius = 25.0, pupilRadius = 12.5

    static func inside(_ r: CGRect, _ x: Int, _ y: Int, inset: Int = 0) -> Bool {
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        return px >= r.minX * Double(width) + Double(inset) && px < r.maxX * Double(width) - Double(inset)
            && py >= r.minY * Double(height) + Double(inset) && py < r.maxY * Double(height) - Double(inset)
    }

    static func eyeDistance(_ x: Int, _ y: Int) -> Double {
        simd_distance(SIMD2(Double(x) + 0.5, Double(y) + 0.5), eyeCentre)
    }

    /// The display-referred (sRGB-encoded, 0…1) scene: skin everywhere
    /// with ±10 % noise at a 6 px scale (pores), a flat yellow patch where
    /// the teeth mask is, and a bright sclera round a brown iris and a
    /// black pupil where the eye mask is.
    static func scene(_ x: Int, _ y: Int) -> SIMD3<Double> {
        if inside(eyeRect, x, y) {
            let d = eyeDistance(x, y)
            if d <= pupilRadius { return SIMD3(0.05, 0.05, 0.05) }
            if d <= irisRadius { return SIMD3(0.40, 0.25, 0.15) }
            return SIMD3(0.92, 0.90, 0.88)
        }
        if inside(teethRect, x, y) { return SIMD3(0.85, 0.80, 0.45) }
        let pores = 1 + 0.10 * HealQualityTests.noise(x, y, cell: 6, seed: 7)
        return SIMD3(0.78, 0.62, 0.52) * pores
    }

    static func maskSet(sensorWidth: Int = width, sensorHeight: Int = height) -> TouchUpMaskSet {
        TouchUpMaskSet.fixture(sensorWidth: sensorWidth, sensorHeight: sensorHeight,
                               faces: [(id: faceID, skin: skinRect, teeth: teethRect, eyes: [eyeRect])])
    }

    /// The mid blur for a face the width of the frame: 13.4 px.
    static let sigmaMid = TouchUp.sigmaMid(faceWidth: Float(width))

    // MARK: - Running the stage

    struct Harness {
        let gpu: GPUContext
        let session: ImageSession
        let masks: MTLTexture
    }

    private func harness() throws -> Harness {
        let gpu = try GPUContext()
        // Any session serves: the stage only borrows its texture pool.
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        session.setTouchUpMasks(Self.maskSet())
        let masks = try XCTUnwrap(session.touchUpMaskTexture(enabled: [Self.faceID]))
        return Harness(gpu: gpu, session: session, masks: masks)
    }

    /// Runs the stage over `input` and reads the result back.
    private func render(_ h: Harness, _ input: MTLTexture, skin: Float = 0, teeth: Float = 0, eyes: Float = 0,
                        overlay: Bool = false, binSpan: Float = 1, sigmaMid: Float = TouchUpKernelTests.sigmaMid,
                        isLinear: Bool = false, headroom: Float = 1) throws -> [Float16] {
        let output = try XCTUnwrap(h.gpu.makePrivateTexture(width: input.width, height: input.height,
                                                             pixelFormat: .rgba16Float))
        let cmd = try XCTUnwrap(h.gpu.commandQueue.makeCommandBuffer())
        let params = TouchUpStage.Params(
            skin: skin, teeth: teeth, eyes: eyes, sigmaFine: 1.5 / binSpan, sigmaMid: sigmaMid,
            isLinear: isLinear, headroom: headroom, tileOrigin: .zero, binSpan: binSpan,
            sensorSize: SIMD2(Float(Self.width), Float(Self.height)), overlay: overlay)
        try TouchUpStage.encode(input: input, output: output, masks: h.masks, params: params,
                                session: h.session, preview: false, gpu: h.gpu, commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        return try TextureReadback.float16Pixels(of: output, gpu: h.gpu)
    }

    static func pixel(_ px: [Float16], _ x: Int, _ y: Int, width: Int = width) -> SIMD3<Double> {
        let i = (y * width + x) * 4
        return SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }

    static func luma(_ c: SIMD3<Double>) -> Double { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }

    static func linear(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2)) }

    /// Mean and variance of the luma over the pixels `include` picks.
    static func lumaStatistics(_ px: [Float16], _ include: (Int, Int) -> Bool) -> (mean: Double, variance: Double) {
        var sum = 0.0, sumSquares = 0.0, n = 0.0
        for y in 0..<height {
            for x in 0..<width where include(x, y) {
                let l = luma(pixel(px, x, y))
                sum += l; sumSquares += l * l; n += 1
            }
        }
        let mean = sum / n
        return (mean, sumSquares / n - mean * mean)
    }

    /// Pixels at least 4 px from every mask rectangle: what no slider may
    /// touch. The masks are sampled with linear filtering at half
    /// resolution, so a mask's influence ends within 2 px of its edge.
    static func outsideEveryMask(_ x: Int, _ y: Int) -> Bool {
        !inside(skinRect, x, y, inset: -4) && !inside(teethRect, x, y, inset: -4) && !inside(eyeRect, x, y, inset: -4)
    }

    static func maxDifference(_ a: [Float16], _ b: [Float16], _ include: (Int, Int) -> Bool) -> Double {
        var worst = 0.0
        for y in 0..<height {
            for x in 0..<width where include(x, y) {
                worst = max(worst, simd_reduce_max(simd_abs(pixel(a, x, y) - pixel(b, x, y))))
            }
        }
        return worst
    }

    // MARK: - Tests

    func testSkinSmoothingFlattensTheNoiseInsideTheMaskOnly() throws {
        let h = try harness()
        let input = try HealQualityTests.texture(width: Self.width, height: Self.height, gpu: h.gpu, Self.scene)
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        let after = try render(h, input, skin: 1)

        // Well inside the skin mask, away from its edge and the blurs' reach.
        let skin = { (x: Int, y: Int) in Self.inside(Self.skinRect, x, y, inset: 8) }
        let was = Self.lumaStatistics(before, skin), now = Self.lumaStatistics(after, skin)
        XCTAssertGreaterThan(was.variance, 1e-4, "the scene has pores to smooth")
        XCTAssertLessThan(now.variance, 0.3 * was.variance,
                          "variance \(was.variance) → \(now.variance) should drop by more than 70 %")
        XCTAssertEqual(now.mean, was.mean, accuracy: 0.01, "smoothing keeps the tone")
        XCTAssertLessThan(Self.maxDifference(before, after, Self.outsideEveryMask), 1e-3, "nothing outside the mask moves")
        // A half-strength slider smooths less.
        let half = Self.lumaStatistics(try render(h, input, skin: 0.5), skin)
        XCTAssertGreaterThan(half.variance, now.variance)
        XCTAssertLessThan(half.variance, was.variance)
    }

    func testTeethWhiteningLosesMostOfTheYellow() throws {
        let h = try harness()
        let input = try HealQualityTests.texture(width: Self.width, height: Self.height, gpu: h.gpu, Self.scene)
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        let after = try render(h, input, teeth: 1)

        func yellow(_ px: [Float16]) -> (yellow: Double, luma: Double) {
            var y = 0.0, l = 0.0, n = 0.0
            for yy in 0..<Self.height {
                for xx in 0..<Self.width where Self.inside(Self.teethRect, xx, yy, inset: 4) {
                    let lin = Self.linear(Self.pixel(px, xx, yy))
                    y += max(0, 0.5 * (lin.x + lin.y) - lin.z); l += Self.luma(lin); n += 1
                }
            }
            return (y / n, l / n)
        }
        let was = yellow(before), now = yellow(after)
        XCTAssertGreaterThan(was.yellow, 0.3, "the patch is yellow to begin with")
        XCTAssertLessThan(now.yellow, 0.5 * was.yellow, "yellow \(was.yellow) → \(now.yellow)")
        XCTAssertGreaterThan(now.luma, was.luma, "and a little brighter")
        XCTAssertLessThan(now.luma, was.luma * 1.35, "but not bleached")
        XCTAssertLessThan(Self.maxDifference(before, after, Self.outsideEveryMask), 1e-3)
        // Skin isn't teeth: the skin mask alone leaves the patch alone.
        XCTAssertLessThan(Self.maxDifference(before, try render(h, input, skin: 1)) {
            Self.inside(Self.teethRect, $0, $1, inset: 4)
        }, 1e-3)
    }

    func testEyesBrightenTheScleraMoreThanTheIris() throws {
        let h = try harness()
        let input = try HealQualityTests.texture(width: Self.width, height: Self.height, gpu: h.gpu, Self.scene)
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        let after = try render(h, input, eyes: 1)

        // Sclera: inside the eye rectangle, clear of the iris and the edge.
        let sclera = { (x: Int, y: Int) in Self.inside(Self.eyeRect, x, y, inset: 4) && Self.eyeDistance(x, y) > 32 }
        // Iris: the ring between the pupil and the sclera, clear of both edges.
        let iris = { (x: Int, y: Int) in Self.eyeDistance(x, y) > 15 && Self.eyeDistance(x, y) < 22 }
        let pupil = { (x: Int, y: Int) in Self.eyeDistance(x, y) < 9 }
        let scleraGain = Self.lumaStatistics(after, sclera).mean / Self.lumaStatistics(before, sclera).mean
        let irisGain = Self.lumaStatistics(after, iris).mean / Self.lumaStatistics(before, iris).mean
        let pupilGain = Self.lumaStatistics(after, pupil).mean / Self.lumaStatistics(before, pupil).mean
        XCTAssertGreaterThan(scleraGain, 1.1, "the sclera brightens")
        XCTAssertGreaterThan(scleraGain, irisGain, "more than the iris (\(scleraGain) vs \(irisGain))")
        XCTAssertGreaterThan(scleraGain, pupilGain, "and more than the pupil (\(pupilGain))")
        XCTAssertLessThan(Self.maxDifference(before, after, Self.outsideEveryMask), 1e-3)
    }

    func testZeroSlidersAreBitIdentical() throws {
        let h = try harness()
        let input = try HealQualityTests.texture(width: Self.width, height: Self.height, gpu: h.gpu, Self.scene)
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        XCTAssertEqual(try render(h, input), before)
        // The EDR path too, where a round trip through the headroom would
        // otherwise show.
        XCTAssertEqual(try render(h, input, isLinear: true, headroom: 2.5), before)
        XCTAssertEqual(try render(h, input, binSpan: 2), before)
    }

    func testOverlayTintsTheSkinMaskRed() throws {
        let h = try harness()
        let input = try HealQualityTests.texture(width: Self.width, height: Self.height, gpu: h.gpu, Self.scene)
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        let after = try render(h, input, overlay: true)
        func redness(_ px: [Float16], _ x: Int, _ y: Int) -> Double {
            let c = Self.pixel(px, x, y)
            return c.x / (c.y + c.z)
        }
        for (x, y) in [(60, 60), (150, 200), (100, 128)] {
            XCTAssertTrue(Self.inside(Self.skinRect, x, y))
            XCTAssertGreaterThan(redness(after, x, y), redness(before, x, y) * 1.2, "redder at (\(x), \(y))")
        }
        XCTAssertLessThan(Self.maxDifference(before, after, Self.outsideEveryMask), 1e-3)
        // Teeth and eye masks aren't skin: no tint there.
        XCTAssertLessThan(Self.maxDifference(before, after) { Self.inside(Self.eyeRect, $0, $1, inset: 4) }, 1e-3)
        XCTAssertLessThan(Self.maxDifference(before, after) { Self.inside(Self.teethRect, $0, $1, inset: 4) }, 1e-3)
        // The EDR path tints as well, in its own light.
        let edr = try render(h, input, overlay: true, isLinear: true, headroom: 2)
        XCTAssertGreaterThan(redness(edr, 100, 128), redness(before, 100, 128) * 1.2)
    }

    /// A binned preview must predict the export: the stage on a 2×
    /// downsampled input at binSpan 2 (the blur sigmas halved, the masks
    /// found by sensor position) matches the full-resolution result
    /// downsampled the same way.
    func testBinnedRenderPredictsTheFullRender() throws {
        let h = try harness()
        let full = try HealQualityTests.texture(width: Self.width, height: Self.height, gpu: h.gpu, Self.scene)
        let bw = Self.width / 2, bh = Self.height / 2
        let binned = try HealQualityTests.texture(width: bw, height: bh, gpu: h.gpu) { x, y in
            (Self.scene(2 * x, 2 * y) + Self.scene(2 * x + 1, 2 * y)
                + Self.scene(2 * x, 2 * y + 1) + Self.scene(2 * x + 1, 2 * y + 1)) / 4
        }
        let fullOut = try render(h, full, skin: 1, teeth: 1, eyes: 1)
        let binnedOut = try render(h, binned, skin: 1, teeth: 1, eyes: 1, binSpan: 2, sigmaMid: Self.sigmaMid / 2)

        // Within 6 px of a mask rectangle's edge the two renders sample
        // the half-res mask at different offsets (a step interpolated at
        // ±¼ texel averages to 0.875 where the texel centre reads 1), and
        // on the eye's rings a box average before and after a per-pixel
        // curve can differ; the fixture's edges are hard, real masks are
        // feathered. Everywhere else the two must agree closely.
        func nearAnEdge(_ x: Int, _ y: Int) -> Bool {
            for r in [Self.skinRect, Self.teethRect, Self.eyeRect]
            where Self.inside(r, x, y, inset: -6) && !Self.inside(r, x, y, inset: 6) { return true }
            let d = Self.eyeDistance(x, y)
            return abs(d - Self.irisRadius) < 3 || abs(d - Self.pupilRadius) < 3
        }
        var worst = 0.0, edgeWorst = 0.0, sum = 0.0
        for y in 0..<bh {
            for x in 0..<bw {
                let expected = (Self.pixel(fullOut, 2 * x, 2 * y) + Self.pixel(fullOut, 2 * x + 1, 2 * y)
                    + Self.pixel(fullOut, 2 * x, 2 * y + 1) + Self.pixel(fullOut, 2 * x + 1, 2 * y + 1)) / 4
                let d = simd_reduce_max(simd_abs(Self.pixel(binnedOut, x, y, width: bw) - expected))
                sum += d
                if nearAnEdge(2 * x, 2 * y) { edgeWorst = max(edgeWorst, d) } else { worst = max(worst, d) }
            }
        }
        let mean = sum / Double(bw * bh)
        XCTAssertLessThan(mean, 0.002, "mean difference \(mean)")
        XCTAssertLessThan(worst, 0.01, "worst difference away from the edges \(worst)")
        XCTAssertLessThan(edgeWorst, 0.1, "worst difference on an edge \(edgeWorst)")
    }
}
