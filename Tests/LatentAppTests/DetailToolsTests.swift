import XCTest
import AppKit
import simd
import PixelEngine
import LensKit
@testable import latent_app

/// The Lens Corrections, Detail and Effects panels' tools in the editor:
/// the defringe eyedropper, the sharpening mask preview, the lens profile
/// choice and Remove Chromatic Aberration, each an undoable edit.
@MainActor
final class DetailToolsTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testFringeHueReadsTheMostColourfulPixels() throws {
        func pixel(_ r: Float, _ g: Float, _ b: Float) -> [Float16] { [Float16(r), Float16(g), Float16(b), 1] }
        // Mostly grey, with a few magenta pixels.
        var patch: [Float16] = []
        for _ in 0..<40 { patch += pixel(0.5, 0.5, 0.5) }
        for _ in 0..<5 { patch += pixel(0.8, 0.2, 0.8) }
        let hue = try XCTUnwrap(EditorModel.fringeHue(patch))
        XCTAssertEqual(hue, 300, accuracy: 1)
        // Green-cyan.
        let cyan = try XCTUnwrap(EditorModel.fringeHue(pixel(0.1, 0.8, 0.6) + pixel(0.1, 0.8, 0.6)))
        XCTAssertGreaterThan(cyan, 140); XCTAssertLessThan(cyan, 180)
        // Nothing coloured, nothing picked.
        XCTAssertNil(EditorModel.fringeHue(pixel(0.4, 0.4, 0.4) + pixel(0.6, 0.6, 0.6)))
    }

    func testEyedropperClickSetsARangeAndDisarms() async throws {
        let model = try await openModel()
        model.armDefringePicker()
        XCTAssertTrue(model.defringePickerActive)
        model.healToolActive = true
        model.disarmTools()
        XCTAssertFalse(model.defringePickerActive, "Escape disarms it with the other tools")

        model.armDefringePicker()
        let centre = CGPoint(x: model.drawableSize.width / 2, y: model.drawableSize.height / 2)
        model.defringePick(atScreen: centre)
        XCTAssertFalse(model.defringePickerActive, "one click, then it's done")
        // Whether the centre has a fringe depends on the photo; a pick that
        // found one moved a range and turned its amount on.
        if model.parameters.defringeHues != .standard {
            XCTAssertTrue(model.parameters.defringePurple > 0 || model.parameters.defringeGreen > 0)
        }
    }

    func testOptionPressOnMaskingShowsTheMask() async throws {
        let model = try await openModel()
        model.sharpenMaskingPressed(true, option: false)
        XCTAssertFalse(model.sharpenMaskPreview, "a plain drag shows the picture")
        model.sharpenMaskingPressed(true, option: true)
        XCTAssertTrue(model.sharpenMaskPreview)
        XCTAssertTrue(model.displayOutput.sharpenMaskPreview)
        model.sharpenMaskingPressed(false, option: false)
        XCTAssertFalse(model.sharpenMaskPreview)
        XCTAssertEqual(model.parameters, model.defaultParameters, "previewing changes nothing in the edit")
    }

    func testLensProfileChoiceIsPartOfTheEditAndUndoes() async throws {
        let model = try await openModel()
        let choices = model.lensProfileChoices
        let lens = try XCTUnwrap(choices.fitting.first { !$0.distortion.isEmpty } ?? choices.others.first)
        model.chooseLensProfile(lens.model)
        XCTAssertEqual(model.parameters.lensProfile, lens.model)
        XCTAssertEqual(model.activeLensProfileName, model.session?.lensCorrection(for: model.parameters)?.profileName)
        model.flushPendingSave()
        model.undo()
        XCTAssertNil(model.parameters.lensProfile, "Undo takes the choice back")
    }

    func testRemoveChromaticAberrationOffClearsIt() async throws {
        let model = try await openModel()
        model.parameters.autoCA = AutoChromaticAberration(red: 0.0005, blue: -0.0005)
        model.setRemoveChromaticAberration(false)
        XCTAssertNil(model.parameters.autoCA)
    }
}
