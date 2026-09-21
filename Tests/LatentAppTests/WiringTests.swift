import XCTest
import AppKit
import simd
import Catalog
import PixelEngine
import MLKit
@testable import latent_app

/// The lead's Wave 2 wiring (docs/Retouch.md §14): the calls the editor's
/// stored properties, `open`, `closeImage`, memory pressure, the display
/// output and paste make into the dust and touch-up work. Each is checked
/// from outside the hook, so one dropped in a merge shows up here rather
/// than in the app. Vision is stood in for by drawn faces, as
/// TouchUpToolTests does; Find Spots runs for real on the D750 raw.
@MainActor
final class WiringTests: XCTestCase {
    override func tearDown() async throws {
        EditorModel.touchUpPasses = .live
    }

    private func openModel(editStackJSON: String? = nil) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    /// A stored edit with the fake's two faces and a slider.
    private func storedFaces(skinSmoothing: Float) throws -> String {
        var p = EditParameters()
        p.touchUp.faces = TouchUpToolTests.boxes.map { TouchUpFace(boundingBox: $0) }
        p.touchUp.skinSmoothing = skinSmoothing
        p.touchUp.modelVersion = FaceLandmarker.modelVersion
        return try EditStack(parameters: p).encodeJSON()
    }

    // MARK: - Dust

    /// Find Spots keeps its analysis for the Sensitivity and Spot Size
    /// controls; disarming the tool, by hand or through another tool,
    /// drops it (the `dustToolActive` didSet).
    func testDisarmingTheDustToolDropsTheAnalysis() async throws {
        let model = try await openModel()
        model.findDustSpots()
        XCTAssertTrue(model.findingDust)
        await waitUntil("Find Spots", seconds: 60) { !model.findingDust }
        XCTAssertTrue(model.dustToolActive, "Find Spots arms the tool")
        XCTAssertNotNil(model.dustAnalysis)

        model.dustToolActive = false
        XCTAssertNil(model.dustAnalysis)

        model.findDustSpots()
        await waitUntil("Find Spots again", seconds: 60) { !model.findingDust }
        XCTAssertNotNil(model.dustAnalysis)
        model.healToolActive = true
        XCTAssertFalse(model.dustToolActive, "the tools are exclusive")
        XCTAssertNil(model.dustAnalysis)
    }

