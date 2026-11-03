import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// The Lens Blur stage (LensBlurStage.swift, Shaders/LensBlur.metal) on a
/// synthetic scene: a textured subject on the left, near, and a fine
/// checkerboard background on the right, far, with a depth map that says
/// so. Runs the real kernels on a display-referred texture, as the
/// touch-up kernel tests do, and measures what the blur did on each side
/// of the edge.
final class LensBlurKernelTests: XCTestCase {
    /// Subject (near) left of `split`, background (far) right of it.
    static let split = 0.5
    static let nearDepth: UInt8 = 220, farDepth: UInt8 = 30

    /// The scene, sRGB-encoded 0…1: a slow ramp with a 7 px texture on the
    /// subject, a 2 px checkerboard on the background, and a bright 3 px
    /// dot in the background when `dot` is set.
    static func scene(width: Int, height: Int, dot: SIMD2<Int>? = nil) -> (Int, Int) -> SIMD3<Double> {
        { x, y in
            if let dot, abs(x - dot.x) <= 1, abs(y - dot.y) <= 1 { return SIMD3(0.98, 0.98, 0.98) }
            if Double(x) + 0.5 < split * Double(width) {
                let t = 0.45 + 0.08 * HealQualityTests.noise(x, y, cell: 7, seed: 3)
                return SIMD3(t, t * 0.9, t * 0.8)
            }
            if dot != nil { return SIMD3(0.08, 0.09, 0.10) }
            return ((x / 2 + y / 2) % 2 == 0) ? SIMD3(0.70, 0.72, 0.75) : SIMD3(0.20, 0.22, 0.25)
        }
    }

