import XCTest
import simd
@testable import PixelEngine

/// The finer detail, lens and effects controls as data: storage,
/// compatibility with edits made before them, clamping, copy/paste groups,
/// and the maths each one's shader follows.
final class DetailEffectsTests: XCTestCase {
    /// Every new control away from its default.
    static var everything: EditParameters {
        var p = EditParameters()
        p.sharpenAmount = 0.8
        p.sharpenDetail = 0.3
        p.sharpenMasking = 0.6
        p.denoiseLuminance = 0.4
        p.denoiseColor = 0.5
        p.noiseDetail = NoiseReductionDetail(luminanceDetail: 0.7, luminanceContrast: 0.2,
                                             colourDetail: 0.25, colourSmoothness: 0.6)
        p.defringePurple = 0.5
        p.defringeHues = DefringeHueRanges(purpleLow: 260, purpleHigh: 320, greenLow: 90, greenHigh: 150)
        p.manualVignetting = 0.4
        p.manualVignettingMidpoint = 0.8
        p.autoCA = AutoChromaticAberration(red: 0.0006, blue: -0.0004)
        p.lensProfile = "Nikon AF-S Nikkor 50mm f/1.8G"
        p.postCropVignette = PostCropVignette(style: .colourPriority, amount: -0.6, midpoint: 0.3,
                                              roundness: 0.4, feather: 0.7, highlights: 0.5)
        p.grain = Grain(amount: 0.4, size: 0.6, roughness: 0.2)
        return p
    }

    // MARK: - Storage

    /// An edit that never touches the new controls encodes exactly as it
    /// did before they existed: none of their keys appear.
    func testUntouchedEditStoresNothingNew() throws {
        var p = EditParameters()
        p.sharpenAmount = 1; p.denoiseLuminance = 0.3; p.defringePurple = 0.2; p.manualVignetting = 0.3
        let json = try EditStack(parameters: p).encodeJSON()
        for key in ["\"grain\"", "\"vignette\"", "\"detail\"", "\"masking\"", "\"hues\"", "\"autoCA\"",
                    "\"manualProfile\"", "\"vignettingMidpoint\""] {
            XCTAssertFalse(json.contains(key), "\(key) written for an edit that doesn't use it: \(json)")
        }
    }

    /// The JSON of an edit made before this change (written by hand from
    /// that version's format) reads back with every new control at its
    /// default.
    func testEditFromBeforeLoadsWithDefaults() throws {
        let old = """
        {"modules":{"defringe":{"green":0,"purple":0.4},"denoise":{"color":0.2,"luminance":0.3},\
        "lens":{"distortion":true,"manualDistortion":0,"manualVignetting":0.5,"tca":true,"vignetting":true},\
        "sharpen":{"amount":1.2,"radius":1,"threshold":0.01}},"process":"1.0","schema":1}
        """
        let p = try EditStack.decode(json: old).parameters()
        XCTAssertEqual(p.sharpenAmount, 1.2)
        XCTAssertEqual(p.sharpenDetail, SharpenRefinement.neutralDetail)
        XCTAssertEqual(p.sharpenMasking, SharpenRefinement.neutralMasking)
        XCTAssertEqual(p.noiseDetail, .neutral)
        XCTAssertEqual(p.defringeHues, .standard)
        XCTAssertEqual(p.manualVignettingMidpoint, ManualVignettingShape.neutralMidpoint)
        XCTAssertNil(p.autoCA)
        XCTAssertNil(p.lensProfile)
        XCTAssertEqual(p.postCropVignette, .off)
        XCTAssertEqual(p.grain, .off)
        // And written back, it is the same edit.
        XCTAssertEqual(try EditStack.decode(json: EditStack(parameters: p).encodeJSON()).parameters(), p)
    }

    /// Save and reload: every new control comes back as it was, through
    /// the stack's JSON, as the catalog and the sidecar store it.
    func testEverythingRoundTrips() throws {
        let p = Self.everything
        let json = try EditStack(parameters: p).encodeJSON()
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
        XCTAssertEqual(try EditStack(parameters: back).encodeJSON(), json, "a second save writes the same bytes")
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
        XCTAssertEqual(EditStack.schemaVersion, 1, "the schema number is not bumped for optional fields")
    }

