import XCTest
import AppKit
import simd
import PixelEngine
@testable import latent_app

/// Editing a placed shape by its handles, the scroll wheel, Keep tool
/// armed, the range eyedropper and probe, and Show Channel
/// (EditorModel+MaskShapes.swift).
@MainActor
final class MaskShapeToolTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: EditorModel.keepMaskToolArmedKey)
    }

    private func placeRadial(_ model: EditorModel) {
        model.addLocal(.radial)
        // Away from the default ellipse's middle, so the drag draws.
        model.maskToolBegan(at: CGPoint(x: 300, y: 300))
        model.maskToolMoved(to: CGPoint(x: 400, y: 300))
        model.maskToolEnded()
    }

    func testTheRotateHandleTurnsTheEllipse() async throws {
        let model = try await openModel()
        placeRadial(model)
        XCTAssertEqual(model.maskTool, .none, "the tool puts itself away, as before")
        model.maskTool = .radial
        let shape = model.parameters.locals[0].shape
        let rotate = try XCTUnwrap(shape.handlePositions(sensorSize: model.sensorSizeVector).first { $0.handle == .radialRotate })
        let press = model.screenPoint(fromNormalized: rotate.point)
        XCTAssertEqual(model.maskHandle(atScreen: press), .radialRotate)
        model.maskToolBegan(at: press)
        guard case .radial(let centre, _, _, _) = shape else { return XCTFail() }
        let c = model.screenPoint(fromNormalized: centre)
        model.maskToolMoved(to: CGPoint(x: c.x + 150, y: c.y))
        model.maskToolEnded()
        let turned = model.parameters.locals[0].shape
        XCTAssertEqual(abs(turned.radialAngle), 90, accuracy: 3, "dragged a quarter turn round")
        guard case .radial(let sameCentre, _, _, _) = turned else { return XCTFail() }
        XCTAssertEqual(sameCentre, centre, "turning leaves it where it was")
    }

    func testScrollChangesFeatherAndShiftScrollAmount() async throws {
        let model = try await openModel()
        placeRadial(model)
        model.maskTool = .radial
        guard case .radial(let centre, _, let feather, _) = model.parameters.locals[0].shape else { return XCTFail() }
        let inside = model.screenPoint(fromNormalized: centre)
        XCTAssertTrue(model.maskToolScrolled(atScreen: inside, delta: 1, shift: false))
        guard case .radial(_, _, let more, _) = model.parameters.locals[0].shape else { return XCTFail() }
        XCTAssertEqual(more, feather + 0.02, accuracy: 1e-5)
        XCTAssertTrue(model.maskToolScrolled(atScreen: inside, delta: -1, shift: true))
        XCTAssertEqual(model.parameters.locals[0].amount, 0.95, accuracy: 1e-5)
        XCTAssertFalse(model.maskToolScrolled(atScreen: CGPoint(x: 1190, y: 790), delta: 1, shift: false),
                       "away from the shape the wheel pans")
        model.maskTool = .none
        XCTAssertFalse(model.maskToolScrolled(atScreen: inside, delta: 1, shift: false), "only while the tool is armed")
    }

    func testKeepToolArmedPlacesSeveralShapes() async throws {
        UserDefaults.standard.set(true, forKey: EditorModel.keepMaskToolArmedKey)
        let model = try await openModel()
        placeRadial(model)
        XCTAssertEqual(model.maskTool, .radial, "still armed")
        model.maskToolBegan(at: CGPoint(x: 900, y: 500))
        model.maskToolMoved(to: CGPoint(x: 960, y: 500))
        model.maskToolEnded()
        XCTAssertEqual(model.parameters.locals.count, 2, "a second radial")
        XCTAssertEqual(model.selectedLocalIndex, 1)
        guard case .radial(let c, _, _, _) = model.parameters.locals[1].shape else { return XCTFail() }
        XCTAssertGreaterThan(c.x, 0.6, "drawn where the drag was")
    }

    func testLuminanceEyedropperSetsTheBand() async throws {
        let model = try await openModel()
        model.addLuminanceRangeMask()
        model.maskTool = .lumaSample
        model.maskToolBegan(at: CGPoint(x: 600, y: 400))
        model.maskToolEnded()
        XCTAssertEqual(model.maskTool, .none, "the eyedropper puts itself away")
        let band = try XCTUnwrap(model.selectedRangeBand)
        XCTAssertLessThanOrEqual(band.high - band.low, 0.2 + 1e-4)
        XCTAssertGreaterThan(band.high - band.low, 0.05)

        // A rectangle spans at least as much as the click inside it did.
        model.maskTool = .lumaSample
        model.maskToolBegan(at: CGPoint(x: 300, y: 200))
        model.maskToolMoved(to: CGPoint(x: 900, y: 600))
        model.maskToolEnded()
        let spanned = try XCTUnwrap(model.selectedRangeBand)
        XCTAssertLessThan(spanned.low, spanned.high)

        model.updateMaskRangeProbe(atScreen: CGPoint(x: 600, y: 400))
        let probe = try XCTUnwrap(model.maskRangeProbe)
        XCTAssertTrue((0...1).contains(probe))
        model.updateMaskRangeProbe(atScreen: nil)
        XCTAssertNil(model.maskRangeProbe)
    }

    func testShowChannelRidesOnTheDisplayOutput() async throws {
        let model = try await openModel()
        model.addLuminanceRangeMask()
        XCTAssertTrue(model.canShowMaskChannel)
        XCTAssertNil(model.displayOutput.maskOverlayStyle.channelComponent)
        model.showMaskChannel = true
        XCTAssertEqual(model.displayOutput.maskOverlay, 0)
        XCTAssertEqual(model.displayOutput.maskOverlayStyle.channelComponent, 0)
        model.selectedMaskComponentID = nil
        XCTAssertNil(model.displayOutput.maskOverlayStyle.channelComponent, "only for a range component")
    }
}