    static func depthMap(width: Int = 64, height: Int = 32) -> DepthMap {
        var data = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = (Double(x) + 0.5) / Double(width) < split ? nearDepth : farDepth }
        }
        return DepthMap(bitmap: MaskBitmap(width: width, height: height, data: data), source: "test@1")
    }

    struct Harness {
        let gpu: GPUContext
        let session: ImageSession
        let depth: MTLTexture
    }

    private func harness(_ map: DepthMap = LensBlurKernelTests.depthMap()) throws -> Harness {
        let gpu = try GPUContext()
        // Any session serves: the stage only borrows its texture pool.
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        session.setDepthMap(map)
        return Harness(gpu: gpu, session: session, depth: try XCTUnwrap(session.depthTexture()))
    }

    private func run(_ h: Harness, _ input: MTLTexture, _ blur: LensBlur, isLinear: Bool = false,
                     headroom: Float = 1) throws -> [Float16] {
        let output = try XCTUnwrap(h.gpu.makePrivateTexture(width: input.width, height: input.height,
                                                             pixelFormat: .rgba16Float))
        let cmd = try XCTUnwrap(h.gpu.commandQueue.makeCommandBuffer())
        let geometry = LensBlurStage.Geometry(tileOrigin: .zero,
                                              sensorSize: SIMD2(Float(input.width), Float(input.height)),
                                              binSpan: 1, isLinear: isLinear, headroom: headroom)
        try LensBlurStage.encode(input: input, output: output, depth: h.depth, blur: blur, geometry: geometry,
                                 session: h.session, gpu: h.gpu, commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        return try TextureReadback.float16Pixels(of: output, gpu: h.gpu)
    }

    static func pixel(_ px: [Float16], _ x: Int, _ y: Int, width: Int) -> SIMD3<Double> {
        let i = (y * width + x) * 4
        return SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }

    static func luma(_ c: SIMD3<Double>) -> Double { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }

    /// The variance of the luma between neighbours across columns
    /// `xs` (rows inset from top and bottom): how much fine detail is left.
    static func detail(_ px: [Float16], width: Int, height: Int, xs: Range<Int>) -> Double {
        var sum = 0.0, n = 0.0
        for y in 8..<(height - 8) {
            for x in xs where x + 1 < width {
                let d = luma(pixel(px, x + 1, y, width: width)) - luma(pixel(px, x, y, width: width))
                sum += d * d; n += 1
            }
        }
        return sum / max(n, 1)
    }

    // MARK: - Off and in focus

    /// A focus range over the whole scene leaves every pixel as it was,
    /// bit for bit, whatever the amount.
    func testEverythingInFocusIsBitIdentical() throws {
        let h = try harness()
        let w = 240, ht = 160
        let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu, Self.scene(width: w, height: ht))
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        let after = try run(h, input, LensBlur(amount: 100, boost: 100, focusFar: 0, focusNear: 1))
        var diffs: [String] = []
        for i in 0..<before.count where before[i] != after[i] && diffs.count < 10 { diffs.append("\(i % 4) @\((i / 4) % w),\((i / 4) / w): \(before[i]) -> \(after[i])") }
        XCTAssertEqual(before, after, diffs.joined(separator: "; "))
    }

    // MARK: - Blur

    /// The far background loses its fine detail; the near subject, in
    /// focus, is untouched away from the edge, and the background is not
    /// smeared over it.
    func testBackgroundBlursAndTheSubjectStaysSharp() throws {
        for (w, ht) in [(480, 320), (960, 640)] {   // one shrink factor, then two
            let h = try harness()
            let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu, Self.scene(width: w, height: ht))
            let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
            let blur = LensBlur(amount: 100, focusFar: 0.5, focusNear: 1)
            let after = try run(h, input, blur)
            let radius = Int(blur.maximumRadius(longEdge: Float(w)).rounded(.up))
            let edge = w / 2
            let background = (edge + radius + 8)..<(w - 8)
            let subject = 8..<(edge - 8)

            let detailBefore = Self.detail(before, width: w, height: ht, xs: background)
            let detailAfter = Self.detail(after, width: w, height: ht, xs: background)
            XCTAssertLessThan(detailAfter, detailBefore * 0.05, "\(w) px: the checkerboard should blur away")

            // Mean brightness keeps (the blur moves light, it doesn't add it).
            var meanBefore = 0.0, meanAfter = 0.0, n = 0.0
            for y in 8..<(ht - 8) {
                for x in background {
                    meanBefore += Self.luma(Self.pixel(before, x, y, width: w))
                    meanAfter += Self.luma(Self.pixel(after, x, y, width: w)); n += 1
                }
            }
            // The blur averages linear light, so the encoded mean rises a little.
            XCTAssertEqual(meanAfter / n, meanBefore / n, accuracy: 0.08, "\(w) px")

            // The subject, a few pixels clear of the edge, is bit-identical.
            var changed = 0
            for y in 0..<ht {
                for x in subject where Self.pixel(after, x, y, width: w) != Self.pixel(before, x, y, width: w) {
                    changed += 1
                }
            }
            XCTAssertEqual(changed, 0, "\(w) px: pixels inside the focus range must not move")
        }
    }

    /// Half the amount, half the reach: the blurred band next to the edge
    /// is narrower, so detail survives further into the background.
    func testAmountScalesTheBlur() throws {
        let h = try harness()
        let w = 480, ht = 320
        let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu, Self.scene(width: w, height: ht))
        let strong = try run(h, input, LensBlur(amount: 100))
        let weak = try run(h, input, LensBlur(amount: 25))
        let band = (w / 2 + 20)..<(w - 8)
        XCTAssertGreaterThan(Self.detail(weak, width: w, height: ht, xs: band),
                             Self.detail(strong, width: w, height: ht, xs: band) * 1.5)
    }

    // MARK: - Highlights and bokeh

    /// One bright dot in a dark background: Boost Highlights makes the
    /// disc it opens into brighter.
    func testBoostBrightensTheBokehDisc() throws {
        let h = try harness()
        let w = 480, ht = 320
        let dot = SIMD2(360, 160)
        let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu,
                                                 Self.scene(width: w, height: ht, dot: dot))
        let plain = try run(h, input, LensBlur(amount: 100, boost: 0))
        let boosted = try run(h, input, LensBlur(amount: 100, boost: 100))
        func light(_ px: [Float16]) -> Double {
            var sum = 0.0
            for y in (dot.y - 6)...(dot.y + 6) {
                for x in (dot.x - 6)...(dot.x + 6) { sum += Self.luma(Self.pixel(px, x, y, width: w)) }
            }
            return sum
        }
        XCTAssertGreaterThan(light(boosted), light(plain) * 1.5)
    }

    /// The three shapes are three different blurs, and a bubble's disc is
    /// brighter at its rim than in its middle.
    func testBokehShapes() throws {
        let h = try harness()
        let w = 960, ht = 640
        let dot = SIMD2(720, 320)
        let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu,
                                                 Self.scene(width: w, height: ht, dot: dot))
        let circle = try run(h, input, LensBlur(amount: 100, bokeh: .circle, boost: 100))
        let bubble = try run(h, input, LensBlur(amount: 100, bokeh: .bubble, boost: 100))
        let blades = try run(h, input, LensBlur(amount: 100, bokeh: .blades5, boost: 100))
        XCTAssertNotEqual(circle, bubble)
        XCTAssertNotEqual(circle, blades)

        // The disc's radius in pixels; average a ring at 85 % against the middle at 25 %.
        let radius = Double(LensBlur(amount: 100).maximumRadius(longEdge: Float(w)))
        func ring(_ px: [Float16], at r: Double) -> Double {
            var sum = 0.0
            for i in 0..<64 {
                let a = Double(i) / 64 * 2 * .pi
                let x = Int((Double(dot.x) + 0.5 + cos(a) * r).rounded(.down))
                let y = Int((Double(dot.y) + 0.5 + sin(a) * r).rounded(.down))
                sum += Self.luma(Self.pixel(px, x, y, width: w))
            }
            return sum / 64
        }
        XCTAssertGreaterThan(ring(bubble, at: 0.85 * radius), ring(bubble, at: 0.25 * radius) * 1.1,
                             "a bubble is brighter at its rim")
    }

    /// The EDR viewport's linear encoding: the same blur, no NaNs, and an
    /// in-focus pixel untouched.
    func testLinearEncoding() throws {
        let h = try harness()
        let w = 240, ht = 160
        let headroom: Float = 2
        let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu) { x, y in
            let c = Self.scene(width: w, height: ht)(x, y)
            return SIMD3(pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2)) * Double(headroom)
        }
        let before = try TextureReadback.float16Pixels(of: input, gpu: h.gpu)
        let after = try run(h, input, LensBlur(amount: 100, boost: 50), isLinear: true, headroom: headroom)
        XCTAssertFalse(after.contains { $0.isNaN })
        XCTAssertEqual(Self.pixel(after, 20, 80, width: w), Self.pixel(before, 20, 80, width: w))
        XCTAssertLessThan(Self.detail(after, width: w, height: ht, xs: 200..<230),
                          Self.detail(before, width: w, height: ht, xs: 200..<230) * 0.1)
    }

    // MARK: - Show Depth

    /// Show Depth paints near warm and far cool, and washes the focus
    /// range light.
    func testDepthView() throws {
        let h = try harness()
        let w = 120, ht = 80
        let input = try HealQualityTests.texture(width: w, height: ht, gpu: h.gpu, Self.scene(width: w, height: ht))
        let geometry = LensBlurStage.Geometry(tileOrigin: .zero, sensorSize: SIMD2(Float(w), Float(ht)),
                                              binSpan: 1, isLinear: false, headroom: 1)
        let cmd = try XCTUnwrap(h.gpu.commandQueue.makeCommandBuffer())
        let out = try LensBlurStage.encodeDepthView(input: input, depth: h.depth, blur: LensBlur(focusFar: 0.5, focusNear: 1),
                                                    geometry: geometry, session: h.session, preview: false,
                                                    gpu: h.gpu, commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        let px = try TextureReadback.float16Pixels(of: out, gpu: h.gpu)
        let near = Self.pixel(px, 10, 40, width: w), far = Self.pixel(px, 110, 40, width: w)
        XCTAssertGreaterThan(near.x, near.z, "near is warm")
        XCTAssertGreaterThan(far.z, far.x, "far is cool")
        XCTAssertGreaterThan(Self.luma(near), Self.luma(far), "the focus range is washed light")
    }

    // MARK: - In the pipeline

    /// Through the whole render: off (or on without a depth map yet) the
    /// stage is skipped and the pixels are those of an edit without it;
    /// on with a depth map, the far side changes.
    func testPipelineSkipsTheStageUntilItHasWorkToDo() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.ramp)), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        func render(_ p: EditParameters) throws -> [Float16] {
            try TextureReadback.float16Pixels(of: pipeline.render(session, scale: .fitting(maxDimension: 600),
                                                                  parameters: p), gpu: gpu)
        }
        let plain = try render(EditParameters())
        var on = EditParameters()
        on.lensBlur = LensBlur(amount: 100, focusFar: 0.5, focusNear: 1)
        XCTAssertEqual(try render(on), plain, "no depth map yet: nothing to blur with")

        session.setDepthMap(Self.depthMap())
        var off = on
        off.lensBlur.amount = 0
        XCTAssertEqual(try render(off), plain, "amount 0: the stage does not run")
        XCTAssertNotEqual(try render(on), plain, "on, with a depth map: the background blurs")
    }
}