    /// A hand-edited sidecar can't push values outside what the controls
    /// allow.
    func testHandEditedValuesAreClamped() throws {
        let json = """
        {"modules":{"sharpen":{"amount":1,"radius":1,"threshold":0.01,"detail":7,"masking":-3},\
        "denoise":{"color":0.2,"luminance":0.3,"detail":{"luminanceDetail":9,"colourSmoothness":-1}},\
        "defringe":{"green":0.2,"purple":0.4,"hues":{"purpleLow":400,"purpleHigh":10,"greenLow":100,"greenHigh":101}},\
        "lens":{"vignettingMidpoint":5,"autoCA":{"red":1,"blue":-1}},\
        "grain":{"amount":3,"size":-2},"vignette":{"amount":-9,"style":"nonsense","feather":2}},"process":"1.0","schema":1}
        """
        let p = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(p.sharpenDetail, 1); XCTAssertEqual(p.sharpenMasking, 0)
        XCTAssertEqual(p.noiseDetail.luminanceDetail, 1); XCTAssertEqual(p.noiseDetail.colourSmoothness, 0)
        XCTAssertGreaterThanOrEqual(p.defringeHues.purpleLow, DefringeHueRanges.purpleLimits.lowerBound)
        XCTAssertLessThanOrEqual(p.defringeHues.purpleHigh, DefringeHueRanges.purpleLimits.upperBound)
        XCTAssertGreaterThanOrEqual(p.defringeHues.greenHigh - p.defringeHues.greenLow, DefringeHueRanges.minimumWidth)
        XCTAssertEqual(p.manualVignettingMidpoint, 1)
        XCTAssertEqual(p.autoCA, AutoChromaticAberration(red: AutoChromaticAberration.limit,
                                                         blue: -AutoChromaticAberration.limit))
        XCTAssertEqual(p.grain.amount, 1); XCTAssertEqual(p.grain.size, 0)
        XCTAssertEqual(p.postCropVignette.amount, -1)
        XCTAssertEqual(p.postCropVignette.style, .highlightPriority, "an unknown style falls back")
        XCTAssertEqual(p.postCropVignette.feather, 1)
    }

    // MARK: - Groups

    func testEffectsTravelAsTheirOwnGroup() {
        let stack = EditStack(parameters: Self.everything)
        XCTAssertTrue(stack.presentGroups.contains(.effects))
        XCTAssertTrue(EditGroup.lookGroups.contains(.effects))
        let onlyEffects = EditStack().merged(with: stack, groups: [.effects]).parameters()
        XCTAssertEqual(onlyEffects.grain, Self.everything.grain)
        XCTAssertEqual(onlyEffects.postCropVignette, Self.everything.postCropVignette)
        XCTAssertEqual(onlyEffects.sharpenDetail, SharpenRefinement.neutralDetail)
        // Sharpening's and noise reduction's new sliders ride with Detail,
        // the lens ones with Lens.
        let onlyDetail = EditStack().merged(with: stack, groups: [.detail]).parameters()
        XCTAssertEqual(onlyDetail.sharpenMasking, 0.6)
        XCTAssertEqual(onlyDetail.noiseDetail, Self.everything.noiseDetail)
        XCTAssertEqual(onlyDetail.grain, .off)
        XCTAssertNil(onlyDetail.autoCA)
        let onlyLens = EditStack().merged(with: stack, groups: [.lens]).parameters()
        XCTAssertEqual(onlyLens.autoCA, Self.everything.autoCA)
        XCTAssertEqual(onlyLens.manualVignettingMidpoint, 0.8)
        XCTAssertEqual(onlyLens.defringeHues, Self.everything.defringeHues)
        XCTAssertEqual(onlyLens.lensProfile, Self.everything.lensProfile)
        // Pasting "no effects" turns them off.
        var pasted = EditStack(parameters: Self.everything)
        pasted = pasted.merged(with: EditStack(parameters: EditParameters()), groups: [.effects])
        XCTAssertEqual(pasted.parameters().grain, .off)
    }

    // MARK: - The maths

