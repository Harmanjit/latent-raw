import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// The new render stages on the sample NEF: off is exactly off, and on
/// does what its control says.
final class DetailEffectsRenderTests: XCTestCase {
    private var gpu: GPUContext!
    private var session: ImageSession!
    private var pipeline: RenderPipeline!

    override func setUpWithError() throws {
        let path = try TestAssets.d750Path()
        gpu = try GPUContext()
        session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        pipeline = RenderPipeline(gpu: gpu)
    }

    private struct Image {
        var pixels: [Float16]
        var width: Int, height: Int
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
        }
        func luma(_ x: Int, _ y: Int) -> Float { simd_dot(rgb(x, y), SIMD3(0.2126, 0.7152, 0.0722)) }
        /// Mean absolute difference between horizontal neighbours' luma.
        var roughness: Double {
            var sum = 0.0
            for y in 0..<height { for x in 0..<(width - 1) { sum += Double(abs(luma(x, y) - luma(x + 1, y))) } }
            return sum / Double(height * (width - 1))
        }
        /// The same for the red-minus-green difference: colour noise.
        var colourRoughness: Double {
            var sum = 0.0
            for y in 0..<height {
                for x in 0..<(width - 1) {
                    let a = rgb(x, y), b = rgb(x + 1, y)
                    sum += Double(abs((a.x - a.y) - (b.x - b.y)))
                }
            }
            return sum / Double(height * (width - 1))
        }
        func meanLuma(in r: (x: Range<Int>, y: Range<Int>)) -> Float {
            var s: Float = 0, n: Float = 0
            for y in r.y { for x in r.x { s += luma(x, y); n += 1 } }
            return s / n
        }
    }

    private func render(_ p: EditParameters, scale: RenderScale = .region(x: 2000, y: 1500, width: 384, height: 256),
                        output: RenderOutput = .file(.sRGB)) throws -> Image {
        let tex = try pipeline.render(session, scale: scale, parameters: p, output: output)
        return Image(pixels: try TextureReadback.float16Pixels(of: tex, gpu: gpu), width: tex.width, height: tex.height)
    }

    // MARK: - Off is off

    /// Every new control at its neutral value, with the stage it belongs
    /// to running, renders the same pixels as the edit without them.
    func testNeutralControlsChangeNothing() throws {
        var base = EditParameters()
        base.sharpenAmount = 1; base.denoiseLuminance = 0.5; base.denoiseColor = 0.5
        base.defringePurple = 0.6; base.manualVignetting = 0.4
        let plain = try render(base)

        var same = base
        same.sharpenDetail = SharpenRefinement.neutralDetail
        same.sharpenMasking = SharpenRefinement.neutralMasking
        same.noiseDetail = .neutral
        same.defringeHues = .standard
        same.manualVignettingMidpoint = ManualVignettingShape.neutralMidpoint
        same.grain = Grain(amount: 0, size: 0.9, roughness: 0.9)               // sliders moved, amount 0
        same.postCropVignette = PostCropVignette(style: .colourPriority, amount: 0, midpoint: 0.1)
        XCTAssertEqual(try render(same).pixels, plain.pixels)
    }

    // MARK: - Grain

    func testGrainAddsTextureAndIsFixedToThePhoto() throws {
        let plain = try render(EditParameters())
        var p = EditParameters(); p.grain = Grain(amount: 0.6)
        let grained = try render(p)
        XCTAssertGreaterThan(grained.roughness, plain.roughness * 1.2, "grain adds fine texture")
        XCTAssertEqual(grained.meanLuma(in: (0..<grained.width, 0..<grained.height)),
                       plain.meanLuma(in: (0..<plain.width, 0..<plain.height)), accuracy: 0.01,
                       "and leaves the overall brightness")
        XCTAssertEqual(try render(p).pixels, grained.pixels, "the same grain every time")

        // The pattern belongs to the sensor position, not to the render: a
        // region shifted by 64 pixels shows the same grains 64 pixels over.
        let shifted = try render(p, scale: .region(x: 2064, y: 1500, width: 384, height: 256))
        let plainShifted = try render(EditParameters(), scale: .region(x: 2064, y: 1500, width: 384, height: 256))
        var worst: Float = 0
        for y in 20..<236 {
            for x in 84..<364 {
                let a = grained.luma(x, y) - plain.luma(x, y)
                let b = shifted.luma(x - 64, y) - plainShifted.luma(x - 64, y)
                worst = max(worst, abs(a - b))
            }
        }
        XCTAssertLessThan(worst, 0.004, "grain at a sensor position is the same in any render")

        // Rougher grain has more fine detail than smooth grain of the same amount.
        var rough = p; rough.grain.roughness = 1
        var smooth = p; smooth.grain.roughness = 0
        XCTAssertGreaterThan(try render(rough).roughness, try render(smooth).roughness)
    }

    // MARK: - Post-crop vignetting

    func testPostCropVignetteFollowsTheCrop() throws {
        // The crop is the left half of the frame; its centre is at 25 %.
        var p = EditParameters()
        p.crop = CropParameters(centre: [0.25, 0.5], size: [0.5, 1])
        let plain = try render(p, scale: .binned(quads: 4))
        p.postCropVignette = PostCropVignette(amount: -1, feather: 0.3)
        let dark = try render(p, scale: .binned(quads: 4))
        let w = dark.width, h = dark.height
        func ratio(atX fx: Double, y fy: Double) -> Float {
            let x = Int(Double(w) * fx), y = Int(Double(h) * fy)
            let r = (x - 2..<x + 3, y - 2..<y + 3)
            return dark.meanLuma(in: r) / max(plain.meanLuma(in: r), 1e-4)
        }
        XCTAssertEqual(ratio(atX: 0.25, y: 0.5), 1, accuracy: 0.01, "the crop's centre is untouched")
        XCTAssertLessThan(ratio(atX: 0.02, y: 0.03), 0.6, "the crop's corner is darkened")
        XCTAssertLessThan(ratio(atX: 0.48, y: 0.97), 0.6, "so is its other corner, at the frame's middle")

        // Lightening, colour priority: the corner brightens and keeps its hue.
        p.postCropVignette = PostCropVignette(style: .colourPriority, amount: 0.8, feather: 0.3)
        let light = try render(p, scale: .binned(quads: 4))
        let x = Int(Double(w) * 0.03), y = Int(Double(h) * 0.04)
        XCTAssertGreaterThan(light.luma(x, y), plain.luma(x, y))
    }

    func testHighlightsSliderProtectsBrightAreas() throws {
        var p = EditParameters()
        p.exposureEV = 2   // plenty of bright pixels
        let plain = try render(p, scale: .binned(quads: 4))
        p.postCropVignette = PostCropVignette(amount: -1, midpoint: 0, feather: 1)
        let unprotected = try render(p, scale: .binned(quads: 4))
        p.postCropVignette.highlights = 1
        let protected_ = try render(p, scale: .binned(quads: 4))
        let all = (0..<plain.width, 0..<plain.height)
        XCTAssertLessThan(unprotected.meanLuma(in: all), plain.meanLuma(in: all))
        XCTAssertGreaterThan(protected_.meanLuma(in: all), unprotected.meanLuma(in: all))
    }

    // MARK: - Sharpening

    func testSharpeningDetailAndMasking() throws {
        var p = EditParameters()
        p.sharpenAmount = 1.5; p.sharpenThreshold = 0
        let full = try render(p)
        var lowDetail = p; lowDetail.sharpenDetail = 0
        XCTAssertLessThan(try render(lowDetail).roughness, full.roughness, "halo suppression takes some edge out")
        var masked = p; masked.sharpenMasking = 1
        let maskedImage = try render(masked)
        XCTAssertLessThan(maskedImage.roughness, full.roughness, "masking leaves smooth areas alone")
        XCTAssertGreaterThan(maskedImage.roughness, try render(EditParameters()).roughness * 0.999)

        // The preview shows the mask: grey levels, white where sharpened.
        var output = RenderOutput.file(.sRGB)
        output.sharpenMaskPreview = true
        var previewEdit = p; previewEdit.sharpenMasking = 0.25
        let mask = try render(previewEdit, output: output)
        var white = 0, black = 0
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let c = mask.rgb(x, y)
                XCTAssertEqual(c.x, c.y, accuracy: 1e-3); XCTAssertEqual(c.y, c.z, accuracy: 1e-3)
                if c.x > 0.9 { white += 1 } else if c.x < 0.01 { black += 1 }
            }
        }
        XCTAssertGreaterThan(white, 0, "edges are in the mask")
        XCTAssertGreaterThan(black, 0, "smooth areas are not")
    }

    // MARK: - Noise reduction

    func testNoiseReductionDetailContrastAndSmoothness() throws {
        var p = EditParameters()
        p.denoiseLuminance = 0.8; p.denoiseColor = 0.8
        let base = try render(p)

        var detailed = p; detailed.noiseDetail.luminanceDetail = 1
        var loose = p; loose.noiseDetail.luminanceDetail = 0
        XCTAssertGreaterThan(try render(detailed).roughness, try render(loose).roughness,
                             "more detail keeps more fine texture")

        var contrast = p; contrast.noiseDetail.luminanceContrast = 1
        XCTAssertGreaterThan(try render(contrast).roughness, base.roughness, "contrast puts texture back")

        var smooth = p; smooth.noiseDetail.colourSmoothness = 1
        XCTAssertLessThan(try render(smooth).colourRoughness, base.colourRoughness, "smoothness evens colour")

        // The heal cache keys on these too: changing one after a render
        // must render again, not reuse the last result.
        XCTAssertNotEqual(try render(detailed).pixels, try render(loose).pixels)
    }

    // MARK: - Lens

    func testManualVignettingMidpoint() throws {
        var p = EditParameters()
        p.lensVignetting = false; p.lensDistortion = false; p.lensTCA = false
        p.manualVignetting = 0.8
        var wide = p; wide.manualVignettingMidpoint = 0
        var corners = p; corners.manualVignettingMidpoint = 1
        let a = try render(wide, scale: .binned(quads: 4)), b = try render(corners, scale: .binned(quads: 4))
        // Halfway to the corner, the low midpoint has brightened more.
        let x = a.width / 4, y = a.height / 4
        let r = (x - 3..<x + 4, y - 3..<y + 4)
        XCTAssertGreaterThan(a.meanLuma(in: r), b.meanLuma(in: r) * 1.02)
    }

    func testDefringeHueRangesAreUsed() throws {
        var p = EditParameters()
        p.defringePurple = 1; p.defringeGreen = 1
        let standard = try render(p, scale: .binned(quads: 4))
        p.defringeHues = DefringeHueRanges(purpleLow: 200, purpleHigh: 360, greenLow: 40, greenHigh: 200)
        XCTAssertNotEqual(try render(p, scale: .binned(quads: 4)).pixels, standard.pixels,
                          "wider ranges catch more colours")
    }

    func testAutomaticChromaticAberration() throws {
        var p = EditParameters()
        p.lensTCA = false; p.lensDistortion = false; p.lensVignetting = false
        let plain = try render(p, scale: .region(x: 100, y: 100, width: 256, height: 256))
        p.autoCA = AutoChromaticAberration(red: 0.0015, blue: -0.0015)
        XCTAssertTrue(RenderPipeline.wantsLensCorrection(session: session, parameters: p))
        let corrected = try render(p, scale: .region(x: 100, y: 100, width: 256, height: 256))
        XCTAssertNotEqual(corrected.pixels, plain.pixels, "red and blue are resampled near the corner")

        // The measurement on a real photo is finite and small, or declines.
        let tiles = try ChromaticAberrationEstimator.captureTiles(session: session, pipeline: pipeline,
                                                                  parameters: EditParameters())
        XCTAssertEqual(tiles.count, 24)
        if let found = ChromaticAberrationEstimator.estimate(tiles: tiles) {
            XCTAssertLessThanOrEqual(abs(found.red), AutoChromaticAberration.limit)
            XCTAssertLessThanOrEqual(abs(found.blue), AutoChromaticAberration.limit)
        }
    }
}
