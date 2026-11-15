import XCTest
import PixelEngine
@testable import latent_app

/// The Tone Equalizer panel's pieces that don't need a window: the band
/// slider's travel, the curve's hit testing, and the editor's actions.
@MainActor
final class ToneEqualizerPanelTests: XCTestCase {
    func testBandSliderTravel() {
        XCTAssertEqual(ToneEqualizerBandSlider.value(at: 0, height: 120), 3)
        XCTAssertEqual(ToneEqualizerBandSlider.value(at: 120, height: 120), -3)
        XCTAssertEqual(ToneEqualizerBandSlider.value(at: 60, height: 120), 0, "0 at the middle")
        XCTAssertEqual(ToneEqualizerBandSlider.value(at: 40, height: 120), 1)
        XCTAssertEqual(ToneEqualizerBandSlider.value(at: -50, height: 120), 3)
    }

    func testCurveNodeUnderThePointer() {
        let width: CGFloat = 200
        for (i, zone) in ToneEqualizer.zones.enumerated() {
            XCTAssertEqual(ToneEqualizerCurve.band(atX: ToneEqualizerCurve.x(zone, width), width: width), i)
        }
    }

    func testToolHint() {
        XCTAssertFalse(ToneTool.toneEqualizer.hint.isEmpty)
    }

    func testBandsAreSetClampedAndReset() {
        let model = EditorModel()
        model.setToneEqualizerBand(2, to: 7)
        XCTAssertEqual(model.parameters.toneEqualizer.bands[2], 3)
        model.setToneEqualizerBand(9, to: 1)
        XCTAssertEqual(model.parameters.toneEqualizer.bands.count, ToneEqualizer.bandCount)
        model.resetToneEqualizer()
        XCTAssertEqual(model.parameters.toneEqualizer, .neutral)
    }

    func testArmingTheToolWantsTheMask() {
        let model = EditorModel()
        XCTAssertFalse(model.toneEqualizerWantsMask)
        model.setToneEqualizerTool(true)
        XCTAssertEqual(model.toneTool, .toneEqualizer)
        XCTAssertTrue(model.toneEqualizerWantsMask)
        model.setToneEqualizerTool(false)
        XCTAssertEqual(model.toneTool, ToneTool.none)
    }

    func testAutoAlignSetsCompensationAndKeepsBands() {
        let model = EditorModel()
        model.setToneEqualizerBand(3, to: 1)
        let values = (0..<1_001).map { -10 + 6 * Float($0) / 1_000 }
        model.applyToneEqualizerAutoAlign(stats: ToneEqualizerMaskStats(values: values), exposureEV: 0)
        let eq = model.parameters.toneEqualizer
        XCTAssertEqual(eq.bands[3], 1)
        XCTAssertEqual(eq.compensated(-10), -8, accuracy: 0.1)
        XCTAssertEqual(eq.compensated(-4), 0, accuracy: 0.1)
    }

    func testAutoAlignWithoutAMaskOnlySaysSo() {
        let model = EditorModel()
        model.status = ""
        model.autoAlignToneEqualizer()
        XCTAssertEqual(model.parameters.toneEqualizer, .neutral)
        XCTAssertFalse(model.status.isEmpty)
    }

    func testBandShareBarHeights() {
        XCTAssertEqual(ToneEqualizerBandShares.heights([0.1, 0.4, 0.2]), [0.25, 1, 0.5])
        XCTAssertEqual(ToneEqualizerBandShares.heights([0, 0]), [0, 0])
        XCTAssertEqual(ToneEqualizerBandShares.heights([]), [])
    }
}
