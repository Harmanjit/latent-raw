import XCTest
import simd
import LensKit
@testable import PixelEngine

/// Hot pixel removal, manual chromatic aberration, the Remove tool's Fill
/// and Blur modes and Lens Blur's blur types: how each is stored (absent
/// while off, so older edits encode byte for byte as before), read back
/// from a hand-edited file, and what the Swift arithmetic says.
final class DetailExtrasTests: XCTestCase {
    private func roundTrip(_ p: EditParameters) throws -> EditParameters {
        let json = try EditStack(parameters: p).encodeJSON()
        return try EditStack.decode(json: json).parameters()
    }

    /// Nothing new is written for an edit that doesn't use the new
    /// controls, nor for a Heal, Clone or Remove patch.
    func testUnusedControlsAreAbsentFromTheJSON() throws {
        var p = EditParameters()
        p.heals = [HealPatch(target: SIMD2(0.5, 0.5), source: SIMD2(0.6, 0.5), radius: 0.02, mode: .heal)]
        p.lensBlur.amount = 40
        let json = try EditStack(parameters: p).encodeJSON()
        for key in ["hotpixels", "tcaRed", "tcaBlue", "fillColour", "fillBrightness", "blurRadius",
                    "blurType", "motionAngle"] {
            XCTAssertFalse(json.contains("\"\(key)\""), key)
        }
    }

    // MARK: - Hot pixels

    func testHotPixelsRoundTripAndTravelWithDetail() throws {
        var p = EditParameters()
        p.hotPixels = HotPixelRemoval(threshold: 30, mode: .outliers)
        XCTAssertEqual(try roundTrip(p).hotPixels, p.hotPixels)
        XCTAssertNil(try roundTrip(EditParameters()).hotPixels)

        let stack = EditStack(parameters: p)
        XCTAssertTrue(stack.presentGroups.contains(.detail))
        let pasted = EditStack().merged(with: stack, groups: [.detail]).parameters()
        XCTAssertEqual(pasted.hotPixels, p.hotPixels)
        XCTAssertNil(EditStack().merged(with: stack, groups: [.lens]).parameters().hotPixels)
    }

    func testHotPixelsReadLenientlyAndClamped() throws {
        let json = #"{"threshold": 500, "mode": "fromTheFuture"}"#
        let decoded = try JSONDecoder().decode(HotPixelRemoval.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.mode, .stuck)
        XCTAssertEqual(decoded.sanitized.threshold, 100)
        XCTAssertEqual(HotPixelRemoval(threshold: .nan).sanitized.threshold, HotPixelRemoval.defaultThreshold)
        XCTAssertEqual(HotPixelRemoval(threshold: 0).margin, 0.01, accuracy: 1e-6)
        XCTAssertEqual(HotPixelRemoval(threshold: 100).margin, 0.40, accuracy: 1e-6)
    }

    /// Stuck Pixels Only replaces a photosite above all its neighbours;
    /// Also Dim Outliers also takes one above their median with a bright
    /// neighbour beside it. Neither touches a pixel in an even area.
    func testHotPixelTest() {
        let stuck = HotPixelRemoval(threshold: 20, mode: .stuck)
        let outliers = HotPixelRemoval(threshold: 20, mode: .outliers)
        let even: [Float] = [0.10, 0.11, 0.09, 0.10, 0.12, 0.10, 0.08, 0.10]
        XCTAssertEqual(stuck.replacement(for: 0.9, neighbours: even) ?? -1, 0.10, accuracy: 1e-6)
        XCTAssertNil(stuck.replacement(for: 0.11, neighbours: even))
        var oneBright = even
        oneBright[2] = 0.89
        XCTAssertNil(stuck.replacement(for: 0.9, neighbours: oneBright))
        XCTAssertEqual(outliers.replacement(for: 0.9, neighbours: oneBright) ?? -1, 0.10, accuracy: 1e-6)
        XCTAssertNil(outliers.replacement(for: 0.11, neighbours: oneBright))
    }

    // MARK: - Manual TCA

    func testManualTCARoundTripClampAndFollowTheLensModule() throws {
        var p = EditParameters()
        p.manualTCARed = 0.3
        p.manualTCABlue = -0.2
        let back = try roundTrip(p)
        XCTAssertEqual(back.manualTCARed, 0.3)
        XCTAssertEqual(back.manualTCABlue, -0.2)

        var stack = EditStack(parameters: EditParameters())
        stack.modules.lens?.tcaRed = 5
        stack.modules.lens?.tcaBlue = .infinity
        let clamped = stack.parameters()
        XCTAssertEqual(clamped.manualTCARed, 0.5)
        XCTAssertEqual(clamped.manualTCABlue, 0)

        // A preset without Lens Corrections leaves the photo's own alone.
        var defaults = EditParameters()
        defaults.manualTCARed = 0.1
        XCTAssertEqual(EditStack().parameters(defaults: defaults).manualTCARed, 0.1)
    }

    /// The sliders add to the linear term of whichever model is in use,
    /// or make one of their own.
    func testManualTCAAddsToTheModel() throws {
        let own = try XCTUnwrap(ManualTCA.adding(red: 0.2, blue: -0.1, to: nil))
        XCTAssertEqual(own.red.z, 1.002, accuracy: 1e-6)
        XCTAssertEqual(own.blue.z, 0.999, accuracy: 1e-6)
        XCTAssertNil(ManualTCA.adding(red: 0, blue: 0, to: nil))
        let auto = AutoChromaticAberration(red: 0.001, blue: 0).tcaModel
        let both = try XCTUnwrap(ManualTCA.adding(red: 0.2, blue: 0, to: auto))
        XCTAssertEqual(both.red.z, 1.003, accuracy: 1e-6)
        XCTAssertEqual(both.blue, auto.blue)
    }

