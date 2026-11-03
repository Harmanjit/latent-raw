import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// Saturation, Black & White, three-way Colour Grading, Calibration and
/// Point Colour (ColourControls.swift): the stored form, the maths done on
/// the CPU, and their effect on a real render.
final class ColourControlsTests: XCTestCase {
    static func everything() -> EditParameters {
        var p = EditParameters()
        p.colour.saturation = -0.35
        p.colour.blackAndWhite = BlackAndWhite(enabled: true, mix: [0.2, 0.1, 0, -0.3, 0, -0.5, 0, 0.4])
        p.colour.grading = ColourGrading(midtones: GradingWheel(hue: 120, saturation: 0.3, luminance: 0.1),
                                         global: GradingWheel(hue: 40, saturation: 0.1, luminance: -0.05),
                                         shadowLuminance: -0.2, highlightLuminance: 0.15, blending: 0.7)
        p.colour.calibration = Calibration(shadowTint: 0.2, redHue: 0.3, redSaturation: -0.2,
                                           greenHue: -0.1, greenSaturation: 0.4, blueHue: 0.5, blueSaturation: 0.1)
        p.colour.pointColours = [PointColour(hue: 25, saturation: 0.5, value: 0.7, hueShift: 0.2,
                                             saturationShift: -0.3, luminanceShift: 0.1, range: 0.6, variance: -0.4)]
        p.splitToning = SplitToning(shadowHue: 210, shadowSaturation: 0.3, highlightHue: 40,
                                    highlightSaturation: 0.2, balance: 0.1)
        return p
    }

    // MARK: - Stored form

