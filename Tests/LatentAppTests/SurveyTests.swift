import XCTest
import Catalog
import PixelEngine
@testable import latent_app

/// Survey (N): its commands, and its panes' models, linked views and memory.
@MainActor
final class SurveyTests: XCTestCase {
    private static func asset(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets").appendingPathComponent(name)
    }

    private func state(_ change: (inout CommandState) -> Void) -> CommandState {
        var state = CommandState()
        state.hasVisibleImages = true
        state.hasSelection = true
        state.editorReady = true
        change(&state)
        return state
    }

    // MARK: - Commands

    func testSurveyNeedsTwoToFourSelected() {
        XCTAssertFalse(state { $0.selectionCount = 1 }.isEnabled(.survey))
        XCTAssertTrue(state { $0.selectionCount = 2 }.isEnabled(.survey))
        XCTAssertTrue(state { $0.selectionCount = 4 }.isEnabled(.survey))
        XCTAssertFalse(state { $0.selectionCount = 5 }.isEnabled(.survey))
        XCTAssertFalse(state { $0.selectionCount = 3; $0.hasSelection = false }.isEnabled(.survey))
        XCTAssertTrue(state { $0.mode = .survey; $0.selectionCount = 1 }.isEnabled(.survey), "already there")
    }

    /// Zoom follows the focused pane's image, not the editor's, which
    /// Survey doesn't load; Before/After has no pane to show.
    func testZoomInSurveyFollowsTheFocusedPane() {
        let survey = state { $0.mode = .survey; $0.selectionCount = 3; $0.hasImage = false; $0.surveyHasImage = true }
        XCTAssertTrue(survey.isEnabled(.zoomIn))
        XCTAssertTrue(survey.isEnabled(.toggleZoom))
        XCTAssertTrue(survey.isEnabled(.removeFromSurvey))
        XCTAssertFalse(survey.isEnabled(.beforeAfter))
        XCTAssertFalse(state { $0.mode = .survey; $0.hasImage = true }.isEnabled(.zoomToFit), "the pane is still opening")
        XCTAssertFalse(state { $0.mode = .loupe; $0.hasImage = true }.isEnabled(.removeFromSurvey))
        XCTAssertTrue(state { $0.mode = .loupe; $0.hasImage = true }.isEnabled(.zoomToFit))
    }

    /// Print, Edit in External Editor and Export Open Image never reach an
    /// image the editor still holds from before Survey, which nobody sees:
    /// Survey prints its panes (the selection) and hands off the focused
    /// one (the lead), as the grid does.
    func testCommandsOnTheShownImageNeverTakeTheEditorsHiddenOne() {
        XCTAssertFalse(AppMode.survey.showsEditorImage)
        XCTAssertFalse(AppMode.library.showsEditorImage)
        for mode in [AppMode.loupe, .compare, .develop] { XCTAssertTrue(mode.showsEditorImage) }
        let survey = state { $0.mode = .survey; $0.selectionCount = 3; $0.hasImage = true }
        XCTAssertFalse(survey.isEnabled(.exportOpenImage))
        XCTAssertTrue(survey.isEnabled(.print))
        XCTAssertTrue(survey.isEnabled(.editExternally))
        let noSelection = state { $0.mode = .survey; $0.hasSelection = false; $0.selectionCount = 0; $0.hasImage = true }
        XCTAssertFalse(noSelection.isEnabled(.print), "never the editor's image")
        XCTAssertFalse(noSelection.isEnabled(.editExternally))
        XCTAssertTrue(state { $0.mode = .loupe; $0.selectionCount = 1; $0.hasImage = true }.isEnabled(.exportOpenImage))
    }

