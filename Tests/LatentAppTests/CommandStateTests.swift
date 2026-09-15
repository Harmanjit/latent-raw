import XCTest
import Catalog
@testable import latent_app

final class CommandStateTests: XCTestCase {
    private func develop(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .develop
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 1
        state.hasImage = true
        state.editorReady = true
        change(&state)
        return state
    }

    func testNothingOpen() {
        let state = CommandState()
        XCTAssertTrue(state.isEnabled(.openFolder))
        XCTAssertTrue(state.isEnabled(.library))
        XCTAssertFalse(state.isEnabled(.develop))
        XCTAssertFalse(state.isEnabled(.loupe))
        XCTAssertFalse(state.isEnabled(.rate(3)))
        XCTAssertFalse(state.isEnabled(.export))
        XCTAssertFalse(state.isEnabled(.exportOpenImage))
        XCTAssertFalse(state.isEnabled(.openFile), "The GPU isn't ready")
        XCTAssertFalse(state.isEnabled(.step(1)))
        XCTAssertFalse(state.isEnabled(.undo))
    }

    func testToolsOnlyInDevelop() {
        XCTAssertTrue(develop().isEnabled(.crop))
        XCTAssertTrue(develop().isEnabled(.heal))
        XCTAssertTrue(develop().isEnabled(.autoAdjust))
        let loupe = develop { $0.mode = .loupe }
        XCTAssertFalse(loupe.isEnabled(.crop))
        XCTAssertFalse(loupe.isEnabled(.heal))
        XCTAssertFalse(loupe.isEnabled(.addMask(.brush)))
        XCTAssertTrue(loupe.isEnabled(.zoomIn))
        // In the grid ⌘= and ⌘- size the thumbnails instead.
        XCTAssertTrue(develop { $0.mode = .library }.isEnabled(.zoomIn))
        XCTAssertFalse(develop { $0.mode = .library }.isEnabled(.zoomToActualSize))
        XCTAssertFalse(develop { $0.mode = .library }.isEnabled(.beforeAfter))
    }

    func testToolSizeNeedsAnArmedBrushOrSpotTool() {
        XCTAssertFalse(develop().isEnabled(.toolSize(1)))
        XCTAssertTrue(develop { $0.toolSizeAdjustable = true }.isEnabled(.toolSize(-1)))
        XCTAssertFalse(develop { $0.toolSizeAdjustable = true; $0.mode = .loupe }.isEnabled(.toolSize(1)))
    }

    func testDeleteSpotNeedsASelectedPatch() {
        XCTAssertFalse(develop { $0.healToolActive = true }.isEnabled(.deleteHeal))
        XCTAssertTrue(develop { $0.healToolActive = true; $0.hasSelectedHeal = true }.isEnabled(.deleteHeal))
    }

    func testCompareCommands() {
        let compare = develop { $0.mode = .compare }
        XCTAssertTrue(compare.isEnabled(.makeSelect))
        XCTAssertFalse(compare.isEnabled(.swapCompare))
        XCTAssertTrue(develop { $0.mode = .compare; $0.hasCompareSelect = true }.isEnabled(.swapCompare))
        XCTAssertFalse(develop().isEnabled(.makeSelect))
    }

    func testToggleLoupeFromGridOrLoupe() {
        XCTAssertTrue(develop { $0.mode = .library }.isEnabled(.toggleLoupe))
        XCTAssertTrue(develop { $0.mode = .loupe }.isEnabled(.toggleLoupe))
        XCTAssertFalse(develop().isEnabled(.toggleLoupe))
        XCTAssertFalse(develop { $0.mode = .library; $0.hasSelection = false }.isEnabled(.toggleLoupe))
    }

    func testExportWaitsForTheRunningBatch() {
        XCTAssertTrue(develop().isEnabled(.export))
        XCTAssertFalse(develop { $0.exportQueueRunning = true }.isEnabled(.export))
        XCTAssertFalse(develop { $0.exportingOpenImage = true }.isEnabled(.exportOpenImage))
    }

