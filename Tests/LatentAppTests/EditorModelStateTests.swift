import XCTest
import AppKit
import PixelEngine
import MLKit
@testable import latent_app

/// The editor's state across opening, closing and background work.
@MainActor
final class EditorModelStateTests: XCTestCase {
    private static func asset(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets").appendingPathComponent(name)
    }

    /// A file that won't open leaves the editor closed. Nothing of the
    /// photo open before may stay: with its catalog id, history or pending
    /// save still set, Undo or the history load that follows would write
    /// that photo's edit (or its deletion) onto the one that failed.
    func testAFailedOpenLeavesNothingOfThePreviousPhoto() async throws {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
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
        let url = Self.asset("golden_nikon_d750_cc0.nef")
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
