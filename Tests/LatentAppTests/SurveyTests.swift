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