    /// The viewport's own passes ride on the display output: the dust
    /// visualisation while it is on and the photo is not shown Before,
    /// the skin tint while Show Skin Mask is on and the stage would run.
    func testDisplayOutputCarriesTheVisualisationAndTheSkinMask() async throws {
        let fake = TouchUpToolTests.FakePasses(boxes: TouchUpToolTests.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel(editStackJSON: storedFaces(skinSmoothing: 40))
        XCTAssertNil(model.displayOutput.spotVisualisation)
        XCTAssertFalse(model.displayOutput.touchUpOverlay)

        model.visualiseSpots = true
        model.visualiseThreshold = 0.3
        XCTAssertEqual(model.displayOutput.spotVisualisation?.threshold, 0.3)
        model.showSkinMask = true
        XCTAssertTrue(model.displayOutput.touchUpOverlay)

        model.showingBefore = true
        XCTAssertNil(model.displayOutput.spotVisualisation, "Before shows the photo as it came")
        model.showingBefore = false
        model.parameters.touchUp.skinSmoothing = 0
        XCTAssertFalse(model.displayOutput.touchUpOverlay, "nothing to tint with every slider at zero")
        XCTAssertNotNil(model.displayOutput.spotVisualisation)
    }

    // MARK: - Touch-up

    /// Opening an image whose stored touch-up wants masks builds them (the
    /// `open` hook), a slider leaving zero on one that has none builds
    /// them too (the `parameters` didSet), and closing drops everything of
    /// the image's dust and touch-up (the `closeImage` hooks).
    func testOpeningSlidersAndClosingReachTouchUpAndDust() async throws {
        let fake = TouchUpToolTests.FakePasses(boxes: TouchUpToolTests.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel(editStackJSON: storedFaces(skinSmoothing: 40))
        let session = try XCTUnwrap(model.session)
        await waitUntil("the masks built on open", seconds: 20) { session.hasTouchUpMasks }
        XCTAssertEqual(fake.builds, 1)
        XCTAssertEqual(fake.finds, 0, "the stored faces are kept, not found again")
        await waitUntil("the thumbnails", seconds: 5) { model.faceThumbnails.count == 2 }

        let atZero = try await openModel(editStackJSON: storedFaces(skinSmoothing: 0))
        let zeroSession = try XCTUnwrap(atZero.session)
        XCTAssertFalse(zeroSession.hasTouchUpMasks, "nothing to build for sliders at zero")
        atZero.parameters.touchUp.skinSmoothing = 30
        await waitUntil("the masks built for the slider", seconds: 20) { zeroSession.hasTouchUpMasks }
        XCTAssertEqual(fake.builds, 2)

        atZero.dustToolActive = true
        atZero.visualiseSpots = true
        atZero.showSkinMask = true
        atZero.selectedBlemishIndex = 0
        atZero.closeImage()
        XCTAssertFalse(atZero.dustToolActive)
        XCTAssertFalse(atZero.visualiseSpots)
        XCTAssertFalse(atZero.showSkinMask)
        XCTAssertNil(atZero.selectedBlemishIndex)
        XCTAssertTrue(atZero.faceThumbnails.isEmpty)
        XCTAssertEqual(atZero.touchUpStatus, "")
    }

    /// Pasting a touch-up that wants masks onto an image with no faces
    /// runs Find Faces at once (the `apply` hook): the pasted sliders
    /// would otherwise do nothing until the user found them.
    func testPastingATouchUpFindsFaces() async throws {
        let fake = TouchUpToolTests.FakePasses(boxes: TouchUpToolTests.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        var pasted = EditParameters()
        pasted.touchUp.skinSmoothing = 60
        model.apply(EditStack(parameters: pasted), groups: [.touchUp])
        XCTAssertTrue(model.findingFaces)
        await waitUntil("Find Faces", seconds: 20) { !model.findingFaces }
        XCTAssertEqual(fake.finds, 1)
        XCTAssertEqual(model.parameters.touchUp.faces.count, 2)
        XCTAssertEqual(model.parameters.touchUp.skinSmoothing, 60)

        // Pasted again onto the faces it has: nothing to find.
        model.apply(EditStack(parameters: pasted), groups: [.touchUp])
        XCTAssertFalse(model.findingFaces)
        XCTAssertEqual(fake.finds, 1)
    }

    /// Memory pressure: a warning drops the dust analysis; critical drops
    /// the touch-up masks and normal builds them again (the
    /// `releaseMemory` hooks).
    func testMemoryPressureReachesDustAndTouchUp() async throws {
        let fake = TouchUpToolTests.FakePasses(boxes: TouchUpToolTests.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel(editStackJSON: storedFaces(skinSmoothing: 40))
        let session = try XCTUnwrap(model.session)
        await waitUntil("the masks", seconds: 20) { session.hasTouchUpMasks }
        model.findDustSpots()
        await waitUntil("Find Spots", seconds: 60) { !model.findingDust }
        XCTAssertNotNil(model.dustAnalysis)

        model.releaseMemory(for: .warning)
        XCTAssertNil(model.dustAnalysis)
        XCTAssertTrue(session.hasTouchUpMasks, "a warning keeps the masks")
        // The tool stays armed with its rings; the two controls that
        // re-detect from the analysis say what happened and what to do.
        XCTAssertTrue(model.dustToolActive)
        XCTAssertEqual(model.status, "Memory is low: click Find Spots again to change Sensitivity or Spot Size")
        model.dustSensitivity = 90
        model.redetectDustIfArmed()
        XCTAssertFalse(model.findingDust)
        XCTAssertEqual(model.status, "Click Find Spots to use the new Sensitivity or Spot Size")

        model.releaseMemory(for: .critical)
        XCTAssertFalse(session.hasTouchUpMasks)
        XCTAssertTrue(model.touchUpReleasedUnderPressure)
        XCTAssertEqual(model.status, "Memory is low: touch-up will show again when memory recovers")

        model.releaseMemory(for: .normal)
        XCTAssertFalse(model.touchUpReleasedUnderPressure)
        await waitUntil("the masks built again", seconds: 20) { session.hasTouchUpMasks }
        XCTAssertEqual(fake.builds, 2)
    }

    /// A memory warning cancels a click-to-select encoding under way; the
    /// encode itself cannot be stopped, so what it made must not land
    /// once it ends: the memory the warning asked for would be back with
    /// no click.
    func testAWarningCancelsAnEncodeUnderWay() async throws {
        try XCTSkipUnless(ModelRegistry.shared.defaultPrompted() != nil, "no click-to-select model")
        let model = try await openModel()
        model.addPromptedMask()
        XCTAssertEqual(model.maskTool, .prompt)
        let task = try XCTUnwrap(model.promptEncoding.values.first, "the encode started")

        model.releaseMemory(for: .critical)
        XCTAssertTrue(model.promptEncoding.isEmpty)
        let landed = await task.value
        XCTAssertNil(landed, "a cancelled encode reports nothing")
        XCTAssertTrue(model.promptSessions.isEmpty)
        XCTAssertTrue(model.promptStatus.isEmpty)
    }

    // MARK: - The panel

    /// The Cancel button's spoken name for each job on the queue.
    func testCancelLabelsForTheSelectionJobs() {
        XCTAssertEqual(LibraryPanel.cancelLabel(forJob: FaceFindJob().title), "Cancel face search")
        XCTAssertEqual(LibraryPanel.cancelLabel(forJob: "Dust removal"), "Cancel dust removal")
    }
}
