import XCTest
@testable import PixelEngine
@testable import RawCore

final class AutoAdjustTests: XCTestCase {
    /// Applying the suggestion should put the scene's geometric mean
    /// brightness near the grey point — that's the definition of what
    /// the exposure estimate does — and the other outputs must be sane.
    func testSuggestionCentresTheSceneOnGrey() throws {
        let path = try TestAssets.d750Path()

        let file = try RawFile(path: path)
        let gpu = try GPUContext()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        var params = EditParameters()
        params.whiteBalance = session.asShotWhiteBalance
        let suggestion = try AutoAdjust.suggest(for: session, pipeline: pipeline, gpu: gpu,
                                                current: params)
        XCTAssertTrue(suggestion.exposureEV.isFinite)
        XCTAssertTrue((-3...3).contains(suggestion.exposureEV))
        XCTAssertTrue((1.0...2.2).contains(suggestion.contrast))
        let wb = try XCTUnwrap(suggestion.whiteBalance)
        XCTAssertTrue((2000...12000).contains(wb.temperature))

        // Re-measure with the suggested exposure applied.
        params.exposureEV = suggestion.exposureEV
        let linear = try pipeline.render(session, scale: .binned(quads: 4), parameters: params,
                                         output: .sceneLinear)
        let px = try TextureReadback.float16Pixels(of: linear, gpu: gpu)
        var sumLog: Float = 0, n = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let y = 0.2627 * Float(px[i]) + 0.6780 * Float(px[i + 1]) + 0.0593 * Float(px[i + 2])
            if y > 1e-4 { sumLog += log2(y); n += 1 }
        }
        let meanY = pow(2, sumLog / Float(n))
        // Either on grey, or held back by the highlight guard (then below).
        XCTAssertLessThanOrEqual(meanY, params.greyPoint * 1.1)
        XCTAssertGreaterThan(meanY, params.greyPoint * 0.2)
    }

    /// Scene-linear analysis renders skip colour grading: the tone curve's
    /// table clamps to [0,1], so with a curve set Auto under-read the
    /// highlights, and HSL, vibrance and split toning moved its estimates.
    /// The same image with and without a look must measure the same.
    func testSceneLinearRenderIgnoresGrading() throws {
        let gpu = try GPUContext()
        let file = try RawFile(path: LinearFixtures.path(LinearFixtures.ramp))
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        var plain = EditParameters()
        plain.exposureEV = 1   // pushes the ramp's top above 1.0 scene-linear
        var graded = plain
        graded.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.25, 0.18), SIMD2(0.75, 0.84), SIMD2(1, 1)])
        var hsl = HSLAdjustments.neutral
        hsl.saturation[0] = -1; hsl.hue[2] = 0.4
        graded.hsl = hsl
        graded.vibrance = 0.5
        graded.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.3,
                                         highlightHue: 45, highlightSaturation: 0.25, balance: 0.1)

        func linear(_ p: EditParameters) throws -> [Float16] {
            try TextureReadback.float16Pixels(
                of: pipeline.render(session, scale: AutoAdjust.analysisScale, parameters: p, output: .sceneLinear),
                gpu: gpu)
        }
        let a = try linear(plain), b = try linear(graded)
        XCTAssertGreaterThan(a.map { Float($0) }.max() ?? 0, 1.2, "the test needs values above 1.0")
        XCTAssertEqual(a, b, "grading must not touch a scene-linear render")

        let s1 = try AutoAdjust.suggest(for: session, pipeline: pipeline, gpu: gpu, current: plain)
        let s2 = try AutoAdjust.suggest(for: session, pipeline: pipeline, gpu: gpu, current: graded)
        XCTAssertEqual(s1, s2)
    }
}
