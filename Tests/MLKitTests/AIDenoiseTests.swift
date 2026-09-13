import XCTest
import Metal
@testable import MLKit
@testable import PixelEngine
@testable import RawCore

final class AIDenoiseTests: XCTestCase {
    /// The model itself: a flat grey field with Gaussian noise comes out
    /// far flatter, and clipped pixels are handed back untouched.
    func testDenoisesSyntheticNoise() async throws {
        try XCTSkipUnless(AIDenoiser.isAvailable, "NAFNet package not bundled")
        let denoiser = try await AIDenoiser.load()
        let w = 300, h = 280   // not a tile multiple: exercises edge tiles and overlap
        var pixels = [Float16](repeating: 0, count: w * h * 4)
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Float {
            let u1 = Float.random(in: 0.0001...1, using: &rng), u2 = Float.random(in: 0...1, using: &rng)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        for i in 0..<(w * h) {
            for c in 0..<3 { pixels[i * 4 + c] = Float16(max(0, 0.3 + 0.04 * gauss())) }
            pixels[i * 4 + 3] = 1
        }
        // A clipped block in the corner.
        for y in 0..<20 { for x in 0..<20 { for c in 0..<3 { pixels[((y * w) + x) * 4 + c] = 1.5 } } }

        final class Counter: @unchecked Sendable { var reported = 0; var total = 0 }
        let counter = Counter()
        let out = try await denoiser.denoise(pixels, width: w, height: h) { done, total in
            counter.reported = max(counter.reported, done); counter.total = total
        }
        XCTAssertEqual(counter.reported, 4); XCTAssertEqual(counter.total, 4, "2x2 tiles at this size")

        func stdDev(_ px: [Float16], skipClipped: Bool) -> Float {
            var sum: Float = 0, sum2: Float = 0, n: Float = 0
            for i in 0..<(w * h) where !(skipClipped && Float(px[i * 4]) > 1) {
                let v = Float(px[i * 4 + 1]); sum += v; sum2 += v * v; n += 1
            }
            let mean = sum / n
            return (sum2 / n - mean * mean).squareRoot()
        }
        let before = stdDev(pixels, skipClipped: true), after = stdDev(out, skipClipped: true)
        XCTAssertLessThan(after, before * 0.4, "noise std \(before) -> \(after)")
        XCTAssertEqual(Float(out[0]), 1.5, "clipped pixels pass through")
        // A pixel with one channel clipped and the others not must come
        // back whole: either all original or all denoised, never mixed
        // per channel (that mixing is a coloured grid on screen).
        var mixed = pixels
        let j = (150 * w + 150) * 4
        mixed[j] = 1.2; mixed[j + 1] = 0.3; mixed[j + 2] = 0.3
        let out2 = try await denoiser.denoise(mixed, width: w, height: h, white: 1)
        XCTAssertEqual(Float(out2[j]), 1.2, accuracy: 1e-3); XCTAssertEqual(Float(out2[j + 1]), 0.3, accuracy: 1e-3); XCTAssertEqual(Float(out2[j + 2]), 0.3, accuracy: 1e-3)
        // Mean preserved (no brightness shift from the gamma round trip).
        var meanIn: Float = 0, meanOut: Float = 0
        for i in 400..<(w * h) { meanIn += Float(pixels[i * 4 + 1]); meanOut += Float(out[i * 4 + 1]) }
        XCTAssertEqual(meanOut / meanIn, 1, accuracy: 0.03)
    }

    /// End to end on the sample NEF: the worker fills the session, the
    /// pipeline blends it, and strength 1 shows less pixel-to-pixel noise
    /// than strength 0 while strength 0 is bit-identical to no denoise.
    func testPipelineBlendsTheResult() async throws {
        let path = AIMaskTests.assetPath("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        try XCTSkipUnless(AIDenoiser.isAvailable, "NAFNet package not bundled")
        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        func highFreq(_ p: EditParameters) throws -> ([Float16], Float) {
            let tex = try pipeline.render(session, scale: .region(x: 1000, y: 1000, width: 512, height: 512),
                                          parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            var hf: Float = 0
            for i in stride(from: 8 * 512 * 4, to: px.count - 4, by: 4) {
                hf += abs(Float(px[i + 1]) - Float(px[i + 5]))
            }
            return (px, hf)
        }
        let (basePx, baseHF) = try highFreq(EditParameters())

        let denoiser = try await AIDenoiser.load()
        let seconds = try await AIDenoiseWorker.run(session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser)
        XCTAssertNotNil(session.aiDenoisedCameraRGB)
        print("full-frame denoise: \(seconds) s")

        var off = EditParameters(); off.aiDenoise = 0
        XCTAssertEqual(try highFreq(off).0, basePx, "strength 0 is a no-op even with a result cached")
        var on = EditParameters(); on.aiDenoise = 1
        let (_, onHF) = try highFreq(on)
        XCTAssertLessThan(onHF, baseHF * 0.85, "high-frequency energy \(baseHF) -> \(onHF)")
        var half = EditParameters(); half.aiDenoise = 0.5
        let (_, halfHF) = try highFreq(half)
        XCTAssertLessThan(halfHF, baseHF); XCTAssertGreaterThan(halfHF, onHF)
    }
}