    /// The mode picker offers Survey on the command's terms: chosen without
    /// two to four selected, nothing changes (and nothing reloads).
    func testThePickerChoosesSurveyOnlyWhenItCanBegin() {
        XCTAssertFalse(state { $0.mode = .develop; $0.selectionCount = 1 }.allowsChoosing(.survey))
        XCTAssertFalse(state { $0.mode = .compare; $0.selectionCount = 5 }.allowsChoosing(.survey))
        XCTAssertTrue(state { $0.selectionCount = 3 }.allowsChoosing(.survey))
        XCTAssertTrue(state { $0.selectionCount = 1 }.allowsChoosing(.develop))
        XCTAssertTrue(CommandState().allowsChoosing(.library))
    }

    func testKeys() throws {
        XCTAssertEqual(KeyCommand.command(for: BareKeyPress(.character("n"))), .survey)
        XCTAssertEqual(KeyCommand.command(for: BareKeyPress(.character("/"))), .removeFromSurvey)
        XCTAssertEqual(try XCTUnwrap(Shortcuts.shortcut(for: .removeFromSurvey)).scope, .survey)
        XCTAssertEqual(Shortcuts.menuTitle("Survey", for: .survey), "Survey (N)")
        XCTAssertEqual(Shortcuts.menuTitle("Remove from Survey", for: .removeFromSurvey), "Remove from Survey (/)")
        XCTAssertFalse(CommandState.passesThroughWhenUnavailable(.removeFromSurvey))
    }

    // MARK: - Panes

    /// Three panes of different sizes: a zoom in one shows the same part of
    /// the picture in the others, until Sync is turned off.
    func testPanesZoomAndPanTogetherWhileSyncIsOn() async throws {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let survey = SurveyModel(policy: MemoryPolicy(physicalMemory: 32 << 30))
        let panes = try XCTUnwrap(SurveyPanes(selected: [1, 2, 3], primary: 2, order: [1, 2, 3]))
        var opened: [Int64] = []
        survey.show(panes) { id, model in
            opened.append(id)
            model.open(url: url, userRotation: id == 3 ? 1 : 0)
        }
        XCTAssertEqual(opened, [2, 1, 3], "the focused pane opens first")
        let a = try XCTUnwrap(survey.model(for: 1)), b = try XCTUnwrap(survey.model(for: 2)),
            c = try XCTUnwrap(survey.model(for: 3))
        XCTAssertFalse(a.measuresScopes, "a pane shows no histogram")
        a.viewportDidResize(to: CGSize(width: 800, height: 600))
        b.viewportDidResize(to: CGSize(width: 640, height: 900))
        c.viewportDidResize(to: CGSize(width: 1000, height: 400))

        survey.focusedModel?.zoomIn()
        XCTAssertFalse(b.fitMode)
        for pane in [a, c] {
            XCTAssertFalse(pane.fitMode)
            XCTAssertEqual(pane.relativeView.zoomFactor, b.relativeView.zoomFactor, accuracy: 1e-6)
            XCTAssertEqual(pane.relativeView.center.x, b.relativeView.center.x, accuracy: 1e-3)
        }
        await Task.yield()   // the turn in which the others took the view ends

        survey.syncsView = false
        a.pan(by: CGSize(width: 300, height: 0))
        XCTAssertNotEqual(a.relativeView.center.x, b.relativeView.center.x, accuracy: 1e-3)
        survey.syncsView = true   // lines the others up with the focused pane
        XCTAssertEqual(a.relativeView.center.x, b.relativeView.center.x, accuracy: 1e-3)
        survey.closeAll()
    }