    func testNeutralSettingsAreExactlyTheOldBehaviour() {
        XCTAssertEqual(NoiseReductionDetail.neutral.luminanceToleranceScale, 1)
        XCTAssertEqual(NoiseReductionDetail.neutral.colourToleranceScale, 1)
        XCTAssertFalse(NoiseReductionDetail.neutral.wantsRefinePass)
        XCTAssertEqual(ManualVignettingShape.exponent(midpoint: 0.5), 2)
        XCTAssertEqual(DefringeHueRanges.standard.turns, SIMD4<Float>(0.70, 0.92, 0.22, 0.44))
        XCTAssertFalse(Grain.off.isActive)
        XCTAssertFalse(PostCropVignette.off.isActive)
    }

    func testDetailSlidersMoveTheTolerancesTheRightWay() {
        var n = NoiseReductionDetail.neutral
        n.luminanceDetail = 1
        XCTAssertLessThan(n.luminanceToleranceScale, 1, "more detail is a tighter filter")
        n.luminanceDetail = 0
        XCTAssertGreaterThan(n.luminanceToleranceScale, 1)
        XCTAssertLessThan(ManualVignettingShape.exponent(midpoint: 0), 2)
        XCTAssertGreaterThan(ManualVignettingShape.exponent(midpoint: 1), 2)
    }

    func testVignetteShapeFollowsItsSliders() {
        let v = PostCropVignette(amount: -1)
        XCTAssertEqual(v.mask(atCropPoint: [0, 0], aspect: 1.5), 0, accuracy: 1e-6, "the centre is untouched")
        XCTAssertEqual(v.mask(atCropPoint: [1, 1], aspect: 1.5), 1, accuracy: 1e-3, "the corners get it all")
        // A lower midpoint reaches further in.
        var low = v; low.midpoint = 0
        XCTAssertGreaterThan(low.mask(atCropPoint: [0.6, 0], aspect: 1.5), v.mask(atCropPoint: [0.6, 0], aspect: 1.5))
        // Rectangular (−1) reaches the middle of an edge sooner than the oval.
        var square = v; square.roundness = -1; square.feather = 0.2
        var oval = v; oval.feather = 0.2
        XCTAssertGreaterThan(square.mask(atCropPoint: [0.95, 0.95], aspect: 1), 0.5)
        XCTAssertGreaterThanOrEqual(square.mask(atCropPoint: [0.95, 0.95], aspect: 1),
                                    oval.mask(atCropPoint: [0.95, 0.95], aspect: 1))
        // A circle on a wide crop is symmetric in pixels: the same pixel
        // distance left and up gives the same strength.
        var circle = v; circle.roundness = 1
        let aspect: Float = 2
        XCTAssertEqual(circle.mask(atCropPoint: [0.5, 0], aspect: aspect),
                       circle.mask(atCropPoint: [0, 1], aspect: aspect), accuracy: 1e-4)
        // No feather is a hard edge.
        var hard = v; hard.feather = 0
        let a = hard.mask(atCropPoint: [0.6, 0.6], aspect: 1), b = hard.mask(atCropPoint: [0.7, 0.7], aspect: 1)
        XCTAssertEqual(a, 0, accuracy: 1e-6); XCTAssertEqual(b, 1, accuracy: 1e-6)
    }

    func testGrainSeedIsPerImageAndStable() {
        let a = Grain.seed(cameraModel: "D750", captureTime: 1_700_000_000, width: 6016, height: 4016)
        XCTAssertEqual(a, Grain.seed(cameraModel: "D750", captureTime: 1_700_000_000, width: 6016, height: 4016))
        XCTAssertNotEqual(a, Grain.seed(cameraModel: "D750", captureTime: 1_700_000_001, width: 6016, height: 4016))
        // Grains scale with the picture.
        let g = Grain(amount: 1)
        XCTAssertEqual(g.cellSensorPixels(shortSide: 8000) / g.cellSensorPixels(shortSide: 4000), 2, accuracy: 1e-5)
        XCTAssertLessThan(Grain(amount: 1, size: 0).cellSensorPixels(shortSide: 4000),
                          Grain(amount: 1, size: 1).cellSensorPixels(shortSide: 4000))
    }

