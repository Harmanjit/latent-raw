import XCTest
@testable import MLKit

/// The denoiser's tiling keeps its weighted sums for one band of rows
/// rather than the whole frame; it must blend exactly as the full-frame
/// sums did. And exports share one loaded network instead of loading it
/// per image.
final class AIDenoiseBandTests: XCTestCase {
    /// A stand-in for the network whose answer depends on where in the
    /// tile a pixel sits, so overlapping tiles disagree and the blend
    /// weights matter.
    @Sendable static func fakeTile(_ input: [Float]) -> [Float] {
        let t = AIDenoiser.tile
        var out = AIDenoiser.unpack(input)
        for c in 0..<3 {
            for y in 0..<t {
                for x in 0..<t { out[c * t * t + y * t + x] += 0.05 * Float((x + 3 * y + c) % 17) / 17 }
            }
        }
        return out
    }

    /// The pre-band assembly: full-frame sums, tiles in order.
    static func fullFrame(_ pixels: [Float16], width: Int, height: Int, white: Float) -> [Float16] {
        let t = AIDenoiser.tile, o = AIDenoiser.overlap, stride = t - o
        let cols = max(1, Int(ceil(Double(max(width - o, 1)) / Double(stride))))
        let rows = max(1, Int(ceil(Double(max(height - o, 1)) / Double(stride))))
        var accum = [Float](repeating: 0, count: width * height * 3)
        var weight = [Float](repeating: 0, count: width * height)
        let ramp: [Float] = (0..<t).map { i in min(1, min(Float(i) + 0.5, Float(t - i) - 0.5) / Float(o)) }
        for i in 0..<(cols * rows) {
            let x0 = min((i % cols) * stride, max(0, width - t)), y0 = min((i / cols) * stride, max(0, height - t))
            let out = fakeTile(AIDenoiser.packTile(pixels, width: width, height: height, x0: x0, y0: y0, white: white))
            AIDenoiser.accumulate(out, into: &accum, weight: &weight, ramp: ramp, width: width, height: height, x0: x0, y0: y0)
        }
        var result = pixels
        for i in 0..<(width * height) where weight[i] > 0 {
            let peak = max(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2])) / white
            let keep = AIDenoiser.smoothstep(0.85, 1.0, peak)
            if keep >= 1 { continue }
            for c in 0..<3 {
                let original = Float(pixels[i * 4 + c])
                let denoised = AIDenoiser.decode(accum[i * 3 + c] / weight[i]) * white
                result[i * 4 + c] = Float16(denoised + (original - denoised) * keep)
            }
        }
        return result
    }

    func testBandedAssemblyMatchesFullFrame() async throws {
        var rng = SystemRandomNumberGenerator()
        // Many rows and columns, one column of many rows (tiles of later
        // rows finish before the band reaches them), exactly one tile,
        // smaller than a tile, and a last row pulled up against the edge.
        for (w, h) in [(1000, 700), (200, 900), (256, 256), (100, 50), (300, 280), (481, 257)] {
            var pixels = [Float16](repeating: 1, count: w * h * 4)
            for i in 0..<(w * h) { for c in 0..<3 { pixels[i * 4 + c] = Float16(Float.random(in: 0...1.2, using: &rng)) } }
            let expected = Self.fullFrame(pixels, width: w, height: h, white: 1.1)
            final class Count: @unchecked Sendable { var done = 0 }
            let count = Count()
            let got = try await AIDenoiser.assemble(pixels, width: w, height: h, white: 1.1,
                                                    progress: { done, _ in count.done = done },
                                                    runTile: Self.fakeTile)
            XCTAssertEqual(got.count, expected.count)
            var worst: Float = 0
            for i in 0..<got.count { worst = max(worst, abs(Float(got[i]) - Float(expected[i]))) }
            XCTAssertLessThan(worst, 2e-3, "\(w)x\(h)")
            XCTAssertNotEqual(got, pixels, "\(w)x\(h): the stand-in changed something")
            XCTAssertGreaterThan(count.done, 0)
        }
    }

    /// One loaded network per variant, until released.
    func testSharedDenoiserIsReusedUntilReleased() async throws {
        try XCTSkipUnless(AIDenoiser.isAvailable, "NAFNet package not bundled")
        let a = try await AIDenoiser.shared(.standard)
        let b = try await AIDenoiser.shared(.standard)
        XCTAssertTrue(a === b, "a second export reuses the loaded network")
        ModelRegistry.shared.releaseAll()
        let c = try await AIDenoiser.shared(.standard)
        XCTAssertFalse(a === c, "memory pressure lets it go")
        AIDenoiser.releaseShared()
    }
}
