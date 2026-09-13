import XCTest
@testable import PixelEngine
@testable import RawCore

final class GradingTests: XCTestCase {
    func testIdentityCurveLUTIsLinearAndMonotone() {
        let lut = ToneCurve.identity.lookupTable()
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut[0], 0, accuracy: 1e-6)
        XCTAssertEqual(lut[255], 1, accuracy: 1e-6)
        XCTAssertEqual(lut[128], 128.0 / 255.0, accuracy: 1e-4)

        // An S-curve stays monotone (no overshoot between points) and
        // passes through its control points.
        let s = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.25, 0.15), SIMD2(0.75, 0.85), SIMD2(1, 1)])
        let l = s.lookupTable()
        for i in 1..<256 { XCTAssertGreaterThanOrEqual(l[i], l[i - 1] - 1e-6) }
        XCTAssertEqual(l[Int(0.25 * 255)], 0.15, accuracy: 0.01)
        XCTAssertEqual(l[Int(0.75 * 255)], 0.85, accuracy: 0.01)
        XCTAssertLessThan(l[64], 64.0 / 255.0, "S-curve darkens the quarter tone")
    }

    func testEditStackRoundTripsGrading() throws {
        var p = EditParameters()
        p.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.4), SIMD2(1, 1)])
        p.hsl.saturation[5] = 0.6
        p.hsl.hue[1] = -0.3
        p.splitToning = SplitToning(shadowHue: 210, shadowSaturation: 0.3, highlightHue: 40,
                                    highlightSaturation: 0.2, balance: 0.1)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"splittoning\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    func testGradingEffectsOnARealImage() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        struct Stats { var meanLuma: Double; var meanChroma: Double; var brightWarmth: Double }
        func stats(_ p: EditParameters) throws -> Stats {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            var luma = 0.0, chroma = 0.0, warm = 0.0, bright = 0
            let n = px.count / 4
            for i in stride(from: 0, to: px.count, by: 4) {
                let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luma += l
                chroma += max(r, g, b) - min(r, g, b)
                if l > 0.6 { warm += r - b; bright += 1 }
            }
            return Stats(meanLuma: luma / Double(n), meanChroma: chroma / Double(n),
                         brightWarmth: bright > 0 ? warm / Double(bright) : 0)
        }

        let plain = try stats(EditParameters())

        // Neutral grading is bit-for-bit the same as no grading (it's skipped).
        var neutral = EditParameters()
        neutral.hsl = .neutral; neutral.splitToning = .neutral; neutral.toneCurve = .identity
        let n = try stats(neutral)
        XCTAssertEqual(n.meanLuma, plain.meanLuma, accuracy: 1e-9)

        // A curve pulled down darkens.
        var dark = EditParameters()
        dark.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 1)])
        XCTAssertLessThan(try stats(dark).meanLuma, plain.meanLuma * 0.9)

        // Desaturating every band removes nearly all chroma.
        var grey = EditParameters()
        grey.hsl.saturation = Array(repeating: -1, count: 8)
        XCTAssertLessThan(try stats(grey).meanChroma, plain.meanChroma * 0.15)

        // Warm highlights: bright pixels get redder than bluer.
        var toned = EditParameters()
        toned.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0, highlightHue: 40,
                                        highlightSaturation: 1, balance: 0)
        XCTAssertGreaterThan(try stats(toned).brightWarmth, plain.brightWarmth + 0.02)
    }
}
