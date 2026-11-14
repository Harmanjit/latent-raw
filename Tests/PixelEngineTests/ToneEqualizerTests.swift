import XCTest
import CoreGraphics
@testable import PixelEngine

/// The tone equalizer's model: storage, the gain curve, compensation,
/// presets, the preset Amount and the helpers the panel uses. The render
/// itself is in ToneEqualizerRenderTests.
final class ToneEqualizerTests: XCTestCase {
    private func equalizer(_ bands: [Float]) -> ToneEqualizer { ToneEqualizer(bands: bands) }

    // MARK: - Storage

    func testNeutralIsAbsentAndOldEditsEncodeAsBefore() throws {
        let p = EditParameters()
        let stack = EditStack(parameters: p)
        XCTAssertNil(stack.modules.toneEqualizer)
        XCTAssertFalse(try stack.encodeJSON().contains("toneEqualizer"))
        // A stack written before the module existed reads back neutral.
        let old = try EditStack.decode(json: try stack.encodeJSON())
        XCTAssertEqual(old.parameters().toneEqualizer, .neutral)
    }

    func testRoundTripsThroughJSON() throws {
        var p = EditParameters()
        p.toneEqualizer = ToneEqualizer(bands: [1, 0.5, 0, 0, 0, 0, 0, -0.5, -1], maskExposure: 1.5,
                                        maskContrast: 0.25, smoothing: 0.8, edgeRefinement: nil)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"toneEqualizer\""))
        XCTAssertFalse(json.contains("edgeRefinement"), "a default stays absent")
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.toneEqualizer, p.toneEqualizer)
        XCTAssertEqual(back, p)
    }

    func testSanitizedClampsAndDropsDefaults() {
        let wild = ToneEqualizer(bands: [9, -9, .nan, 1], maskExposure: 0, maskContrast: 7,
                                 smoothing: ToneEqualizer.defaultSmoothing, edgeRefinement: -1)
        let s = wild.sanitized
        XCTAssertEqual(s.bands.count, ToneEqualizer.bandCount)
        XCTAssertEqual(Array(s.bands.prefix(4)), [3, -3, 0, 1])
        XCTAssertNil(s.maskExposure)
        XCTAssertEqual(s.maskContrast, 1)
        XCTAssertNil(s.smoothing)
        XCTAssertEqual(s.edgeRefinement, 0)
    }

    func testStoredMaskSettingsWithoutBandsStayStored() {
        var p = EditParameters()
        p.toneEqualizer.maskExposure = 2
        XCTAssertFalse(p.toneEqualizer.isActive)
        XCTAssertNotNil(EditStack(parameters: p).modules.toneEqualizer)
    }

    // MARK: - The gain curve

    func testEqualBandsGiveThatGainEverywhere() {
        let eq = equalizer(Array(repeating: 1.25, count: 9))
        for ev in stride(from: Float(-12), through: 3, by: 0.37) {
            XCTAssertEqual(eq.gain(atMaskEV: ev), 1.25, accuracy: 1e-5)
        }
    }

    func testGainFollowsItsBandAndNeverOvershoots() {
        var bands = [Float](repeating: 0, count: 9)
        bands[4] = 2   // −4 EV
        let eq = equalizer(bands)
        XCTAssertEqual(eq.gain(atMaskEV: -4), 2, accuracy: 1e-6, "the curve passes through its band")
        XCTAssertLessThan(eq.gain(atMaskEV: -6), 0.05)
        XCTAssertLessThan(eq.gain(atMaskEV: -2), 0.05)
        for ev in stride(from: Float(-10), through: 2, by: 0.1) {
            let g = eq.gain(atMaskEV: ev)
            XCTAssertGreaterThanOrEqual(g, 0)
            XCTAssertLessThanOrEqual(g, 2)
        }
    }

    func testEndBandsHoldPastTheEnds() {
        let eq = equalizer([1, 0, 0, 0, 0, 0, 0, 0, -1])
        XCTAssertEqual(eq.gain(atMaskEV: -14), eq.gain(atMaskEV: -8), accuracy: 1e-6)
        XCTAssertEqual(eq.gain(atMaskEV: 4), eq.gain(atMaskEV: 0), accuracy: 1e-6)
    }

    func testNeutralGainTableIsZero() {
        XCTAssertTrue(ToneEqualizer.neutral.gainTable().allSatisfy { $0 == 0 })
        XCTAssertEqual(ToneEqualizer.neutral.gainTable().count, ToneEqualizer.lutCount)
    }

    // MARK: - Compensation and bands

    func testCompensationShiftsAndStretchesAboutThePivot() {
        var eq = ToneEqualizer.neutral
        XCTAssertEqual(eq.compensated(-3), -3, accuracy: 1e-6)
        eq.maskExposure = 1
        XCTAssertEqual(eq.compensated(-3), -2, accuracy: 1e-6)
        eq.maskExposure = nil
        eq.maskContrast = 1
        XCTAssertEqual(eq.compensated(-4), -4, accuracy: 1e-6, "the pivot stays put")
        XCTAssertEqual(eq.compensated(-3), -2, accuracy: 1e-6, "one stop above it becomes two")
    }

    func testBandUnderAValue() {
        XCTAssertEqual(ToneEqualizer.band(atMaskEV: -8.4), 0)
        XCTAssertEqual(ToneEqualizer.band(atMaskEV: -20), 0)
        XCTAssertEqual(ToneEqualizer.band(atMaskEV: -3.6), 4)
        XCTAssertEqual(ToneEqualizer.band(atMaskEV: 3), 8)
        XCTAssertEqual(ToneEqualizer.band(atMaskEV: .nan), 0)
    }

    func testFitSpreadsTheMaskAcrossTheBands() {
        let fit = ToneEqualizer.fittedCompensation(low: -9, high: -5.5)
        var eq = ToneEqualizer.neutral
        eq.maskExposure = fit.exposure
        eq.maskContrast = fit.contrast
        XCTAssertEqual(eq.compensated(-9), -7.5, accuracy: 0.01)
        XCTAssertEqual(eq.compensated(-5.5), -0.5, accuracy: 0.01)
    }

    func testMaskSnapshotSamplesAndAddsExposure() {
        let snap = ToneEqualizerMaskSnapshot(width: 2, height: 1, values: [-6, -2], exposureEV: 1)
        XCTAssertEqual(snap.maskEV(atNormalized: SIMD2(0.25, 0.5))!, -5, accuracy: 1e-5)
        XCTAssertEqual(snap.maskEV(atNormalized: SIMD2(0.5, 0.5))!, -3, accuracy: 1e-5)
        XCTAssertNil(snap.maskEV(atNormalized: SIMD2(1.5, 0.5)))
        XCTAssertEqual(snap.percentile(0)!, -5, accuracy: 1e-6)
        XCTAssertEqual(snap.percentile(1)!, -1, accuracy: 1e-6)
    }

    func testMaskHistogramIsNormalised() {
        let h = HistogramCalculator.normalizedHistogram(of: [-4, -4, -4.1, -1, 9, .nan], range: -8...0, bins: 8)
        XCTAssertEqual(h.count, 8)
        XCTAssertEqual(h.max(), 1)
        XCTAssertEqual(h[4], 1)          // −4 twice
        XCTAssertEqual(h[3], 0.5)        // −4.1
        XCTAssertEqual(h[7], 1)          // −1, and 9 clamped into the top bin
    }

    func testReadoutText() {
        XCTAssertEqual(PixelReadout(linearDisplayP3: .zero).toneEqualizerText, "")
        XCTAssertEqual(PixelReadout(linearDisplayP3: .zero, toneEqualizerMaskEV: -4.26).toneEqualizerText,
                       "Mask \u{2212}4.3 EV")
    }

    // MARK: - Groups, presets and the Amount

    func testItsOwnGroupCopiesAndPastes() {
        var p = EditParameters()
        p.toneEqualizer = equalizer([0, 0, 0, 0, 1, 0, 0, 0, 0])
        let stack = EditStack(parameters: p)
        XCTAssertEqual(stack.presentGroups, stack.presentGroups.union([.toneEqualizer]))
        XCTAssertTrue(stack.presentGroups.contains(.toneEqualizer))
        XCTAssertTrue(EditGroup.lookGroups.contains(.toneEqualizer))
        let pasted = EditStack().merged(with: stack, groups: [.toneEqualizer])
        XCTAssertEqual(pasted.modules.toneEqualizer, p.toneEqualizer)
        XCTAssertNil(EditStack().merged(with: stack, groups: [.tone]).modules.toneEqualizer)
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(), to: pasted), "Tone Equalizer")
    }

    func testBuiltInRangePresets() throws {
        let names = Preset.builtIns.map(\.name)
        for name in ["Compress Shadows and Highlights (Soft)", "Compress Shadows and Highlights (Strong)",
                     "Lift Shadows", "Compress Range"] {
            XCTAssertTrue(names.contains(name), name)
        }
        let soft = try XCTUnwrap(Preset.builtIns.first { $0.name == "Compress Shadows and Highlights (Soft)" })
        XCTAssertEqual(soft.groups, [.toneEqualizer])
        let bands = try XCTUnwrap(soft.stack.modules.toneEqualizer).bands
        XCTAssertGreaterThan(bands[0], 0, "shadows lifted")
        XCTAssertLessThan(bands[8], 0, "highlights lowered")
        let range = try XCTUnwrap(Preset.builtIns.first { $0.name == "Compress Range" }).stack.parameters()
        XCTAssertLessThan(range.toneRanges.highlights, 0)
        XCTAssertGreaterThan(range.toneRanges.shadows, 0)
        XCTAssertGreaterThan(range.clarity, 0)
        // The older built-ins are still first, unchanged in order.
        XCTAssertEqual(Array(names.prefix(5)), ["Black & White", "Punchy", "Soft Film", "Warm Golden Hour", "Landscape Detail"])
    }

    func testPresetAmountBlendsTheBands() throws {
        let preset = try XCTUnwrap(Preset.builtIns.first { $0.name == "Lift Shadows" })
        let base = EditStack(parameters: EditParameters())
        let half = base.applying(preset.stack, groups: preset.groups, amount: 0.5).parameters()
        XCTAssertEqual(half.toneEqualizer.bands[0], 0.5, accuracy: 1e-6)
        let double = base.applying(preset.stack, groups: preset.groups, amount: 2).parameters()
        XCTAssertEqual(double.toneEqualizer.bands[0], 2, accuracy: 1e-6)
        XCTAssertEqual(base.applying(preset.stack, groups: preset.groups, amount: 1),
                       base.merged(with: preset.stack, groups: preset.groups))
    }

    // MARK: - Scrolling over the image

    func testToolScrollAmount() {
        typealias W = ViewerInteraction.WheelEvent
        XCTAssertEqual(ViewerInteraction.toolScrollAmount(W(precise: false, delta: CGSize(width: 0, height: 1))), 1.0 / 12)
        XCTAssertEqual(ViewerInteraction.toolScrollAmount(W(precise: false, delta: CGSize(width: 0, height: -3),
                                                             invertedFromDevice: true)), 1.0 / 12)
        XCTAssertEqual(ViewerInteraction.toolScrollAmount(W(precise: true, delta: CGSize(width: 0, height: 24)))!, 0.1,
                       accuracy: 1e-6)
        XCTAssertNil(ViewerInteraction.toolScrollAmount(W(precise: true, delta: CGSize(width: 0, height: 24),
                                                           momentumPhase: .changed)))
        XCTAssertNil(ViewerInteraction.toolScrollAmount(W(precise: true, delta: CGSize(width: 5, height: 0))))
    }
}
