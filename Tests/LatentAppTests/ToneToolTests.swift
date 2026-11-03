import XCTest
import AppKit
import ColorKit
import PixelEngine
@testable import latent_app

/// The tone and colour tools in the editor: white balance presets and
/// the selector, the targeted adjustment tools, the clipping overlay and
/// the readout, and the keys and menu items that reach them.
@MainActor
final class ToneToolTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    private var centre: CGPoint { CGPoint(x: 600, y: 400) }

    // MARK: - Keys and menus

    func testKeysAndMenuItems() {
        XCTAssertEqual(KeyCommand.command(for: BareKeyPress(.character("j"))), .toggleClipping)
        XCTAssertEqual(KeyCommand.command(for: BareKeyPress(.character("w"))), .whiteBalanceSelector)
        var state = CommandState()
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(.toggleClipping), "nothing open")
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(.toggleClipping))
        XCTAssertTrue(state.isEnabled(.whiteBalanceSelector))
        state.mode = .library
        XCTAssertFalse(state.isEnabled(.whiteBalanceSelector))
        XCTAssertEqual(state.clippingTitle, "Show Clipping")
        state.clippingShown = true
        XCTAssertEqual(state.clippingTitle, "Hide Clipping")
    }

    // MARK: - Pure pieces

    func testCurvePointForATargetedDrag() {
        let (added, i) = EditorModel.curve(.identity, withPointAt: 0.4)
        XCTAssertEqual(added.points.count, 3)
        XCTAssertEqual(i, 1)
        XCTAssertEqual(added.points[1].x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(added.points[1].y, 0.4, accuracy: 0.01, "on the curve as drawn")
        let (reused, j) = EditorModel.curve(added, withPointAt: 0.42)
        XCTAssertEqual(reused, added, "a point within reach is taken, not doubled")
        XCTAssertEqual(j, 1)
        let (_, end) = EditorModel.curve(.identity, withPointAt: 0.999)
        XCTAssertEqual(end, 1, "the end points stay pinned; a new one goes just inside")
    }

    func testHistogramRegions() {
        XCTAssertEqual(HistogramRegion.at(0.05), .blacks)
        XCTAssertEqual(HistogramRegion.at(0.2), .shadows)
        XCTAssertEqual(HistogramRegion.at(0.5), .exposure)
        XCTAssertEqual(HistogramRegion.at(0.8), .highlights)
        XCTAssertEqual(HistogramRegion.at(1), .whites)
        var p = EditParameters()
        HistogramRegion.whites.set(3, in: &p)
        XCTAssertEqual(p.toneRanges.whites, 1, "clamped to the slider")
        HistogramRegion.exposure.set(2.5, in: &p)
        XCTAssertEqual(p.exposureEV, 2.5)
        XCTAssertEqual(HistogramRegion.exposure.value(in: p), 2.5)
    }

    // MARK: - On an open photo

    func testWhiteBalancePresetsAndKelvin() async throws {
        let model = try await openModel()
        XCTAssertEqual(model.whiteBalancePreset, .asShot)
        model.applyWhiteBalancePreset(.tungsten)
        XCTAssertEqual(model.parameters.whiteBalance.temperature, 2850)
        XCTAssertEqual(model.whiteBalancePreset, .tungsten)
        model.applyWhiteBalancePreset(.auto)
        XCTAssertEqual(model.whiteBalancePreset, .auto, "Auto keeps its name while untouched")
        model.temperatureKelvinBinding.wrappedValue = 50_000
        XCTAssertEqual(model.parameters.whiteBalance.temperature, ColorKit.WhiteBalance.temperatureRange.upperBound)
        XCTAssertNil(model.whiteBalancePreset, "a typed value is custom")
        model.applyWhiteBalancePreset(.asShot)
        XCTAssertEqual(model.parameters.whiteBalance, model.asShotWhiteBalance)
    }

    func testToneToolsAreExclusiveWithTheOtherTools() async throws {
        let model = try await openModel()
        model.healToolActive = true
        model.toneTool = .curve
        XCTAssertFalse(model.healToolActive)
        XCTAssertTrue(model.imageToolActive)
        model.redEyeToolActive = true
        XCTAssertEqual(model.toneTool, .none)
        model.toneTool = .whiteBalance
        model.disarmTools()
        XCTAssertEqual(model.toneTool, .none)
    }

    func testCurveTargetedDragIsOneUndoStep() async throws {
        let model = try await openModel()
        XCTAssertNotNil(model.displayedPixel(atScreen: centre), "the centre of the view is on the photo")
        XCTAssertNil(model.displayedPixel(atScreen: CGPoint(x: -50, y: -50)))
        model.toneTool = .curve
        model.imageToolBegan(at: centre, exclude: false)
        model.imageToolMoved(to: CGPoint(x: centre.x, y: centre.y - 100))
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.toneCurve.points.count, 3)
        let point = model.parameters.toneCurve.points[1]
        XCTAssertGreaterThan(point.y, point.x, "dragging up lightens that tone")
        model.flushPendingSave()
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.parameters.toneCurve.isIdentity)

        // Region mode moves the region the tone is in.
        model.curveEditorMode = .parametric
        model.imageToolBegan(at: centre, exclude: false)
        model.imageToolMoved(to: CGPoint(x: centre.x, y: centre.y + 100))
        model.imageToolEnded()
        XCTAssertFalse(model.parameters.parametricCurve.isNeutral)
        XCTAssertTrue(model.parameters.parametricCurve.amounts.allSatisfy { $0 <= 0 }, "down darkens")
    }

    func testColourTargetedDragMovesTheBandsUnderThePointer() async throws {
        let model = try await openModel()
        model.toneTool = .colour(.saturation)
        model.imageToolBegan(at: centre, exclude: false)
        model.imageToolMoved(to: CGPoint(x: centre.x, y: centre.y - 200))
        model.imageToolEnded()
        let moved = model.parameters.hsl.saturation.filter { $0 != 0 }
        XCTAssertFalse(moved.isEmpty)
        XCTAssertLessThanOrEqual(moved.count, 2, "one hue touches two bands at most")
        XCTAssertTrue(moved.allSatisfy { $0 > 0 })
        XCTAssertEqual(model.parameters.hsl.hue, HSLAdjustments.neutral.hue, "only the chosen slider set")
    }

    func testClippingAndReadout() async throws {
        let model = try await openModel()
        let before = model.parameters
        model.toggleClipping()
        XCTAssertEqual(model.clipping, .both)
        XCTAssertEqual(model.parameters, before, "the overlay is not an edit")
        model.toggleClipping()
        XCTAssertEqual(model.clipping, [])
        model.pointerMoved(to: centre)
        XCTAssertNotNil(model.pixelProbe.readout)
        model.pointerMoved(to: nil)
        XCTAssertNil(model.pixelProbe.readout)
    }

    func testWhiteBalanceSelectorReportsOrApplies() async throws {
        let model = try await openModel()
        let before = model.parameters.whiteBalance
        model.toggleWhiteBalanceSelector()
        XCTAssertEqual(model.toneTool, .whiteBalance)
        model.imageToolBegan(at: centre, exclude: false)
        if model.parameters.whiteBalance != before {
            XCTAssertEqual(model.toneTool, .none, "the selector puts itself away once it has worked")
        } else {
            XCTAssertEqual(model.toneTool, .whiteBalance, "a spot it can't judge leaves it armed")
            XCTAssertFalse(model.status.isEmpty)
        }
    }
}