    /// Red reads from a radius 0.4 % larger than green's at +0.4 %.
    func testManualTCAMovesWhereRedReads() {
        let size = SIMD2<Float>(6000, 4000)
        let sampling = RenderPipeline.LensSampling(sensorSize: size,
                                                   tca: ManualTCA.adding(red: 0.4, blue: 0, to: nil))
        let corner = SIMD2<Float>(5800, 3800)
        let points = sampling.sourcePoints(forSensorPoint: corner)
        let centre = size * 0.5
        let green = simd_length(points[0] - centre), red = simd_length(points[1] - centre)
        XCTAssertEqual(red / green, 1.004, accuracy: 1e-4)
        XCTAssertEqual(simd_length(points[2] - centre) / green, 1, accuracy: 1e-5)
    }

    // MARK: - Fill and Blur

    func testFillAndBlurFieldsRoundTripAndSanitise() throws {
        var fill = HealPatch(target: SIMD2(0.3, 0.3), source: SIMD2(0.3, 0.3), radius: 0.02, mode: .fill)
        fill.fillColour = SIMD3(0.4, 0.2, 0.1)
        fill.fillBrightness = 1.5
        var blur = HealPatch(target: SIMD2(0.6, 0.6), source: SIMD2(0.6, 0.6), radius: 0.03, mode: .blur)
        blur.blurRadius = 0.01
        var p = EditParameters()
        p.heals = [fill, blur]
        XCTAssertEqual(try roundTrip(p).heals, p.heals)

        var wild = fill
        wild.fillColour = SIMD3(.nan, 0, 0)
        wild.fillBrightness = 10
        wild.blurRadius = 3
        let sane = try XCTUnwrap(wild.sanitized)
        XCTAssertNil(sane.fillColour)
        XCTAssertEqual(sane.fillBrightness, 4)
        XCTAssertEqual(sane.blurRadius, HealPatch.maximumBlurRadius)
    }

    /// Fill and Blur have no source, so a tile never widens to reach one;
    /// Blur reads its surroundings, Fill nothing past its edge.
    func testFillAndBlurReadNoSource() {
        let size = CGSize(width: 1000, height: 1000)
        let region = CGRect(x: 400, y: 400, width: 200, height: 200)
        for mode in [HealPatch.Mode.fill, .blur] {
            var patch = HealPatch(target: SIMD2(0.5, 0.5), source: SIMD2(0.05, 0.05), radius: 0.02, mode: mode)
            patch.blurRadius = 0.01
            let needed = HealPatch.regionIncludingSources(region, patches: [patch], sensorSize: size)
            XCTAssertFalse(needed.contains(CGPoint(x: 60, y: 60)), "\(mode)")
            XCTAssertTrue(HealPatch.isSelfContained(region, patches: [patch], sensorSize: size), "\(mode)")
        }
        XCTAssertFalse(HealPatch.Mode.fill.usesSource)
        XCTAssertFalse(HealPatch.Mode.blur.usesSource)
        XCTAssertTrue(HealPatch.Mode.clone.usesSource)
    }

    func testFillColourSRGBRoundTrip() {
        let c = SIMD3<Float>(0.8, 0.4, 0.2)
        let back = HealPatch.sRGB(fromFillColour: HealPatch.fillColour(fromSRGB: c))
        XCTAssertEqual(back.x, c.x, accuracy: 0.01)
        XCTAssertEqual(back.y, c.y, accuracy: 0.01)
        XCTAssertEqual(back.z, c.z, accuracy: 0.01)
    }

    // MARK: - Lens Blur types

    func testBlurTypeRoundTripAndSanitise() throws {
        var p = EditParameters()
        p.lensBlur.amount = 50
        p.lensBlur.blurType = .motion
        p.lensBlur.motionAngle = 30
        XCTAssertEqual(try roundTrip(p).lensBlur, p.lensBlur)

        var b = LensBlur(amount: 10)
        b.blurType = .bokeh
        b.motionAngle = 200
        let s = b.sanitized
        XCTAssertNil(s.blurType)
        XCTAssertEqual(s.motionAngle ?? -1, 20, accuracy: 1e-4)
        b.motionAngle = 180
        XCTAssertNil(b.sanitized.motionAngle)

        let json = #"{"amount": 20, "blurType": "tiltShift"}"#
        let decoded = try JSONDecoder().decode(LensBlur.self, from: Data(json.utf8))
        XCTAssertNil(decoded.blurType)
        XCTAssertEqual(decoded.effectiveBlurType, .bokeh)
    }

    func testOnlyGaussianAndMotionBlurWithoutDepth() {
        var b = LensBlur(amount: 30)
        XCTAssertFalse(b.blursWithoutDepth)
        b.blurType = .gaussian
        XCTAssertTrue(b.blursWithoutDepth)
        b.blurType = .motion
        XCTAssertTrue(b.blursWithoutDepth)
        b.amount = 0
        XCTAssertFalse(b.blursWithoutDepth)
    }
}

extension DetailExtrasTests {
    func testHistoryNamesHotPixels() {
        var p = EditParameters()
        p.hotPixels = HotPixelRemoval()
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: EditParameters()), to: EditStack(parameters: p)),
                       "Hot Pixels")
    }
}
