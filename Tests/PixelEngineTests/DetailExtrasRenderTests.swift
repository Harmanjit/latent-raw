import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// The new kernels at work: hot pixel removal on a real sensor plane with
/// planted stuck photosites, Fill and Blur patches through the heal stage,
/// and Lens Blur's Gaussian and Motion on a synthetic scene.
final class DetailExtrasRenderTests: XCTestCase {
    typealias Q = HealQualityTests

    // MARK: - Hot pixels

    /// Stuck photosites planted at white in dark parts of the D750 frame
    /// are all replaced, each by its neighbours' median, and counted; the
    /// rest of the plane is copied as it was. Also Dim Outliers finds at
    /// least as many. Runs on the golden raw on CI.
    func testPlantedStuckPixelsAreReplaced() throws {
        let gpu = try GPUContext()
        let file = try RawFile(path: try TestAssets.d750Path())
        let session = try ImageSession(file: file, gpu: gpu)
        let s = file.summary
        let w = s.rawWidth, h = s.rawHeight
        let plane = session.sensorBuffer.contents().bindMemory(to: UInt16.self, capacity: w * h)
        let range = s.whiteLevel - s.blackLevel
        func value(_ x: Int, _ y: Int) -> Float { max(Float(plane[y * w + x]) - s.blackLevel, 0) / range }

        // Dark spots spread over the frame: every neighbour well below white.
        var planted: [(Int, Int, Float)] = []
        var y = 40
        while y < h - 40 && planted.count < 40 {
            var x = 40 + (y % 7) * 2
            while x < w - 40 && planted.count < 40 {
                let n = [(-2, -2), (0, -2), (2, -2), (-2, 0), (2, 0), (-2, 2), (0, 2), (2, 2)].map { value(x + $0.0, y + $0.1) }
                if n.max()! < 0.2, value(x, y) < 0.2 {
                    let sorted = n.sorted()
                    planted.append((x, y, 0.5 * (sorted[3] + sorted[4])))
                }
                x += 997
            }
            y += 211
        }
        XCTAssertGreaterThan(planted.count, 10, "too few dark spots to plant in")
        let original = Array(UnsafeBufferPointer(start: plane, count: w * h))
        for (x, y, _) in planted { plane[y * w + x] = UInt16(s.whiteLevel) }

        let removal = HotPixelRemoval(threshold: 50, mode: .stuck)
        let clean = try HotPixelStage.makeCleanPlane(session: session, removal: removal, gpu: gpu)
        XCTAssertGreaterThanOrEqual(clean.fixed, planted.count)
        let out = clean.buffer.contents().bindMemory(to: UInt16.self, capacity: w * h)
        for (x, y, median) in planted {
            let got = max(Float(out[y * w + x]) - s.blackLevel, 0) / range
            XCTAssertEqual(got, median, accuracy: 1.5 / range, "(\(x), \(y))")
        }
        // Everything replaced was a pixel standing out: at most a few
        // hundredths of a percent of the frame, the planted ones included.
        var changed = 0
        for i in 0..<(w * h) where out[i] != plane[i] { changed += 1 }
        XCTAssertEqual(changed, clean.fixed)
        XCTAssertLessThan(Double(changed), Double(w * h) * 0.002)

        let outliers = try HotPixelStage.makeCleanPlane(session: session,
                                                        removal: HotPixelRemoval(threshold: 50, mode: .outliers), gpu: gpu)
        XCTAssertGreaterThanOrEqual(outliers.fixed, clean.fixed)

        // Through a render: the preview misses the plain demosaic's cache,
        // and the count is there for the panel afterwards.
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        let plain = try TextureReadback.float16Pixels(
            of: pipeline.renderCameraRGB(session, scale: .binned(quads: 4), parameters: p), gpu: gpu)
        XCTAssertNil(session.hotPixelsFixed(for: removal))
        p.hotPixels = removal
        let cleaned = try TextureReadback.float16Pixels(
            of: pipeline.renderCameraRGB(session, scale: .binned(quads: 4), parameters: p), gpu: gpu)
        XCTAssertEqual(session.hotPixelsFixed(for: removal), clean.fixed)
        XCTAssertNotEqual(plain, cleaned)
        original.withUnsafeBufferPointer { _ = memcpy(plane, $0.baseAddress!, w * h * 2) }
    }