    /// Every new field survives a save and reload, and the round-tripped
    /// edit is the same edit.
    func testRoundTripThroughJSON() throws {
        let p = Self.everything()
        let json = try EditStack(parameters: p).encodeJSON()
        for key in ["\"saturation\"", "\"blackwhite\"", "\"colorgrading\"", "\"calibration\"", "\"pointcolor\""] {
            XCTAssertTrue(json.contains(key), key)
        }
        let stack = try EditStack.decode(json: json)
        XCTAssertEqual(stack.schema, EditStack.schemaVersion, "the schema number is not bumped")
        XCTAssertEqual(stack.parameters(), p)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    /// A neutral edit writes none of the new keys, so it encodes exactly as
    /// it did before they existed, and an old edit reads them as neutral.
    func testNeutralWritesNothingNewAndOldEditsReadNeutral() throws {
        let json = try EditStack(parameters: EditParameters()).encodeJSON()
        for key in ["blackwhite", "colorgrading", "calibration", "pointcolor"] {
            XCTAssertFalse(json.contains(key), key)
        }
        XCTAssertFalse(json.contains("\"saturation\":{"), "no saturation module")
        let old = """
        {"schema":1,"process":"1.0","modules":{"splittoning":{"shadowHue":215,"shadowSaturation":0.3,\
        "highlightHue":45,"highlightSaturation":0.25,"balance":0.1}}}
        """
        let p = try EditStack.decode(json: old).parameters()
        XCTAssertEqual(p.colour, .neutral)
        XCTAssertEqual(p.splitToning.shadowSaturation, 0.3)
        XCTAssertEqual(ColourExtrasGPU(p.colour, splitBalance: p.splitToning.balance).info.x, 0,
                       "an old split-toning edit takes the old shader path")
    }

    /// Hand-edited or partial modules load with defaults and in range.
    func testLenientAndSanitisedDecoding() throws {
        let json = """
        {"schema":1,"process":"1.0","modules":{"saturation":{"amount":7},\
        "blackwhite":{"enabled":true,"mix":[1,2]},"colorgrading":{"blending":-3,"midtones":{"saturation":0.4}},\
        "calibration":{"redHue":0.5},"pointcolor":[{"hue":-30,"saturation":2,"value":0.5,"hueShift":0.5}]}}
        """
        let c = try EditStack.decode(json: json).parameters().colour
        XCTAssertEqual(c.saturation, 1)
        XCTAssertTrue(c.blackAndWhite.enabled)
        XCTAssertEqual(c.blackAndWhite.mix, BlackAndWhite.neutralMix, "a mix of the wrong length is dropped")
        XCTAssertEqual(c.grading.blending, 0)
        XCTAssertEqual(c.grading.midtones.saturation, 0.4)
        XCTAssertEqual(c.calibration.redHue, 0.5)
        XCTAssertEqual(c.calibration.greenHue, 0)
        XCTAssertEqual(c.pointColours.first?.hue, 330)
        XCTAssertEqual(c.pointColours.first?.saturation, 1)
        XCTAssertEqual(c.pointColours.first?.range, PointColour.defaultRange)
    }

    /// Copy and paste: Saturation, B&W and Point Colour ride with Colour;
    /// Colour Grading with Split Toning; Calibration has its own group.
    func testGroups() {
        let stack = EditStack(parameters: Self.everything())
        XCTAssertTrue(stack.presentGroups.isSuperset(of: [.colour, .splitToning, .calibration]))
        XCTAssertTrue(EditGroup.lookGroups.contains(.calibration))

        let colour = EditStack().merged(with: stack, groups: [.colour]).parameters().colour
        XCTAssertEqual(colour.saturation, -0.35)
        XCTAssertTrue(colour.blackAndWhite.enabled)
        XCTAssertEqual(colour.pointColours.count, 1)
        XCTAssertTrue(colour.grading.isNeutral)
        XCTAssertTrue(colour.calibration.isNeutral)

        let grading = EditStack().merged(with: stack, groups: [.splitToning]).parameters()
        XCTAssertEqual(grading.colour.grading.blending, 0.7)
        XCTAssertEqual(grading.splitToning.shadowHue, 210)
        XCTAssertEqual(grading.colour.saturation, 0)

        let calibration = EditStack().merged(with: stack, groups: [.calibration]).parameters().colour
        XCTAssertEqual(calibration.calibration.redHue, 0.3)
        XCTAssertFalse(calibration.blackAndWhite.enabled)
    }

    func testHistoryNamesTheChange() {
        let a = EditStack(parameters: EditParameters())
        var p = EditParameters()
        p.colour.blackAndWhite.enabled = true
        XCTAssertEqual(EditHistory.describeChange(from: a, to: EditStack(parameters: p)), "Treatment")
        p.colour.blackAndWhite.mix[5] = -0.4
        let bw = EditStack(parameters: p)
        var q = p
        q.colour.blackAndWhite.mix[5] = -0.6
        XCTAssertEqual(EditHistory.describeChange(from: bw, to: EditStack(parameters: q)), "B&W Mix")
        q.colour.saturation = 0.2
        q.colour.calibration.blueHue = 0.1
        XCTAssertEqual(EditHistory.describeChange(from: bw, to: EditStack(parameters: q)),
                       "Saturation, B&W Mix, Calibration")
    }

    // MARK: - Maths

    func testCalibrationMatrixKeepsWhiteAndTurnsPrimaries() {
        XCTAssertEqual(Calibration.neutral.matrix, matrix_identity_float3x3)
        XCTAssertFalse(Calibration(shadowTint: 0.5).movesPrimaries, "the shadow tint is not a matrix change")

        let c = Calibration(redHue: 1, greenSaturation: -0.5, blueHue: -0.4, blueSaturation: 0.6)
        let m = c.matrix
        let white = m * SIMD3<Float>(1, 1, 1)
        XCTAssertEqual(white.x, 1, accuracy: 1e-4); XCTAssertEqual(white.y, 1, accuracy: 1e-4)
        XCTAssertEqual(white.z, 1, accuracy: 1e-4)

        // Red's hue at +1 turns 30 degrees towards yellow.
        let red = Calibration(redHue: 1).matrix * SIMD3<Float>(1, 0, 0)
        let hue = PointColour.hsv(red - SIMD3(repeating: min(red.x, red.y, red.z))).x
        XCTAssertGreaterThan(red.y, red.z, "red moves towards yellow, not magenta")
        XCTAssertEqual(hue, 30, accuracy: 6)

        // Saturation scales the primary's colourfulness about grey.
        let duller = Calibration(greenSaturation: -1).matrix * SIMD3<Float>(0, 1, 0)
        let greenChroma = duller.y - (duller.x + duller.z) / 2
        XCTAssertLessThan(greenChroma, 0.6, "less colourful than the untouched primary (1.0)")
        XCTAssertGreaterThan(greenChroma, 0)
    }

    func testAutoMixLeavesGreysAndLiftsSaturatedColours() {
        let greys = (0..<1000).map { SIMD3<Float>(repeating: Float($0 % 100) / 100) }
        XCTAssertEqual(BlackAndWhite.autoMix(pixels: greys), BlackAndWhite.neutralMix)

        // Half a frame of saturated red, half of a green with the same
        // gamma-2.2 luma: Auto lifts red (it looks brighter), and doesn't
        // lift the green as much, so the two separate in grey.
        let red = SIMD3<Float>(0.9, 0.12, 0.1)
        let redLuma = 0.2627 * red.x + 0.6780 * red.y + 0.0593 * red.z
        let green = SIMD3<Float>(0.15, (redLuma - 0.2627 * 0.15 - 0.0593 * 0.12) / 0.6780, 0.12)
        let pixels = Array(repeating: red, count: 500) + Array(repeating: green, count: 500)
        let mix = BlackAndWhite.autoMix(pixels: pixels)
        XCTAssertGreaterThan(mix[0], 0.1, "red lifted")
        XCTAssertGreaterThan(mix[0], mix[3] + 0.1, "red ends lighter than the green")
        XCTAssertEqual(mix[5], 0, "no blue in the frame, so no blue mix")
        XCTAssertTrue(mix.allSatisfy { (-1...1).contains($0) })
    }

    func testBandWeightsMatchTheShader() {
        XCTAssertEqual(BlackAndWhite.bandWeights(hue: 0), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(BlackAndWhite.bandWeights(hue: 15)[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(BlackAndWhite.bandWeights(hue: 15)[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(BlackAndWhite.bandWeights(hue: 330)[7], 0.5, accuracy: 1e-6)
        XCTAssertEqual(BlackAndWhite.bandWeights(hue: 330)[0], 0.5, accuracy: 1e-6)
    }

    func testPointColourFromPickAndGPUPacking() {
        let pc = PointColour(picked: SIMD3(0.8, 0.4, 0.2))
        XCTAssertEqual(pc.hue, 20, accuracy: 0.01)
        XCTAssertEqual(pc.saturation, 0.75, accuracy: 1e-5)
        XCTAssertEqual(pc.value, 0.8, accuracy: 1e-5)
        XCTAssertFalse(pc.isActive, "a swatch only picked changes nothing")

        XCTAssertEqual(MemoryLayout<ColourExtrasGPU>.stride, 24 * 16, "matches the Metal struct")
        var c = ColourControls(pointColours: [pc])
        XCTAssertEqual(c.gpuFlags, 0)
        c.pointColours[0].saturationShift = 0.5
        let packed = ColourExtrasGPU(c, splitBalance: 0)
        XCTAssertEqual(packed.info.x, ColourControls.flagPointColour)
        XCTAssertEqual(packed.info.y, 1)
        XCTAssertEqual(packed.pointShift[0].y, 0.5)
        XCTAssertEqual(packed.pointTarget[0].x, 20, accuracy: 0.01)
        // Black & White replaces the colour controls.
        c.blackAndWhite.enabled = true
        c.saturation = 0.5
        XCTAssertEqual(c.gpuFlags, ColourControls.flagBlackAndWhite)
    }

    // MARK: - Renders

    func testRendersOnARealImage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        func pixels(_ p: EditParameters) throws -> [SIMD3<Float>] {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
            return stride(from: 0, to: px.count, by: 4).map { SIMD3(Float(px[$0]), Float(px[$0 + 1]), Float(px[$0 + 2])) }
        }
        func meanChroma(_ px: [SIMD3<Float>]) -> Float {
            px.reduce(0) { $0 + ($1.max() - $1.min()) } / Float(px.count)
        }
        func meanLuma(_ px: [SIMD3<Float>], _ keep: (Float) -> Bool = { _ in true }) -> Float {
            let l = px.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }.filter(keep)
            return l.reduce(0, +) / Float(max(l.count, 1))
        }

        let plain = try pixels(EditParameters())

        // Inactive: neutral controls (picked swatches with nothing to do
        // included) render bit for bit as without them.
        var inactive = EditParameters()
        inactive.colour.pointColours = [PointColour(hue: 30, saturation: 0.5, value: 0.5)]
        inactive.colour.blackAndWhite.mix = [0.5, 0, 0, 0, 0, 0, 0, 0]   // kept, but treatment is Color
        XCTAssertEqual(try pixels(inactive), plain)

        // An old split-toning edit renders the same whether or not the
        // Colour Grading path runs it (Blending 0.5 is split toning's).
        var split = EditParameters()
        split.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.4, highlightHue: 45,
                                        highlightSaturation: 0.3, balance: 0.2)
        var viaGrading = split
        viaGrading.colour.grading.global = GradingWheel(hue: 0, saturation: 0, luminance: 1e-7)
        let a = try pixels(split), b = try pixels(viaGrading)
        let worst = zip(a, b).map { simd_reduce_max(simd_abs($0 - $1)) }.max() ?? 0
        XCTAssertLessThan(worst, 2e-3)

        // Saturation: -1 is grey, +0.5 more colourful.
        var grey = EditParameters(); grey.colour.saturation = -1
        XCTAssertLessThan(meanChroma(try pixels(grey)), meanChroma(plain) * 0.05)
        var vivid = EditParameters(); vivid.colour.saturation = 0.5
        XCTAssertGreaterThan(meanChroma(try pixels(vivid)), meanChroma(plain) * 1.2)

        // Black & White: grey, and the mix moves it.
        var bw = EditParameters(); bw.colour.blackAndWhite.enabled = true
        let bwPixels = try pixels(bw)
        XCTAssertLessThan(meanChroma(bwPixels), 1e-3)
        var bwBright = bw; bwBright.colour.blackAndWhite.mix = Array(repeating: 1, count: 8)
        var bwDark = bw; bwDark.colour.blackAndWhite.mix = Array(repeating: -1, count: 8)
        XCTAssertGreaterThan(meanLuma(try pixels(bwBright)), meanLuma(bwPixels))
        XCTAssertLessThan(meanLuma(try pixels(bwDark)), meanLuma(bwPixels))
        // Split toning still tints a black and white.
        var toned = bw; toned.splitToning.highlightSaturation = 0.5
        XCTAssertGreaterThan(meanChroma(try pixels(toned)), 0.005)

        // Colour Grading: global luminance brightens; a midtone tint adds colour to a B&W.
        var lifted = EditParameters(); lifted.colour.grading.global.luminance = 0.5
        XCTAssertGreaterThan(meanLuma(try pixels(lifted)), meanLuma(plain) + 0.03)
        var midTint = bw; midTint.colour.grading.midtones = GradingWheel(hue: 200, saturation: 0.6)
        let mid = try pixels(midTint)
        XCTAssertGreaterThan(meanChroma(mid), 0.01)
        let blueish = mid.map { $0.z - $0.x }.reduce(0, +) / Float(mid.count)
        XCTAssertGreaterThan(blueish, 0, "hue 200 tints towards cyan-blue")

        // Calibration: the shadow tint goes magenta in the shadows; the
        // primaries change colour but keep greys where they were (the
        // matrix maps equal parts of all three to grey). Coloured pixels
        // may get lighter or darker (red turned towards yellow is
        // brighter), so the whole image's mean luma depends on the file.
        var magenta = EditParameters(); magenta.colour.calibration.shadowTint = 1
        let m = try pixels(magenta)
        let shadowGreen = zip(m, plain).filter { meanLuma([$0.1]) < 0.2 }.map { $0.0.y - $0.1.y }
        XCTAssertLessThan(shadowGreen.reduce(0, +) / Float(max(shadowGreen.count, 1)), 0)
        var calibrated = EditParameters(); calibrated.colour.calibration.redHue = 1
        let c = try pixels(calibrated)
        XCTAssertNotEqual(c, plain)
        let greys = plain.indices.filter { plain[$0].max() - plain[$0].min() < 0.03 }
        XCTAssertGreaterThan(greys.count, 1000)
        XCTAssertEqual(meanLuma(greys.map { c[$0] }), meanLuma(greys.map { plain[$0] }), accuracy: 0.01)

        // Point Colour: a swatch at the image's own commonest colour with
        // saturation -1 takes colour out of the image; the same swatch
        // with no shift and Variance -1 also flattens it a little.
        let image = try GradingImage.render(session: session, pipeline: pipeline, gpu: gpu,
                                            parameters: EditParameters(), stage: .beforePointColour)
        let centre = try XCTUnwrap(image.averageColour(at: SIMD2(0.5, 0.55)))
        var point = EditParameters()
        point.colour.pointColours = [PointColour(picked: centre)]
        point.colour.pointColours[0].saturationShift = -1
        point.colour.pointColours[0].range = 1
        XCTAssertLessThan(meanChroma(try pixels(point)), meanChroma(plain))

        // Auto B&W on the real image gives a usable mix.
        let mix = BlackAndWhite.autoMix(for: try GradingImage.render(
            session: session, pipeline: pipeline, gpu: gpu, parameters: EditParameters(), stage: .beforeColourMix))
        XCTAssertEqual(mix.count, 8)
        XCTAssertTrue(mix.allSatisfy { (-1...1).contains($0) })
    }
}