    /// A removed pane closes its image. Leaving Survey on a small Mac
    /// closes every pane's; with more memory they stay, off screen, and
    /// come back for the same images without opening them again.
    func testMemoryWhenPanesGoAndSurveyIsLeft() async throws {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let panes = try XCTUnwrap(SurveyPanes(selected: [1, 2, 3], primary: 1, order: [1, 2, 3]))

        let roomy = SurveyModel(policy: MemoryPolicy(physicalMemory: 32 << 30))
        roomy.show(panes) { _, model in model.open(url: url) }
        let removed = try XCTUnwrap(roomy.model(for: 3))
        XCTAssertTrue(roomy.remove(3))
        XCTAssertFalse(removed.hasImage)
        XCTAssertNil(roomy.model(for: 3))
        let kept = try XCTUnwrap(roomy.model(for: 1))
        roomy.end()
        XCTAssertTrue(kept.hasImage)
        XCTAssertTrue(kept.isOffScreen, "memory pressure closes it")
        XCTAssertNil(kept.linkedGroup)
        var reopened: [Int64] = []
        roomy.show(try XCTUnwrap(SurveyPanes(selected: [1, 2], primary: 1, order: [1, 2]))) { id, model in
            XCTAssertTrue(model.hasImage)
            reopened.append(id)
        }
        XCTAssertTrue(roomy.model(for: 1) === kept)
        XCTAssertFalse(kept.isOffScreen)
        XCTAssertTrue(kept.linkedGroup === roomy)
        XCTAssertEqual(reopened, [1, 2], "asked to refresh, not given a new model")
        roomy.closeAll()
        XCTAssertFalse(kept.hasImage)
        XCTAssertNil(roomy.panes)

        let small = SurveyModel(policy: MemoryPolicy(physicalMemory: 8 << 30))
        small.show(panes) { _, model in model.open(url: url) }
        let pane = try XCTUnwrap(small.model(for: 2))
        pane.viewportDidResize(to: CGSize(width: 800, height: 600))
        pane.zoomToActualSize()   // renders a full-resolution tile
        XCTAssertNotNil(pane.tile)
        let session = try XCTUnwrap(pane.session)
        let rendered = session.approximateBytesHeld
        await Task.yield()
        await Task.yield()
        XCTAssertNil(pane.analysisTexture, "a small Mac keeps only what's on screen")
        XCTAssertLessThan(session.approximateBytesHeld, rendered, "the pooled textures went")
        XCTAssertNotNil(pane.tile, "the picture stays")
        small.end()
        XCTAssertFalse(pane.hasImage)
        XCTAssertNil(small.panes)
    }

    /// Panes whose edits have AI denoise on run it one at a time, the
    /// focused pane first, and only while Survey shows: a run under way
    /// when Survey is left stops, and starts again on the way back.
    func testPanesTakeTurnsAtAIDenoiseWhileShown() async throws {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let survey = SurveyModel(policy: MemoryPolicy(physicalMemory: 32 << 30))
        let panes = try XCTUnwrap(SurveyPanes(selected: [1, 2, 3], primary: 2, order: [1, 2, 3]))
        survey.show(panes) { _, model in model.open(url: url) }
        let a = try XCTUnwrap(survey.model(for: 1)), b = try XCTUnwrap(survey.model(for: 2)),
            c = try XCTUnwrap(survey.model(for: 3))
        var started: [EditorModel] = []
        survey.startsAIDenoise = { model in
            started.append(model)
            model.aiDenoiseRunning = true
        }
        var denoised = a.parameters
        denoised.aiDenoise = 1
        let stack = try EditStack(parameters: denoised).encodeJSON()

        a.showStoredEdit(stack, userRotation: 0)
        c.showStoredEdit(stack, userRotation: 0)
        b.showStoredEdit(stack, userRotation: 0)
        XCTAssertEqual(started.map(ObjectIdentifier.init), [ObjectIdentifier(a)], "one at a time")
        XCTAssertFalse(c.aiDenoiseRunning)

        a.aiDenoiseRunning = false
        await settle { started.count == 2 }
        XCTAssertEqual(started.map(ObjectIdentifier.init), [a, b].map(ObjectIdentifier.init), "the focused pane next")
        b.aiDenoiseRunning = false
        await settle { started.count == 3 }
        XCTAssertTrue(started.last === c)

        survey.end()
        XCTAssertFalse(c.aiDenoiseRunning, "nobody sees it")
        await settle(for: 0.2) { false }
        XCTAssertEqual(started.count, 3)
        survey.show(panes) { _, _ in }
        XCTAssertEqual(started.count, 4)
        XCTAssertTrue(started.last === c, "it starts again")
        survey.closeAll()
    }

