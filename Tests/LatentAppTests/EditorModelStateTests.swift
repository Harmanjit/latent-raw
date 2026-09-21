import XCTest
import AppKit
import PixelEngine
import MLKit
@testable import latent_app

/// The editor's state across opening, closing and background work.
@MainActor
final class EditorModelStateTests: XCTestCase {
    /// A file that won't open leaves the editor closed. Nothing of the
    /// photo open before may stay: with its catalog id, history or pending
    /// save still set, Undo or the history load that follows would write
    /// that photo's edit (or its deletion) onto the one that failed.
    func testAFailedOpenLeavesNothingOfThePreviousPhoto() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        XCTAssertTrue(model.isReady)
        var saved: [Int64] = []
        model.onEditSettled = { id, _ in saved.append(id) }

        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.parameters.exposureEV = 1
        model.flushPendingSave()
        XCTAssertTrue(model.canUndo)
        model.parameters.exposureEV = 2   // waiting for its save when the next open begins
        XCTAssertEqual(saved, [1])

        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("latent-not-a-raw-\(UUID()).nef")
        try Data("not a raw file".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        model.open(url: broken, catalogImageID: 2)

        XCTAssertEqual(saved, [1, 1], "the previous photo's pending edit went to that photo")
        XCTAssertFalse(model.hasImage)
        XCTAssertNil(model.catalogImageID)
        XCTAssertNil(model.pendingSave)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.history.canUndo)
        XCTAssertFalse(model.history.canRedo)
        XCTAssertTrue(model.status.hasPrefix("Could not open"), model.status)
        model.undo()
        XCTAssertEqual(saved, [1, 1], "Undo with nothing open writes nothing")
    }

    /// A cancelled denoise run only notices at its next tile. By then the
    /// next image may have started its own run, which must stay running:
    /// memory pressure releases the session's textures only while no run
    /// is reading them, and a second run would start beside it.
    func testACancelledDenoiseRunCannotEndTheNextOne() {
        let model = EditorModel()
        let first = model.beginAIDenoiseRun()
        model.stopAIDenoise()   // the next image opens
        let second = model.beginAIDenoiseRun()
        XCTAssertFalse(model.endAIDenoiseRun(first, status: ""), "the cancelled run reports late")
        XCTAssertTrue(model.aiDenoiseRunning)
        XCTAssertEqual(model.aiDenoiseStatus, "Loading model…")
        XCTAssertTrue(model.endAIDenoiseRun(second, status: "Denoised"))
        XCTAssertFalse(model.aiDenoiseRunning)
        XCTAssertEqual(model.aiDenoiseStatus, "Denoised")
    }

    /// Noise reduction takes seconds to minutes and is often left to run:
    /// the Mac stays awake for it, as for an export.
    func testDenoiseKeepsTheMacAwakeWhileItRuns() async throws {
        let url = TestAssets.url(TestAssets.goldenName)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path) && AIDenoiser.isAvailable)
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url)
        XCTAssertTrue(model.hasImage)
        let held = ExportActivity.activeCount
        model.runAIDenoise()
        XCTAssertTrue(model.aiDenoiseRunning)
        XCTAssertEqual(ExportActivity.activeCount, held + 1)
        model.cancelAIDenoise()
        await waitUntil("the run to stop", seconds: 60) { !model.aiDenoiseRunning }
        XCTAssertEqual(ExportActivity.activeCount, held)
    }

    /// Find Faces runs off the main actor; the photo it was started on may
    /// be closed before it reports. Its faces, masks and status then go
    /// nowhere: the next photo's edit must not get another photo's faces.
    func testFacesFoundAfterThePhotoClosedGoNowhere() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let gate = Gate()
        EditorModel.touchUpPasses = heldFind(at: gate)
        defer { EditorModel.touchUpPasses = .live }
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.findFaces()
        XCTAssertTrue(model.findingFaces)

        model.closeImage()
        model.resetTouchUpForNewImage()   // as the lead's closeImage does
        XCTAssertFalse(model.findingFaces, "the flag went with the photo")
        model.open(url: url, catalogImageID: 2)
        let steps = model.history.steps.count
        gate.open()
        await gate.settled()
        XCTAssertTrue(model.parameters.touchUp.faces.isEmpty, "another photo's faces")
        XCTAssertFalse(try XCTUnwrap(model.session).hasTouchUpMasks)
        XCTAssertTrue(model.faceThumbnails.isEmpty)
        XCTAssertEqual(model.history.steps.count, steps)
        XCTAssertNotEqual(model.status, "Found 1 face")
        XCTAssertFalse(model.findingFaces)
    }

    /// A Find Faces still running for the last photo must not stand in
    /// the way of the next one: its stored edit wants masks, and the
    /// on-open build has to run although the old search has not reported
    /// yet. When it does, it changes nothing of the new photo.
    func testAFindStillRunningForTheLastPhotoDoesNotBlockTheNextOnesMasks() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let gate = Gate()
        EditorModel.touchUpPasses = heldFind(at: gate)
        defer { EditorModel.touchUpPasses = .live }
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        model.findFaces()
        XCTAssertTrue(model.findingFaces)

        var stored = EditParameters()
        stored.touchUp.faces = [TouchUpFace(boundingBox: SIMD4(0.2, 0.2, 0.2, 0.3)), TouchUpFace(boundingBox: SIMD4(0.55, 0.25, 0.2, 0.3))]
        stored.touchUp.skinSmoothing = 40
        stored.touchUp.modelVersion = FaceLandmarker.modelVersion
        model.open(url: url, catalogImageID: 2, editStackJSON: try EditStack(parameters: stored).encodeJSON())
        let session = try XCTUnwrap(model.session)
        let faces = model.parameters.touchUp.faces
        XCTAssertEqual(faces.count, 2)
        XCTAssertFalse(model.findingFaces)
        XCTAssertNotNil(model.touchUpMaskTask, "the on-open build started")
        await waitUntil("the masks built on open", seconds: 20) { session.hasTouchUpMasks }
        XCTAssertEqual(session.touchUpMasks?.faces.map(\.id), faces.map(\.id))
        let steps = model.history.steps.count

        gate.open()
        await gate.settled()
        XCTAssertEqual(model.parameters.touchUp.faces, faces, "the old search changed nothing")
        XCTAssertEqual(session.touchUpMasks?.faces.map(\.id), faces.map(\.id))
        XCTAssertEqual(model.history.steps.count, steps)
        XCTAssertFalse(model.findingFaces)
    }

    /// Passes whose `find` waits at `gate` and then reports one face;
    /// `build` makes the fixture set for the stored faces.
    private func heldFind(at gate: Gate) -> EditorModel.TouchUpPasses {
        EditorModel.TouchUpPasses(
            find: { _, image in
                gate.wait()
                defer { gate.passed() }
                let face = TouchUpFace(boundingBox: SIMD4(0.2, 0.2, 0.3, 0.3))
                return TouchUpRegions.Found(faces: [face], tooSmall: 0, masks: Self.fixture(for: [face], image: image),
                                            thumbnails: [:])
            },
            build: { touchUp, _, image in (Self.fixture(for: touchUp.faces, image: image), []) },
            blemishes: { _, _, _, _, _ in [] })
    }

    /// The fixture set with each face's box as its skin.
    nonisolated private static func fixture(for faces: [TouchUpFace], image: EditorModel.TouchUpContext) -> TouchUpMaskSet {
        let summary = image.session.file.summary
        return TouchUpMaskSet.fixture(sensorWidth: summary.rawWidth, sensorHeight: summary.rawHeight,
                                      faces: faces.map { face in
            let b = face.boundingBox
            return (id: face.id, skin: CGRect(x: CGFloat(b.x), y: CGFloat(b.y), width: CGFloat(b.z), height: CGFloat(b.w)),
                    teeth: nil, eyes: [])
        })
    }

    /// Holds a fake pass until the test lets it go, and says when the
    /// pass has returned so the test can wait for its completion to run.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var returned = 0
        func wait() { semaphore.wait() }
        func open() { semaphore.signal() }
        func passed() { lock.withLock { returned += 1 } }
        /// Waits for the held pass to return, then lets its main-actor
        /// completion run (a few turns of the loop).
        @MainActor func settled() async {
            await waitUntil("the held pass to return", seconds: 20) { self.lock.withLock { self.returned } > 0 }
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Paste and presets outside the grid go to the image shown only.
    /// Outside Develop that is always its stored edit, whose Library undo
    /// is what Undo there takes back, even with the editor holding it.
    func testSettingsGoToTheShownImageOutsideTheGrid() {
        typealias Target = ContentView.SettingsTarget
        XCTAssertEqual(Target.choose(mode: .library, editorHasImage: true), .selection)
        XCTAssertEqual(Target.choose(mode: .loupe, editorHasImage: true), .primary)
        XCTAssertEqual(Target.choose(mode: .compare, editorHasImage: true), .primary)
        XCTAssertEqual(Target.choose(mode: .survey, editorHasImage: true), .primary)
        XCTAssertEqual(Target.choose(mode: .loupe, editorHasImage: false), .primary)
        // Develop pastes into whatever it shows, a file opened on its own
        // included, and undoes it in its own history.
        XCTAssertEqual(Target.choose(mode: .develop, editorHasImage: true), .editor)
        XCTAssertEqual(Target.choose(mode: .develop, editorHasImage: false), .primary)
    }

    /// Undo and Redo undo typing in any window, so they follow the key
    /// window's first responder, not only the main window's.
    func testTypingIsSeenInWhicheverWindowIsKey() async {
        let focus = KeyWindowTextFocus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(text)
        focus.watch(window)
        XCTAssertTrue(window.makeFirstResponder(text))
        await settle { focus.isEditingText }
        XCTAssertTrue(focus.isEditingText)
        XCTAssertTrue(window.makeFirstResponder(nil))
        await settle { !focus.isEditingText }
        XCTAssertFalse(focus.isEditingText)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<50 where !done() { await Task.yield() }
    }
}