    /// A linear source has no mosaic: the setting changes nothing and
    /// counts nothing.
    func testLinearSourceIgnoresHotPixels() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var p = EditParameters()
        let before = try TextureReadback.float16Pixels(of: pipeline.render(session, scale: .full, parameters: p), gpu: gpu)
        p.hotPixels = HotPixelRemoval(threshold: 0, mode: .outliers)
        let after = try TextureReadback.float16Pixels(of: pipeline.render(session, scale: .full, parameters: p), gpu: gpu)
        XCTAssertEqual(before, after)
        XCTAssertNil(session.hotPixelsFixed(for: p.hotPixels))
    }

    // MARK: - Fill and Blur

    /// Fill paints its colour (camera space here, the matrix being the
    /// identity) times 2^brightness inside the patch, at the patch's
    /// opacity, and leaves the outside alone.
    func testFillPaintsItsColour() throws {
        let gpu = try GPUContext()
        let w = 96, h = 64
        let size = SIMD2<Float>(Float(w), Float(h))
        let input = try Q.texture(width: w, height: h, gpu: gpu) { x, y in
            SIMD3(0.1 + 0.004 * Double(x), 0.3, 0.2)
        }
        func fill(_ opacity: Float?) -> HealPatch {
            var p = HealPatch(target: SIMD2(48, 32) / size, source: SIMD2(48, 32) / size,
                              radius: 12.0 / 64, feather: 0, mode: .fill, opacity: opacity)
            p.fillColour = SIMD3(0.3, 0.2, 0.1)
            p.fillBrightness = 1
            return p
        }
        let full = try Q.healed(input, patches: [fill(nil)], sensorSize: size, gpu: gpu)
        XCTAssertEqual(full(48, 32).x, 0.6, accuracy: 2e-3)
        XCTAssertEqual(full(48, 32).y, 0.4, accuracy: 2e-3)
        XCTAssertEqual(full(48, 32).z, 0.2, accuracy: 2e-3)
        XCTAssertEqual(full(10, 10).y, 0.3, accuracy: 1e-3)
        let half = try Q.healed(input, patches: [fill(0.5)], sensorSize: size, gpu: gpu)
        XCTAssertEqual(half(48, 32).y, 0.35, accuracy: 2e-3)
    }

    /// Blur takes the checkerboard under the patch to its mean, as a spot
    /// and as a brush stroke, and leaves the outside exactly as it was.
    func testBlurSoftensUnderThePatch() throws {
        let gpu = try GPUContext()
        let w = 128, h = 96
        let size = SIMD2<Float>(Float(w), Float(h))
        let input = try Q.texture(width: w, height: h, gpu: gpu) { x, y in
            ((x / 2 + y / 2) % 2 == 0) ? SIMD3(0.7, 0.7, 0.7) : SIMD3(0.1, 0.1, 0.1)
        }
        func spread(_ px: (Int, Int) -> SIMD3<Double>, around c: SIMD2<Int>, reach: Int) -> Double {
            var lo = 1.0, hi = 0.0
            for y in (c.y - reach)...(c.y + reach) {
                for x in (c.x - reach)...(c.x + reach) { lo = min(lo, px(x, y).x); hi = max(hi, px(x, y).x) }
            }
            return hi - lo
        }
        var spot = HealPatch(target: SIMD2(64, 48) / size, source: SIMD2(64, 48) / size,
                             radius: 20.0 / 96, feather: 0, mode: .blur)
        spot.blurRadius = 6.0 / 96
        let blurred = try Q.healed(input, patches: [spot], sensorSize: size, gpu: gpu)
        XCTAssertLessThan(spread(blurred, around: SIMD2(64, 48), reach: 6), 0.1)
        XCTAssertEqual(blurred(64, 48).x, 0.4, accuracy: 0.06)
        XCTAssertEqual(blurred(4, 4).x, ((4 / 2 + 4 / 2) % 2 == 0) ? 0.7 : 0.1, accuracy: 1e-3)

        let stroke = try XCTUnwrap(HealPatch.stroke(path: [SIMD2(20, 30) / size, SIMD2(108, 30) / size],
                                                     radius: 8.0 / 96, feather: 0, mode: .blur,
                                                     sensorSize: CGSize(width: w, height: h)))
        var blurStroke = stroke
        blurStroke.source = blurStroke.target
        blurStroke.blurRadius = 4.0 / 96
        let along = try Q.healed(input, patches: [blurStroke], sensorSize: size, gpu: gpu)
        for x in [30, 64, 98] {
            XCTAssertLessThan(spread(along, around: SIMD2(x, 30), reach: 3), 0.15, "x \(x)")
        }
        XCTAssertGreaterThan(spread(along, around: SIMD2(64, 80), reach: 3), 0.5)
    }

    // MARK: - Lens Blur types

    private func lensBlur(_ input: MTLTexture, _ blur: LensBlur, depth: Bool, gpu: GPUContext) throws -> [Float16] {
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        session.setDepthMap(LensBlurKernelTests.depthMap())
        let output = try XCTUnwrap(gpu.makePrivateTexture(width: input.width, height: input.height,
                                                           pixelFormat: .rgba16Float))
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let geometry = LensBlurStage.Geometry(tileOrigin: .zero,
                                              sensorSize: SIMD2(Float(input.width), Float(input.height)),
                                              binSpan: 1, isLinear: false, headroom: 1)
        try LensBlurStage.encode(input: input, output: output, depth: depth ? session.depthTexture() : nil,
                                 blur: blur, geometry: geometry, session: session, gpu: gpu, commandBuffer: cmd)
        cmd.commit(); cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        return try TextureReadback.float16Pixels(of: output, gpu: gpu)
    }

    /// Mean squared difference between neighbours `step` apart, over
    /// columns `xs`: how much detail is left along that direction.
    private func detail(_ px: [Float16], width: Int, height: Int, xs: Range<Int>, step: SIMD2<Int>) -> Double {
        typealias L = LensBlurKernelTests
        var sum = 0.0, n = 0.0
        for y in 8..<(height - 8) {
            for x in xs where x + step.x < width && y + step.y < height {
                let d = L.luma(L.pixel(px, x + step.x, y + step.y, width: width)) - L.luma(L.pixel(px, x, y, width: width))
                sum += d * d; n += 1
            }
        }
        return sum / max(n, 1)
    }

    /// Gaussian blurs the far background and keeps the near subject
    /// sharp over a depth map; without one it blurs both.
    func testGaussianKeepsTheFocusRangeAndBlursAllWithoutDepth() throws {
        let gpu = try GPUContext()
        let w = 256, h = 128
        let input = try Q.texture(width: w, height: h, gpu: gpu) { x, y in
            ((x / 2 + y / 2) % 2 == 0) ? SIMD3(0.70, 0.72, 0.75) : SIMD3(0.20, 0.22, 0.25)
        }
        let original = try TextureReadback.float16Pixels(of: input, gpu: gpu)
        var blur = LensBlur(amount: 60, focusFar: 0.7, focusNear: 1)
        blur.blurType = .gaussian
        let near = 8..<(w / 2 - 24), far = (w / 2 + 24)..<(w - 8)
        let step = SIMD2(1, 0)
        let withDepth = try lensBlur(input, blur, depth: true, gpu: gpu)
        XCTAssertEqual(detail(withDepth, width: w, height: h, xs: near, step: step),
                       detail(original, width: w, height: h, xs: near, step: step), accuracy: 1e-6)
        XCTAssertLessThan(detail(withDepth, width: w, height: h, xs: far, step: step),
                          0.05 * detail(original, width: w, height: h, xs: far, step: step))
        let whole = try lensBlur(input, blur, depth: false, gpu: gpu)
        XCTAssertLessThan(detail(whole, width: w, height: h, xs: near, step: step),
                          0.05 * detail(original, width: w, height: h, xs: near, step: step))
    }

    /// Motion at 0° smears vertical stripes (detail across x) and leaves
    /// horizontal ones (detail across y) nearly alone; at 90° the reverse.
    func testMotionBlursAlongItsAngle() throws {
        let gpu = try GPUContext()
        let w = 192, h = 192
        let vertical = try Q.texture(width: w, height: h, gpu: gpu) { x, _ in
            (x / 2) % 2 == 0 ? SIMD3(0.7, 0.7, 0.7) : SIMD3(0.2, 0.2, 0.2)
        }
        let horizontal = try Q.texture(width: w, height: h, gpu: gpu) { _, y in
            (y / 2) % 2 == 0 ? SIMD3(0.7, 0.7, 0.7) : SIMD3(0.2, 0.2, 0.2)
        }
        var blur = LensBlur(amount: 100)
        blur.blurType = .motion
        let xs = 24..<(w - 24)
        let across = SIMD2(1, 0), down = SIMD2(0, 1)
        let v0 = try TextureReadback.float16Pixels(of: vertical, gpu: gpu)
        let h0 = try TextureReadback.float16Pixels(of: horizontal, gpu: gpu)
        let vBlurred = try lensBlur(vertical, blur, depth: false, gpu: gpu)
        let hBlurred = try lensBlur(horizontal, blur, depth: false, gpu: gpu)
        XCTAssertLessThan(detail(vBlurred, width: w, height: h, xs: xs, step: across),
                          0.1 * detail(v0, width: w, height: h, xs: xs, step: across))
        XCTAssertGreaterThan(detail(hBlurred, width: w, height: h, xs: xs, step: down),
                             0.8 * detail(h0, width: w, height: h, xs: xs, step: down))
        blur.motionAngle = 90
        let hVertical = try lensBlur(horizontal, blur, depth: false, gpu: gpu)
        XCTAssertLessThan(detail(hVertical, width: w, height: h, xs: xs, step: down),
                          0.1 * detail(h0, width: w, height: h, xs: xs, step: down))
    }
}
