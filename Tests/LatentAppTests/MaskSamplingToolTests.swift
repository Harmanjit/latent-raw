import XCTest
import simd
import PixelEngine
@testable import latent_app

/// Shift- and Option-clicks with the Pick Range and Colour Range
/// eyedroppers (EditorModel+MaskSampling.swift) and adding a mask preset
/// to a photo (MaskPresetsMenu.swift).
@MainActor
final class MaskSamplingToolTests: XCTestCase {
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

    /// One click on the image at normalised `p`, as the view would send it.
    private func pick(_ model: EditorModel, at p: SIMD2<Float>, mode: MaskSampleMode) {
        model.maskTool = .lumaSample
        model.beginRangeSample(at: p, mode: mode)
        model.finishRangeSample(CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0))
    }

    func testShiftClickGrowsAndOptionClickShrinksTheRange() async throws {
        let model = try await openModel()
        model.addLuminanceRangeMask()
        pick(model, at: SIMD2(0.5, 0.5), mode: .replace)
        XCTAssertEqual(model.maskTool, .none, "a plain click still puts the eyedropper away")
        let first = try XCTUnwrap(model.selectedRangeBand)

        // Find a spot whose value lies well outside the first band.
        var far: SIMD2<Float>?
        for y in stride(from: Float(0.05), through: 0.95, by: 0.1) {
            for x in stride(from: Float(0.05), through: 0.95, by: 0.1) {
                let p = SIMD2(x, y)
                guard let w = model.workingColour(at: p) else { continue }
                let v = MaskRangeInputs(working: w, contrast: model.parameters.contrast, greyPoint: model.parameters.greyPoint,
                                        toneRanges: model.parameters.toneRanges).value(nil)
                if v < first.low - 0.05 || v > first.high + 0.05 { far = p; break }
            }
            if far != nil { break }
        }
        let other = try XCTUnwrap(far, "the test raw has more than one tone")

        pick(model, at: other, mode: .add)
        XCTAssertEqual(model.maskTool, .lumaSample, "Shift-click keeps the eyedropper armed")
        let grown = try XCTUnwrap(model.selectedRangeBand)
        XCTAssertLessThanOrEqual(grown.low, first.low + 1e-5)
        XCTAssertGreaterThanOrEqual(grown.high, first.high - 1e-5)
        XCTAssertGreaterThan(grown.high - grown.low, first.high - first.low + 0.01)
        XCTAssertEqual(model.maskSamplePoints.count, 2, "both samples are drawn while armed")

        pick(model, at: other, mode: .remove)
        let shrunk = try XCTUnwrap(model.selectedRangeBand)
        XCTAssertEqual(shrunk.low, first.low, accuracy: 1e-5)
        XCTAssertEqual(shrunk.high, first.high, accuracy: 1e-5)
        XCTAssertEqual(model.maskSamplePoints.count, 1)
        model.maskTool = .none
        XCTAssertTrue(model.maskSamplePoints.isEmpty, "points show only while the tool is armed")
    }

    func testOptionClickRemovesTheNearestColourSample() async throws {
        let model = try await openModel()
        model.addColourRangeMask()
        model.maskToolBegan(at: CGPoint(x: 300, y: 200)); model.maskToolEnded()
        model.maskToolBegan(at: CGPoint(x: 900, y: 600)); model.maskToolEnded()
        XCTAssertEqual(model.maskSamplePoints.count, 2)
        let kept = try XCTUnwrap(model.maskSamplePoints.first)
        model.removeColourSample(near: model.sensorNormalized(CGPoint(x: 890, y: 590)))
        guard case .colour(let range)? = model.parameters.locals[0].components.first?.source else { return XCTFail() }
        XCTAssertEqual(range.samples.count, 1)
        XCTAssertEqual(model.maskSamplePoints, [kept], "the far sample stays")
    }

    func testApplyingAPresetAddsAMask() async throws {
        let model = try await openModel()
        model.addLocal(.radial)
        model.parameters.locals[0].exposureEV = 0.8
        let (preset, _) = MaskPreset.capture(model.parameters.locals[0], name: "Glow")
        XCTAssertTrue(model.applyMaskPreset(preset))
        XCTAssertEqual(model.parameters.locals.count, 2, "added, never replacing")
        XCTAssertEqual(model.parameters.locals[1].name, "Glow")
        XCTAssertEqual(model.parameters.locals[1].exposureEV, 0.8)
        XCTAssertNotEqual(model.parameters.locals[1].id, model.parameters.locals[0].id)
        XCTAssertEqual(model.selectedLocalIndex, 1)
    }
}

/// Copy Mask and Paste Mask on the open photo, and when the commands are
/// offered (MaskClipboardCommands.swift).
@MainActor
final class MaskClipboardCommandTests: XCTestCase {
    func testPasteAddsACopyAndNeverReplaces() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: nil)
        XCTAssertTrue(model.hasImage)
        let clipboard = MaskClipboard()
        XCTAssertFalse(model.pasteMask(from: clipboard), "nothing copied yet")

        model.addLocal(.radial)
        model.parameters.locals[0].exposureEV = 0.8
        model.parameters.locals[0].components = [MaskComponent(mode: .subtract, source: .mask(id: UUID()))]
        model.copyMask(at: 0, to: clipboard)
        XCTAssertTrue(model.status.contains("Linked Mask"), model.status)
        model.flushPendingSave()
        XCTAssertTrue(model.pasteMask(from: clipboard))
        model.flushPendingSave()
        XCTAssertTrue(model.pasteMask(from: clipboard))
        XCTAssertEqual(model.parameters.locals.count, 3, "each paste adds a mask")
        XCTAssertEqual(model.parameters.locals[1].exposureEV, 0.8)
        XCTAssertTrue(model.parameters.locals[1].components.isEmpty, "the link to this photo's mask is dropped")
        XCTAssertEqual(Set(model.parameters.locals.map(\.id)).count, 3, "fresh ids every time")
        XCTAssertEqual(model.selectedLocalIndex, 2)
        model.undo()
        XCTAssertEqual(model.parameters.locals.count, 2, "one paste is one undo step")
    }

    func testCommandsNeedACopiedMask() {
        var state = CommandState()
        state.mode = .develop
        state.hasImage = true
        state.canAddMask = true
        state.hasSelectedMask = true
        state.selectionCount = 2
        XCTAssertTrue(state.isEnabled(.mask(.copy)))
        XCTAssertFalse(state.isEnabled(.mask(.paste)))
        XCTAssertFalse(state.isEnabled(.mask(.pasteToSelection)))
        state.hasCopiedMask = true
        XCTAssertTrue(state.isEnabled(.mask(.paste)))
        XCTAssertTrue(state.isEnabled(.mask(.pasteToSelection)))
        state.canAddMask = false
        XCTAssertFalse(state.isEnabled(.mask(.paste)), "no room for another mask")
        state.mode = .survey
        XCTAssertFalse(state.isEnabled(.mask(.pasteToSelection)), "Survey's panes are never written")
        for command in MaskClipboardCommand.allCases {
            XCTAssertNotNil(Keymap.info(for: .mask(command)), "\(command) is in the keymap catalog")
        }
    }
}