    /// An undo or redo in the Library that put back a surveyed image's
    /// rotation or stored edit shows on its pane, while Survey shows.
    func testPanesShowWhatAnUndoPutBack() async throws {
        let sample = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sample.path))
        _ = try await GPUContext.shared()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("latent-survey-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for name in ["A.NEF", "B.NEF"] { try fm.copyItem(at: sample, to: folder.appendingPathComponent(name)) }
        let library = Library()
        _ = try await library.open(folder: folder)
        let a = try XCTUnwrap(library.images.first { $0.fileName == "A.NEF" }?.id)
        let b = try XCTUnwrap(library.images.first { $0.fileName == "B.NEF" }?.id)
        library.setSelection([a, b], primary: a)
        let survey = SurveyModel(policy: MemoryPolicy(physicalMemory: 32 << 30))
        XCTAssertTrue(survey.begin(library: library, onFailure: { XCTFail("\($0): \($1)") }))
        let paneA = try XCTUnwrap(survey.model(for: a)), paneB = try XCTUnwrap(survey.model(for: b))
        await settle(for: 30) { paneA.hasImage && paneB.hasImage }
        XCTAssertTrue(paneA.hasImage && paneB.hasImage)

        try await library.rotateSelected(by: 1, onlyPrimary: true)
        survey.followRestore([a, b], .rotation, library: library, onFailure: { XCTFail("\($0): \($1)") })
        XCTAssertEqual(paneA.userRotation, 1)
        XCTAssertEqual(paneB.userRotation, 0)

        var edited = paneB.parameters
        edited.exposureEV = 1.5
        try await library.saveEditStack(try EditStack(parameters: edited).encodeJSON(), schemaVersion: EditStack.schemaVersion,
                                        processVersion: EditStack.processVersion, forImageID: b)
        survey.followRestore([b], .edits, library: library, onFailure: { XCTFail("\($0): \($1)") })
        await settle { paneB.parameters.exposureEV == 1.5 }
        XCTAssertEqual(paneB.parameters.exposureEV, 1.5)
        XCTAssertNil(paneB.pendingSave, "a pane never saves")

        survey.end()
        try await library.rotateSelected(by: 1, onlyPrimary: true)
        survey.followRestore([a], .rotation, library: library, onFailure: { XCTFail("\($0): \($1)") })
        XCTAssertEqual(paneA.userRotation, 1, "a pane off screen isn't rendered for it")
        try await library.saveEditStack(nil, schemaVersion: EditStack.schemaVersion,
                                        processVersion: EditStack.processVersion, forImageID: b)
        survey.followRestore([b], .edits, library: library, onFailure: { XCTFail("\($0): \($1)") })
        await settle(for: 0.2) { false }
        XCTAssertEqual(paneB.parameters.exposureEV, 1.5, "Survey reads it again on the way back in")
        survey.closeAll()
    }

    private func settle(for seconds: Double = 2, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A pane that kept its image while Survey was away shows the stored
    /// edit and rotation as they are now.
    func testAKeptPaneShowsTheStoredEditAsItIsNow() async throws {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url)
        var edited = model.parameters
        edited.exposureEV = 1.5
        model.showStoredEdit(try EditStack(parameters: edited).encodeJSON(), userRotation: 3)
        XCTAssertEqual(model.parameters.exposureEV, 1.5)
        XCTAssertEqual(model.userRotation, 3)
        XCTAssertNil(model.pendingSave, "a pane never saves")
        model.showStoredEdit(nil, userRotation: 0)
        XCTAssertEqual(model.parameters, model.defaultParameters)
    }
}
