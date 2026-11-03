import XCTest
import PixelEngine
@testable import latent_app

/// The editor side of Black & White and Point Colour: the treatment
/// switch, the picker's one click, and undo for both.
@MainActor
final class ColourToolsTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    /// The first switch to Black & White sets the mix with Auto in the same
    /// step, so one Undo returns to colour with no mix; switching back to
    /// Color keeps the mix.
    func testTreatmentSwitchSetsAutoMixAndUndoes() async throws {
        let model = try await openModel()
        model.toggleBlackAndWhite()
        XCTAssertTrue(model.isBlackAndWhite)
        let mix = model.parameters.colour.blackAndWhite.mix
        XCTAssertEqual(mix.count, 8)
        model.flushPendingSave()
        XCTAssertEqual(model.history.steps.last?.label, "Treatment")

        model.toggleBlackAndWhite()
        XCTAssertFalse(model.isBlackAndWhite)
        XCTAssertEqual(model.parameters.colour.blackAndWhite.mix, mix, "the mix is kept in Color")

        model.undo()
        XCTAssertTrue(model.isBlackAndWhite)
        model.undo()
        XCTAssertFalse(model.isBlackAndWhite)
        XCTAssertTrue(model.parameters.colour.blackAndWhite.mixIsNeutral)
    }

    /// Pick takes one click: it adds a swatch of the colour under it,
    /// selects it, and lets go of the image on release.
    func testPickerAddsOneSwatchThenDisarms() async throws {
        let model = try await openModel()
        model.addLocal(.linear)
        XCTAssertEqual(model.maskTool, .linear)
        let locals = model.parameters.locals

        model.beginPointColourPick()
        XCTAssertTrue(model.pointColourPicking)
        XCTAssertTrue(model.imageToolActive)
        model.imageToolBegan(at: CGPoint(x: 600, y: 400), exclude: false)
        model.imageToolMoved(to: CGPoint(x: 700, y: 500))
        model.imageToolEnded()

        XCTAssertFalse(model.pointColourPicking)
        XCTAssertEqual(model.parameters.colour.pointColours.count, 1)
        XCTAssertEqual(model.selectedPointColour, 0)
        XCTAssertEqual(model.parameters.locals, locals, "the click went to the picker, not the gradient")
        let swatch = try XCTUnwrap(model.parameters.colour.pointColours.first)
        XCTAssertTrue((0...1).contains(swatch.value) && swatch.value > 0, "a real colour was read")

        model.flushPendingSave()
        model.undo()
        XCTAssertTrue(model.parameters.colour.pointColours.isEmpty)

        model.beginPointColourPick()
        model.disarmTools()
        XCTAssertFalse(model.pointColourPicking, "Escape leaves the picker too")
    }
}
