import XCTest
@testable import PixelEngine
@testable import RawCore

/// Sharpening must raise local contrast; denoising must lower it.
/// Measured as the mean absolute horizontal difference between
/// neighbouring pixels of a full-resolution tile — a plain proxy for
/// "how much fine detail (or noise) is there".
final class DetailTests: XCTestCase {
    func roughness(_ pixels: [Float16], width: Int, height: Int) -> Double {
        var sum = 0.0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let i = (y * width + x) * 4
                sum += abs(Double(pixels[i + 1]) - Double(pixels[i + 5]))
            }
        }
        return sum / Double(height * (width - 1))
    }

    func testSharpenRaisesAndDenoiseLowersLocalContrast() throws {
        let path = try TestAssets.d750Path()

        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let scale = RenderScale.region(x: 2000, y: 1500, width: 512, height: 384)

        func measure(_ p: EditParameters) throws -> Double {
            let tex = try pipeline.render(session, scale: scale, parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            return roughness(px, width: tex.width, height: tex.height)
        }

        let plain = try measure(EditParameters())

        var sharp = EditParameters()
        sharp.sharpenAmount = 1.5
        sharp.sharpenRadius = 1.0
        sharp.sharpenThreshold = 0
        XCTAssertGreaterThan(try measure(sharp), plain * 1.15, "sharpening should add local contrast")

        var smooth = EditParameters()
        smooth.denoiseLuminance = 1.0
        smooth.denoiseColor = 1.0
        XCTAssertLessThan(try measure(smooth), plain * 0.9, "denoise should remove local contrast")

        // Off means off: identical pixels to the plain render.
        var off = EditParameters()
        off.sharpenAmount = 0
        off.denoiseLuminance = 0
        XCTAssertEqual(try measure(off), plain, accuracy: 1e-9)
    }

    func testGaussianWeightsAreNormalizedAndSymmetric() {
        let w = RenderPipeline.gaussianWeights(sigma: 1.2)
        XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(w.count % 2, 1)
        XCTAssertEqual(w.first!, w.last!, accuracy: 1e-7)
        XCTAssertLessThanOrEqual(RenderPipeline.gaussianWeights(sigma: 20).count, 33)
    }
}
