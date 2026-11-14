import XCTest
@testable import PixelEngine

/// `EditHistory.changedGroups`, which Sync Last Change to Selection pastes by.
final class EditHistoryChangedGroupsTests: XCTestCase {
    func testNamesTheGroupsAStepChanged() {
        let a = EditParameters()
        var b = a
        b.exposureEV = 1
        XCTAssertEqual(EditHistory.changedGroups(from: EditStack(parameters: a), to: EditStack(parameters: b)), [.tone])
        b.hsl.saturation[0] = 0.3
        b.vibrance = 0.2
        XCTAssertEqual(EditHistory.changedGroups(from: EditStack(parameters: a), to: EditStack(parameters: b)),
                       [.tone, .colour])
        XCTAssertEqual(EditHistory.changedGroups(from: EditStack(parameters: b), to: EditStack(parameters: b)), [])
    }

    func testLastChangedGroupsFollowsTheCursor() {
        var p = EditParameters()
        var history = EditHistory(initial: EditStack(parameters: p))
        XCTAssertEqual(history.lastChangedGroups, [], "the first step changed nothing")
        p.exposureEV = 0.5
        history.record(EditStack(parameters: p))
        p.vibrance = 0.4
        history.record(EditStack(parameters: p))
        XCTAssertEqual(history.lastChangedGroups, [.colour])
        _ = history.undo()
        XCTAssertEqual(history.lastChangedGroups, [.tone], "the step into the current state, not the undone one")
    }

    func testPastingTheChangedGroupsBringsATargetInStep() {
        var lead = EditParameters(), before = EditParameters()
        before.contrast = 1.2
        lead.contrast = 1.2
        lead.exposureEV = -0.7
        var target = EditParameters()
        target.vibrance = 0.3
        let groups = EditHistory.changedGroups(from: EditStack(parameters: before), to: EditStack(parameters: lead))
        let synced = EditStack(parameters: target).merged(with: EditStack(parameters: lead), groups: groups).parameters()
        XCTAssertEqual(synced.exposureEV, -0.7)
        XCTAssertEqual(synced.vibrance, 0.3, "groups the step left alone keep the target's values")
    }
}
