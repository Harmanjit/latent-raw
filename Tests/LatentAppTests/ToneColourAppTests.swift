import XCTest
import AppKit
import PixelEngine
@testable import latent_app

/// The app side of the second round of tone and colour tools: Auto setting
/// the tone ranges and presence, Shift-double-click on one slider, the
/// colour wheel's modifiers, hue isolation, Visualise HDR Ranges beside J,
/// and Match Total Exposures' menu state.
@MainActor
final class ToneColourAppTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testAutoSetsToneAndPresence() async throws {
        let model = try await openModel()
        model.parameters.toneRanges = ToneRanges(highlights: 1, shadows: -1, whites: -1, blacks: 1)
        model.autoAdjust()
        let r = model.parameters.toneRanges
        for v in [r.highlights, r.shadows, r.whites, r.blacks] {
            XCTAssertLessThanOrEqual(abs(v), 0.7, "Auto replaced the sliders with its own estimate")
        }
        XCTAssertTrue((0...0.25).contains(model.parameters.vibrance))
        XCTAssertTrue((0...0.05).contains(model.parameters.colour.saturation))
    }

    func testShiftDoubleClickSetsOneSlider() async throws {
        let model = try await openModel()
        model.parameters.toneRanges = ToneRanges(highlights: -0.3, shadows: 0.2, whites: 1, blacks: 0)
        model.autoToneSlider(.whites)
        XCTAssertLessThanOrEqual(abs(model.parameters.toneRanges.whites), 0.7)
        XCTAssertEqual(model.parameters.toneRanges.highlights, -0.3, "the others are kept")
        XCTAssertEqual(model.parameters.toneRanges.shadows, 0.2)
        XCTAssertEqual(model.parameters.toneRanges.blacks, 0)
    }

    func testHueIsolationIsADisplaySetting() async throws {
        let model = try await openModel()
        let before = model.parameters
        model.hueIsolationBand = 2
        XCTAssertEqual(model.displayOutput.hueIsolation, 2)
        XCTAssertEqual(model.parameters, before, "not an edit")
        model.hueIsolationBand = nil
        XCTAssertNil(model.displayOutput.hueIsolation)
    }

    /// J leaves Visualise HDR Ranges alone, and its menu title follows
    /// only the two clipping indicators.
    func testJKeepsHDRRanges() async throws {
        let model = try await openModel()
        model.clipping = .hdrRanges
        model.toggleClipping()
        XCTAssertEqual(model.clipping, [.hdrRanges, .shadows, .highlights])
        model.toggleClipping()
        XCTAssertEqual(model.clipping, .hdrRanges)
    }

    func testColourWheelModifiers() {
        let centre = CGPoint(x: 50, y: 50), radius: CGFloat = 50
        let start = GradingWheel(hue: 0, saturation: 0.5)
        let startPuck = CGPoint(x: 75, y: 50)
        // Plain: the puck goes to the pointer (straight up: hue 90, full).
        let plain = ColourWheel.dragged(start: start, startPuck: startPuck, location: CGPoint(x: 50, y: 0),
                                        translation: CGSize(width: -25, height: -50), centre: centre,
                                        radius: radius, lockHue: false, fine: false)
        XCTAssertEqual(plain.hue, 90, accuracy: 0.1)
        XCTAssertEqual(plain.saturation, 1, accuracy: 0.001)
        // Shift: the hue stays, the strength is the distance along it.
        let locked = ColourWheel.dragged(start: start, startPuck: startPuck, location: CGPoint(x: 90, y: 20),
                                         translation: CGSize(width: 15, height: -30), centre: centre,
                                         radius: radius, lockHue: true, fine: false)
        XCTAssertEqual(locked.hue, 0)
        XCTAssertEqual(locked.saturation, 0.8, accuracy: 0.001)
        // Command: a tenth of the pointer's travel.
        let fine = ColourWheel.dragged(start: start, startPuck: startPuck, location: CGPoint(x: 95, y: 50),
                                       translation: CGSize(width: 20, height: 0), centre: centre,
                                       radius: radius, lockHue: false, fine: true)
        XCTAssertEqual(fine.hue, 0, accuracy: 0.1)
        XCTAssertEqual(fine.saturation, 0.54, accuracy: 0.001)
    }

    func testMatchTotalExposuresMenuState() {
        var state = CommandState()
        state.mode = .library
        state.selectionCount = 1
        XCTAssertFalse(state.isEnabled(.matchTotalExposures), "needs a lead and another")
        state.selectionCount = 3
        XCTAssertTrue(state.isEnabled(.matchTotalExposures))
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(.matchTotalExposures), "Library only")
    }
}
