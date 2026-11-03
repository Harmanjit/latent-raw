import XCTest
import AppKit
import simd
import PixelEngine
import MLKit
@testable import latent_app

/// The editor side of mask components (EditorModel+MaskComponents.swift):
/// the tools aim at the selected component, housekeeping commands undo
/// like any edit, the eyedropper and the Select Objects box.
@MainActor
final class MaskComponentToolTests: XCTestCase {
    private static let vision = "vision.foregroundInstance@1"

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

    func testAComponentTakesTheToolAndUndoes() async throws {
        let model = try await openModel()
        model.addLocal(.radial)
        model.maskToolBegan(at: CGPoint(x: 600, y: 400))
        model.maskToolMoved(to: CGPoint(x: 700, y: 400))
        model.maskToolEnded()
        let radial = model.parameters.locals[0].shape
        model.flushPendingSave()

        model.addMaskComponent(.brush, mode: .subtract)
        let component = try XCTUnwrap(model.parameters.locals[0].components.first)
        XCTAssertEqual(model.selectedMaskComponentID, component.id)
        XCTAssertEqual(model.maskTool, .brush)
        XCTAssertEqual(component.mode, .subtract)
        model.maskToolBegan(at: CGPoint(x: 600, y: 400))
        model.maskToolMoved(to: CGPoint(x: 650, y: 420))
        model.maskToolEnded()
        XCTAssertEqual(model.parameters.locals[0].shape, radial, "the paint went into the component")
        guard case .brush(let strokes)? = model.parameters.locals[0].components.first?.shape else {
            return XCTFail("still a brush component")
        }
        XCTAssertEqual(strokes.count, 1)

        model.flushPendingSave()
        model.undo()
        XCTAssertTrue(model.parameters.locals[0].components.isEmpty, "Undo takes the component back out")
    }

    func testARadialMovesWhenDraggedFromInside() async throws {
        let model = try await openModel()
        model.addLocal(.radial)
        model.maskToolBegan(at: CGPoint(x: 600, y: 400))
        model.maskToolMoved(to: CGPoint(x: 700, y: 400))
        model.maskToolEnded()
        guard case .radial(let centre, let radii, _) = model.parameters.locals[0].shape else { return XCTFail() }
        model.maskTool = .radial
        model.maskToolBegan(at: CGPoint(x: 610, y: 400))
        model.maskToolMoved(to: CGPoint(x: 510, y: 300))
        model.maskToolEnded()
        guard case .radial(let moved, let sameRadii, _) = model.parameters.locals[0].shape else { return XCTFail() }
        XCTAssertEqual(sameRadii, radii, "moving keeps the size")
        XCTAssertLessThan(moved.x, centre.x)
        XCTAssertLessThan(moved.y, centre.y)
    }

    func testDuplicateHideAndDeleteEmpty() async throws {
        let model = try await openModel()
        model.addLocal(.brush)
        model.addLocal(.radial)
        model.maskToolBegan(at: CGPoint(x: 600, y: 400))
        model.maskToolMoved(to: CGPoint(x: 700, y: 400))
        model.maskToolEnded()
        model.parameters.locals[1].exposureEV = 0.5
        model.duplicateLocal(at: 1, invert: true)
        XCTAssertEqual(model.parameters.locals.count, 3)
        XCTAssertEqual(model.selectedLocalIndex, 2)
        XCTAssertTrue(model.parameters.locals[2].invert)
        XCTAssertEqual(model.parameters.locals[2].exposureEV, 0.5)
        XCTAssertNotEqual(model.parameters.locals[2].id, model.parameters.locals[1].id)

        model.toggleHidden(at: 2)
        XCTAssertTrue(model.parameters.locals[2].hidden)
        model.flushPendingSave()

        XCTAssertTrue(model.hasEmptyMasks, "the brush has no strokes")
        model.deleteEmptyMasks()
        XCTAssertEqual(model.parameters.locals.map(\.name).count, 2)
        XCTAssertEqual(model.selectedLocalIndex, 1, "the selection follows its mask")
        model.flushPendingSave()
        model.undo()
        XCTAssertEqual(model.parameters.locals.count, 3, "Undo brings the empty mask back")
    }

    func testColourRangeEyedropperAddsSamples() async throws {
        let model = try await openModel()
        model.addColourRangeMask()
        XCTAssertEqual(model.maskTool, .colourSample)
        model.maskToolBegan(at: CGPoint(x: 600, y: 400))
        model.maskToolEnded()
        model.maskToolBegan(at: CGPoint(x: 300, y: 200))
        model.maskToolEnded()
        guard case .colour(let range)? = model.parameters.locals[0].components.first?.source else {
            return XCTFail("a colour range component")
        }
        XCTAssertEqual(range.samples.count, 2)
        XCTAssertEqual(model.parameters.locals[0].components.first?.mode, .intersect)
        model.clearColourSamples()
        guard case .colour(let cleared)? = model.parameters.locals[0].components.first?.source else { return XCTFail() }
        XCTAssertTrue(cleared.samples.isEmpty)
    }

    func testAModelComponentGetsPixelsUnderItsOwnID() async throws {
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        model.addLocal(.none)
        let entry = try XCTUnwrap(ModelRegistry.shared.entry(id: ModelRegistry.builtInSubjectID))
        model.addMaskComponent(.subject(entry), mode: .add)
        let id = try XCTUnwrap(model.selectedMaskComponentID)
        await waitUntil("the subject mask", seconds: 60) { !model.generatingMasks.contains(id) }
        XCTAssertTrue(session.hasAIMask(forLocal: id))
        XCTAssertFalse(session.hasAIMask(forLocal: model.parameters.locals[0].id))

        // A duplicate brings the pixels along under the copy's id.
        model.duplicateLocal(at: 0)
        let copyID = try XCTUnwrap(model.parameters.locals[1].components.first?.id)
        XCTAssertTrue(session.hasAIMask(forLocal: copyID))
    }

    func testSelectObjectsBoxBecomesTwoCorners() async throws {
        try XCTSkipUnless(SAM2Models.isAvailable, "SAM 2.1 not bundled")
        let model = try await openModel()
        let entry = try XCTUnwrap(ModelRegistry.shared.defaultPrompted())
        model.addObjectsMask(model: entry)
        XCTAssertEqual(model.maskTool, .box)
        model.maskToolBegan(at: CGPoint(x: 400, y: 250))
        model.maskToolMoved(to: CGPoint(x: 800, y: 600))
        XCTAssertNotNil(model.maskDragBox)
        model.maskToolEnded()
        XCTAssertNil(model.maskDragBox)
        guard case .prompted(let points, _) = model.parameters.locals[0].shape else { return XCTFail() }
        XCTAssertEqual(points.compactMap(\.corner), [1, 2])
        XCTAssertLessThan(points[0].x, points[1].x)
        XCTAssertLessThan(points[0].y, points[1].y)
        let id = model.parameters.locals[0].id
        await waitUntil("the object mask", seconds: 60) {
            model.session?.hasAIMask(forLocal: id) == true && !model.generatingMasks.contains(id)
        }
        XCTAssertTrue(model.session?.hasAIMask(forLocal: id) == true)
    }
}