    func testEyedropperMovesTheMatchingRange() {
        let s = DefringeHueRanges.standard
        let magenta = s.picking(hue: 300)
        XCTAssertEqual(magenta.band, .purple)
        XCTAssertEqual((magenta.ranges.purpleLow + magenta.ranges.purpleHigh) / 2, 300, accuracy: 0.01)
        XCTAssertEqual(magenta.ranges.purpleHigh - magenta.ranges.purpleLow, s.purpleHigh - s.purpleLow, accuracy: 0.01)
        XCTAssertEqual(magenta.ranges.greenLow, s.greenLow, "the other range stays")
        let cyan = s.picking(hue: 170)
        XCTAssertEqual(cyan.band, .green)
        XCTAssertLessThanOrEqual(cyan.ranges.greenHigh, DefringeHueRanges.greenLimits.upperBound)
        // A red just past 0° belongs with purple, pinned to the top end.
        let red = s.picking(hue: 5)
        XCTAssertEqual(red.band, .purple)
        XCTAssertEqual(red.ranges.purpleHigh, 360)
    }

    // MARK: - Chromatic aberration estimate

    /// A synthetic patch: a set of soft edges in all colours, with the red
    /// image shifted outward along `direction` by `shift` pixels.
    private func patch(shift: Float, direction: SIMD2<Float>, size: Int = 96) -> [SIMD3<Float>] {
        var pixels = [SIMD3<Float>](repeating: .zero, count: size * size)
        func scene(_ p: SIMD2<Float>) -> Float {
            // Rings and stripes so the radial gradient has structure.
            let t = sin(p.x * 0.31) * cos(p.y * 0.23) + 0.6 * sin((p.x + p.y) * 0.17)
            return 0.05 + 0.9 * (1 / (1 + exp(-4 * t)))
        }
        for y in 0..<size {
            for x in 0..<size {
                let p = SIMD2<Float>(Float(x), Float(y))
                let g = scene(p)
                let r = scene(p - shift * direction)
                pixels[y * size + x] = SIMD3(r * 0.8, g, g * 0.6)
            }
        }
        return pixels
    }

    func testRadialShiftFindsTheRedImageOffset() throws {
        let direction = simd_normalize(SIMD2<Float>(0.6, 0.8))
        for shift: Float in [-1.4, 0, 0.7, 1.6] {
            let s = try XCTUnwrap(ChromaticAberrationEstimator.radialShift(
                pixels: patch(shift: shift, direction: direction), width: 96, height: 96, channel: 0,
                direction: direction), "shift \(shift)")
            XCTAssertEqual(s.shift, shift, accuracy: 0.12, "shift \(shift)")
            XCTAssertGreaterThan(s.weight, 0)
            // Blue was not shifted.
            let b = try XCTUnwrap(ChromaticAberrationEstimator.radialShift(
                pixels: patch(shift: shift, direction: direction), width: 96, height: 96, channel: 2,
                direction: direction))
            XCTAssertEqual(b.shift, 0, accuracy: 0.12)
        }
    }

    func testFlatPatchSaysNothing() {
        let flat = [SIMD3<Float>](repeating: SIMD3(0.3, 0.4, 0.2), count: 64 * 64)
        XCTAssertNil(ChromaticAberrationEstimator.radialShift(pixels: flat, width: 64, height: 64, channel: 0,
                                                              direction: [1, 0]))
    }

    func testScaleFitIgnoresAnOutlier() throws {
        let k: Float = 0.0005
        var samples = [Float(800), 1200, 1600, 2000, 2400, 2800].map {
            ChromaticAberrationEstimator.Sample(radius: $0, shift: k * $0, weight: 1)
        }
        samples.append(.init(radius: 1500, shift: 2.5, weight: 1))   // a red object, not a fringe
        XCTAssertEqual(try XCTUnwrap(ChromaticAberrationEstimator.fitScale(samples)), k, accuracy: 1e-6)
        XCTAssertNil(ChromaticAberrationEstimator.fitScale(Array(samples.prefix(3))), "too few to trust")
    }

    func testAutoCorrectionIsALinearTCAModel() {
        let tca = AutoChromaticAberration(red: 0.001, blue: -0.002).tcaModel
        XCTAssertEqual(tca.red, SIMD3(0, 0, 1.001))
        XCTAssertEqual(tca.blue, SIMD3(0, 0, 0.998))
    }
}
