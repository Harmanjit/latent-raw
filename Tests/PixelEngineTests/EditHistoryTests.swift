import XCTest
@testable import PixelEngine

final class EditHistoryTests: XCTestCase {
    func stack(_ ev: Float) -> EditStack { var p = EditParameters(); p.exposureEV = ev; return EditStack(parameters: p) }

    func testRecordUndoRedoAndTruncation() {
        var h = EditHistory(initial: stack(0))
        XCTAssertFalse(h.canUndo); XCTAssertFalse(h.canRedo)
        XCTAssertFalse(h.record(stack(0)), "identical state is not a step")
        XCTAssertTrue(h.record(stack(1)))
        XCTAssertTrue(h.record(stack(2)))
        XCTAssertEqual(h.steps.count, 3)
        XCTAssertEqual(h.steps.last?.label, "Exposure")

        XCTAssertEqual(h.undo()?.parameters().exposureEV, 1)
        XCTAssertEqual(h.undo()?.parameters().exposureEV, 0)
        XCTAssertNil(h.undo())
        XCTAssertEqual(h.redo()?.parameters().exposureEV, 1)
        XCTAssertTrue(h.canRedo)

        // A new edit after undoing discards the redo branch.
        XCTAssertTrue(h.record(stack(5)))
        XCTAssertFalse(h.canRedo)
        XCTAssertEqual(h.steps.map { $0.stack.parameters().exposureEV }, [0, 1, 5])
        XCTAssertEqual(h.jump(to: 0)?.parameters().exposureEV, 0)
    }

    func testCapDropsOldest() {
        var h = EditHistory(initial: stack(0))
        for i in 1...40 { h.record(stack(Float(i))) }
        XCTAssertEqual(h.steps.count, EditHistory.maximumSteps)
        XCTAssertEqual(h.current.parameters().exposureEV, 40)
        XCTAssertEqual(h.steps.first?.stack.parameters().exposureEV, 11)
    }

    func testLabelsNameWhatChanged() {
        var a = EditParameters(), b = EditParameters()
        b.hsl.saturation[0] = 0.3; b.contrast = 1.9
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: a), to: EditStack(parameters: b)), "Tone, HSL")
        a.locals = [LocalAdjustment(name: "x", shape: .whole)]
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: b), to: EditStack(parameters: a)).contains("Local"), true)
    }

    func testHistoryAndSnapshotsRoundTripJSON() throws {
        var h = EditHistory(initial: stack(0)); h.record(stack(1))
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(EditHistory.self, from: data)
        XCTAssertEqual(back, h)
        let snap = EditSnapshot(name: "Warm", stack: stack(0.3))
        let s2 = try JSONDecoder().decode(EditSnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(s2, snap)
    }
}
