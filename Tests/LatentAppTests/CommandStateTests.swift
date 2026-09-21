import XCTest
import Catalog
@testable import latent_app

@MainActor
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

    /// The dust and touch-up tools arm in Develop with an image, like the
    /// spot tool; Delete removes a selected ring of either.
    func testDustAndTouchUpToolsFollowTheSpotTool() {
        XCTAssertTrue(develop().isEnabled(.dust))
        XCTAssertTrue(develop().isEnabled(.touchUp))
        XCTAssertFalse(develop { $0.hasImage = false }.isEnabled(.dust))
        XCTAssertFalse(develop { $0.hasImage = false }.isEnabled(.touchUp))
        for mode in [AppMode.library, .loupe, .compare, .survey] {
            XCTAssertFalse(develop { $0.mode = mode }.isEnabled(.dust), "\(mode)")
            XCTAssertFalse(develop { $0.mode = mode }.isEnabled(.touchUp), "\(mode)")
        }
        XCTAssertFalse(develop { $0.dustToolActive = true }.isEnabled(.deleteHeal))
        XCTAssertTrue(develop { $0.dustToolActive = true; $0.hasSelectedDust = true }.isEnabled(.deleteHeal))
        XCTAssertFalse(develop { $0.hasSelectedDust = true }.isEnabled(.deleteHeal), "the tool must be armed")
        XCTAssertFalse(develop { $0.touchUpToolActive = true }.isEnabled(.deleteHeal))
        XCTAssertTrue(develop { $0.touchUpToolActive = true; $0.hasSelectedBlemish = true }.isEnabled(.deleteHeal))
        XCTAssertFalse(develop { $0.hasSelectedBlemish = true }.isEnabled(.deleteHeal), "the tool must be armed")
        XCTAssertFalse(develop { $0.mode = .loupe; $0.dustToolActive = true; $0.hasSelectedDust = true }
            .isEnabled(.deleteHeal))
        XCTAssertTrue(CommandState.passesThroughWhenUnavailable(.deleteHeal), "Delete still reaches the grid")
    }

    /// Remove Dust works on the open image in Develop and on the selection
    /// elsewhere; it is a GPU job, so it takes turns with exports and
    /// merges, and it reads the files, so it waits for a move or rename.
    func testRemoveDustNeedsAnImageOrASelectionAndAFreeGPU() {
        XCTAssertTrue(develop().isEnabled(.removeDust))
        XCTAssertFalse(develop { $0.hasImage = false }.isEnabled(.removeDust), "Develop works on the open image")
        XCTAssertFalse(develop { $0.hasImage = false; $0.selectionCount = 3 }.isEnabled(.removeDust),
                       "in Develop the grid's selection doesn't count")
        for mode in [AppMode.library, .loupe, .compare, .survey] {
            XCTAssertTrue(develop { $0.mode = mode; $0.hasImage = false }.isEnabled(.removeDust), "\(mode)")
            XCTAssertTrue(develop { $0.mode = mode; $0.selectionCount = 12 }.isEnabled(.removeDust), "\(mode)")
            XCTAssertFalse(develop { $0.mode = mode; $0.selectionCount = 0; $0.hasSelection = false }
                .isEnabled(.removeDust), "\(mode) needs a selection")
        }
        XCTAssertFalse(develop { $0.editorReady = false }.isEnabled(.removeDust), "no GPU to analyse with")
        XCTAssertFalse(develop { $0.exportQueueRunning = true }.isEnabled(.removeDust))
        XCTAssertFalse(develop { $0.photoMergeRunning = true }.isEnabled(.removeDust), "any holder of the GPU slot")
        XCTAssertFalse(develop { $0.fileOperationRunning = true }.isEnabled(.removeDust))
        XCTAssertFalse(develop { $0.isEditingText = true }.isEnabled(.removeDust))
        XCTAssertFalse(CommandState.passesThroughWhenUnavailable(.removeDust))
    }

    /// The model-made masks are added like the gradients and the brush.
    func testModelMasksAreAddedLikeTheOthers() {
        XCTAssertFalse(develop().isEnabled(.addMask(.subject)))
        XCTAssertTrue(develop { $0.canAddMask = true }.isEnabled(.addMask(.subject)))
        XCTAssertTrue(develop { $0.canAddMask = true }.isEnabled(.addMask(.prompt)))
        XCTAssertFalse(develop { $0.canAddMask = true; $0.mode = .loupe }.isEnabled(.addMask(.subject)))
        XCTAssertFalse(develop { $0.canAddMask = true; $0.mode = .library }.isEnabled(.addMask(.prompt)))
    }

    /// None of the new commands has a key: the shortcuts page stays as it is.
    func testTheNewCommandsHaveNoKeys() {
        for command in [KeyCommand.dust, .touchUp, .removeDust, .addMask(.subject), .addMask(.prompt)] {
            XCTAssertNil(Shortcuts.shortcut(for: command), "\(command)")
            XCTAssertEqual(Shortcuts.menuTitle("Item", for: command), "Item")
        }
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
    }

    /// Outside Develop, Undo and Redo take back library actions, whose
    /// labels ContentView puts in place of the editor's; Develop needs its
    /// image for its own history.
    func testLibraryUndoOutsideDevelop() {
        let grid = develop { $0.mode = .library; $0.hasImage = false; $0.undoLabel = "Paste Settings (12 Images)" }
        XCTAssertTrue(grid.isEnabled(.undo))
        XCTAssertFalse(grid.isEnabled(.redo))
        XCTAssertEqual(grid.undoTitle, "Undo Paste Settings (12 Images)")
        XCTAssertTrue(develop { $0.mode = .loupe; $0.redoLabel = "Rating" }.isEnabled(.redo))
        XCTAssertFalse(develop { $0.hasImage = false; $0.undoLabel = "Exposure" }.isEnabled(.undo))
        // An action filed without a name still reads as plain Undo.
        XCTAssertEqual(develop { $0.mode = .library; $0.undoLabel = "" }.undoTitle, "Undo")
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

    /// A merge opens its source photos at the paths it took when it
    /// started, so undoing a move while it runs pulls them out from under
    /// it. The guard must hold both ways round, as Move's already does.
    func testAFileChangingUndoWaitsForAMergeAsItWaitsForAnExport() {
        let library = { (change: (inout CommandState) -> Void) -> CommandState in
            var state = CommandState()
            state.mode = .library
            state.hasVisibleImages = true
            state.hasSelection = true
            state.selectionCount = 2
            state.editorReady = true
            state.undoLabel = "Move (5 Images)"
            state.redoLabel = "Move (5 Images)"
            state.undoChangesFiles = true
            state.redoChangesFiles = true
            change(&state)
            return state
        }
        XCTAssertTrue(library { _ in }.isEnabled(.undo))
        // An export already blocked it; a Photo Merge, a print and a
        // contact sheet are all OutputJobs, as Move and Rename read them.
        XCTAssertFalse(library { $0.exportQueueRunning = true }.isEnabled(.undo))
        XCTAssertFalse(library { $0.outputJobRunning = true }.isEnabled(.undo))
        XCTAssertFalse(library { $0.outputJobRunning = true }.isEnabled(.redo))
        // An undo that only changes the catalog is still allowed.
        XCTAssertTrue(library { $0.outputJobRunning = true; $0.undoChangesFiles = false }.isEnabled(.undo))
    }

    /// And the other way: a merge can't be started on files a move is half
    /// way through, as Rename and Move to Folder already refuse.
    func testAMergeWaitsForAMoveOrRename() {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 5
        state.editorReady = true
        XCTAssertTrue(state.isEnabled(.photoMergeHDR))
        state.fileOperationRunning = true
        for command in [KeyCommand.photoMergeHDR, .photoMergeHDRWithoutDialog, .photoMergePanorama,
                        .photoMergeHDRPanorama] {
            XCTAssertFalse(state.isEnabled(command), "\(command)")
        }
        XCTAssertFalse(state.isEnabled(.moveToFolder), "which is how Move already behaves")
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
