import XCTest
@testable import PixelEngine
@testable import RawCore

final class AutoAdjustTests: XCTestCase {
    /// Applying the suggestion should put the scene's geometric mean
    /// brightness near the grey point — that's the definition of what
    /// the exposure estimate does — and the other outputs must be sane.
    func testSuggestionCentresTheSceneOnGrey() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

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
}