    func testUndoTitlesNameTheChange() {
        let state = develop { $0.undoLabel = "Exposure"; $0.redoLabel = "Tone, Curve" }
        XCTAssertTrue(state.isEnabled(.undo))
        XCTAssertTrue(state.isEnabled(.redo))
        XCTAssertEqual(state.undoTitle, "Undo Exposure")
        XCTAssertEqual(state.redoTitle, "Redo Tone, Curve")
        XCTAssertEqual(develop().undoTitle, "Undo")
        XCTAssertFalse(develop().isEnabled(.redo))
        // Edits are undone in Develop only.
        XCTAssertFalse(develop { $0.undoLabel = "Exposure"; $0.mode = .library }.isEnabled(.undo))
    }

    func testTypingMakesUndoPlain() {
        let state = develop { $0.undoLabel = "Exposure"; $0.isEditingText = true }
        XCTAssertEqual(state.undoTitle, "Undo")
        XCTAssertEqual(state.redoTitle, "Redo")
    }

    func testStateTitles() {
        XCTAssertEqual(develop().beforeAfterTitle, "Show Before")
        XCTAssertEqual(develop { $0.showingBefore = true }.beforeAfterTitle, "Show After")
        XCTAssertEqual(develop().exportTitle, "Export…")
        XCTAssertEqual(develop { $0.selectionCount = 3 }.exportTitle, "Export 3 Images…")
        XCTAssertEqual(CommandState.ratingTitle(0), "Clear Rating")
        XCTAssertEqual(CommandState.ratingTitle(1), "1 Star")
        XCTAssertEqual(CommandState.ratingTitle(4), "4 Stars")
    }

    func testPickAndRejectSayWhatTheyWillDo() {
        let unflagged = develop()
        XCTAssertEqual(unflagged.pickItem.title, "Pick")
        XCTAssertEqual(unflagged.pickItem.command, .pick)
        XCTAssertEqual(unflagged.rejectItem.command, .reject)
        let picked = develop { $0.primaryFlag = .picked }
        XCTAssertEqual(picked.pickItem.title, "Unpick")
        XCTAssertEqual(picked.pickItem.command, .unflag)
        XCTAssertEqual(picked.rejectItem.title, "Reject")
        let rejected = develop { $0.primaryFlag = .rejected }
        XCTAssertEqual(rejected.rejectItem.title, "Unreject")
        XCTAssertEqual(rejected.rejectItem.command, .unflag)
        XCTAssertEqual(Shortcuts.menuTitle(picked.pickItem.title, for: picked.pickItem.command), "Unpick (U)")
    }

    /// Delete, Shift-X and the brackets go on to the rest of the app when
    /// they have nothing to do; other single keys are swallowed.
    func testWhichKeysPassThrough() {
        XCTAssertTrue(CommandState.passesThroughWhenUnavailable(.deleteHeal))
        XCTAssertTrue(CommandState.passesThroughWhenUnavailable(.makeSelect))
        XCTAssertTrue(CommandState.passesThroughWhenUnavailable(.toolSize(1)))
        XCTAssertFalse(CommandState.passesThroughWhenUnavailable(.develop))
        XCTAssertFalse(CommandState.passesThroughWhenUnavailable(.rate(2)))
    }

    func testContextsCompareByStateOnly() {
        let a = CommandContext(state: develop()) { _ in }
        let b = CommandContext(state: develop()) { _ in }
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, CommandContext(state: develop { $0.showingBefore = true }) { _ in })
    }

    /// With no image open, Undo would restore the history left from the
    /// previous photo onto whatever id is set: a failed open, say.
    func testUndoNeedsAnOpenImage() {
        let edited = develop { $0.undoLabel = "Exposure"; $0.redoLabel = "Contrast" }
        XCTAssertTrue(edited.isEnabled(.undo))
        XCTAssertTrue(edited.isEnabled(.redo))
        let closed = develop { $0.undoLabel = "Exposure"; $0.redoLabel = "Contrast"; $0.hasImage = false }
        XCTAssertFalse(closed.isEnabled(.undo))
        XCTAssertFalse(closed.isEnabled(.redo))
    }
}
