import XCTest
import CoreGraphics
@testable import Catalog

final class SurveyPanesTests: XCTestCase {
    func testTwoToFourSelectedImagesInGridOrder() throws {
        XCTAssertNil(SurveyPanes(selected: [1], primary: 1, order: [1, 2]))
        XCTAssertNil(SurveyPanes(selected: [1, 2, 3, 4, 5], primary: 1, order: [1, 2, 3, 4, 5]))
        let panes = try XCTUnwrap(SurveyPanes(selected: [7, 3, 5], primary: 5, order: [9, 7, 5, 3]))
        XCTAssertEqual(panes.ids, [7, 5, 3])
        XCTAssertEqual(panes.focusedID, 5, "the primary selection has the keyboard")
        XCTAssertEqual(panes.focusedIndex, 1)
        XCTAssertTrue(SurveyPanes.canSurvey(selectionCount: 4))
        XCTAssertFalse(SurveyPanes.canSurvey(selectionCount: 1))
    }

    /// Selected images a filter hides come after the ones it shows, and a
    /// primary that isn't selected leaves the focus on the first pane.
    func testHiddenSelectionAndMissingPrimary() throws {
        let panes = try XCTUnwrap(SurveyPanes(selected: [8, 2, 6], primary: 4, order: [6, 5, 4]))
        XCTAssertEqual(panes.ids, [6, 2, 8])
        XCTAssertEqual(panes.focusedID, 6)
    }

    func testArrowsMoveTheFocusAndStopAtTheEnds() throws {
        var panes = try XCTUnwrap(SurveyPanes(selected: [1, 2, 3], primary: 1, order: [1, 2, 3]))
        XCTAssertFalse(panes.moveFocus(by: -1))
        XCTAssertTrue(panes.moveFocus(by: 1))
        XCTAssertEqual(panes.focusedID, 2)
        XCTAssertTrue(panes.moveFocus(by: 5))
        XCTAssertEqual(panes.focusedID, 3)
        XCTAssertFalse(panes.moveFocus(by: 1))
        XCTAssertTrue(panes.focus(1))
        XCTAssertFalse(panes.focus(42), "no pane shows it")
        XCTAssertEqual(panes.focusedID, 1)
    }

    /// The focus moves to the pane that takes the removed one's place, or
    /// the one before when the last pane goes; other panes keep it.
    func testRemovingMovesTheFocusToANeighbour() throws {
        var panes = try XCTUnwrap(SurveyPanes(selected: [1, 2, 3, 4], primary: 2, order: [1, 2, 3, 4]))
        XCTAssertTrue(panes.remove(2))
        XCTAssertEqual(panes.ids, [1, 3, 4])
        XCTAssertEqual(panes.focusedID, 3)
        XCTAssertTrue(panes.isComplete)
        panes.focus(4)
        panes.remove(4)
        XCTAssertEqual(panes.focusedID, 3)
        panes.remove(1)
        XCTAssertEqual(panes.focusedID, 3)
        XCTAssertFalse(panes.isComplete, "one image left is a loupe")
        XCTAssertFalse(panes.remove(1))
    }

    func testFollowingTheSelection() throws {
        var panes = try XCTUnwrap(SurveyPanes(selected: [1, 2, 3], primary: 2, order: [1, 2, 3]))
        // A rating under a filter hides and deselects the focused image;
        // the library keeps it as the lead.
        XCTAssertEqual(panes.follow(selected: [1, 3], primary: 2), [2])
        XCTAssertEqual(panes.ids, [1, 3])
        XCTAssertEqual(panes.focusedID, 3)
        // The primary moves to another shown pane: the focus follows. A
        // newly selected image doesn't join.
        XCTAssertEqual(panes.follow(selected: [1, 3, 9], primary: 1), [])
        XCTAssertEqual(panes.ids, [1, 3])
        XCTAssertEqual(panes.focusedID, 1)
        XCTAssertEqual(panes.follow(selected: [], primary: nil), [1, 3])
        XCTAssertTrue(panes.ids.isEmpty)
    }

    /// Landscape images: two side by side, four in a 2 × 2 grid, three in
    /// a row only in a window wide enough. Portrait images prefer a row.
    func testArrangementShowsEachImageLargest() {
        let window = CGSize(width: 1100, height: 780)
        XCTAssertTrue(SurveyPanes.grid(count: 2, in: window, captionHeight: 26) == (2, 1))
        XCTAssertTrue(SurveyPanes.grid(count: 4, in: window, captionHeight: 26) == (2, 2))
        XCTAssertTrue(SurveyPanes.grid(count: 3, in: window, captionHeight: 26) == (2, 2))
        XCTAssertTrue(SurveyPanes.grid(count: 3, in: CGSize(width: 2400, height: 700), captionHeight: 26) == (3, 1))
        XCTAssertTrue(SurveyPanes.grid(count: 4, in: window, imageAspect: 2.0 / 3.0, captionHeight: 26) == (4, 1))
        XCTAssertTrue(SurveyPanes.grid(count: 2, in: CGSize(width: 500, height: 900)) == (1, 2))
        XCTAssertTrue(SurveyPanes.grid(count: 3, in: .zero) == (3, 1), "nothing laid out yet")
    }

    func testFramesTileTheAreaInPaneOrder() {
        let frames = SurveyPanes.frames(count: 4, columns: 2, rows: 2, in: CGSize(width: 201, height: 101), spacing: 1)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 101, y: 0, width: 100, height: 50),
                                CGRect(x: 0, y: 51, width: 100, height: 50), CGRect(x: 101, y: 51, width: 100, height: 50)])
        XCTAssertTrue(SurveyPanes.frames(count: 0, columns: 1, rows: 1, in: CGSize(width: 10, height: 10), spacing: 0).isEmpty)
    }
}
