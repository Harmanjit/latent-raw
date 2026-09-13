import XCTest
@testable import PixelEngine
@testable import RawCore
import LensKit

/// The 50mm f/1.4G sample at f/5: a profile with distortion, TCA and
/// vignetting. Corrections must be on by default, switch off cleanly,
/// and do what they say.
final class LensCorrectionTests: XCTestCase {
    func testProfileResolvesAndVignettingBrightensCorners() throws {
        let path = TestAssets.path("HSB_2615.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        let correction = try XCTUnwrap(session.lensCorrection)
        XCTAssertTrue(correction.profileName.contains("50mm"), correction.profileName)
        XCTAssertNotNil(correction.vignetting)
        XCTAssertNotNil(correction.distortion)

        func cornerToCentre(_ p: EditParameters) throws -> (ratio: Double, centre: [Float]) {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p,
                                          output: .sceneLinear)
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            let w = tex.width, h = tex.height
            func luma(_ x: Int, _ y: Int) -> Double {
                let i = (y * w + x) * 4
                return Double(px[i]) * 0.2627 + Double(px[i + 1]) * 0.678 + Double(px[i + 2]) * 0.0593
            }
            // Average a small patch to ride over noise.
            func patch(_ cx: Int, _ cy: Int) -> Double {
                var s = 0.0
                for dy in -3...3 { for dx in -3...3 { s += luma(cx + dx, cy + dy) } }
                return s / 49
            }
            let corner = patch(12, 12) + patch(w - 13, 12) + patch(12, h - 13) + patch(w - 13, h - 13)
            let centre = patch(w / 2, h / 2)
            let i = ((h / 2) * w + w / 2) * 4
            return (corner / 4 / centre, [Float(px[i]), Float(px[i + 1]), Float(px[i + 2])])
        }

        var off = EditParameters()
        off.lensDistortion = false; off.lensTCA = false; off.lensVignetting = false
        var vignettingOnly = off
        vignettingOnly.lensVignetting = true

        let before = try cornerToCentre(off)
        let after = try cornerToCentre(vignettingOnly)
        XCTAssertGreaterThan(after.ratio, before.ratio * 1.05,
                             "corners should brighten relative to the centre")
        // Vignetting correction is 1.0 at the centre: the centre pixel is unchanged.
        for c in 0..<3 {
            XCTAssertEqual(after.centre[c], before.centre[c], accuracy: max(0.01, before.centre[c] * 0.02))
        }
    }

    func testStageIsSkippedWhenEverythingIsOff() throws {
        let path = TestAssets.path("HSB_2615.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        var off = EditParameters()
        off.lensDistortion = false; off.lensTCA = false; off.lensVignetting = false
        XCTAssertFalse(RenderPipeline.wantsLensCorrection(session: session, parameters: off))
        XCTAssertTrue(RenderPipeline.wantsLensCorrection(session: session, parameters: EditParameters()))
        off.manualVignetting = 0.3
        XCTAssertTrue(RenderPipeline.wantsLensCorrection(session: session, parameters: off))
    }
}
