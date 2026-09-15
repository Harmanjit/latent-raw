import XCTest
@testable import latent_app

final class ToolSizeTests: XCTestCase {
    func testStepsScaleAndUndoEachOther() {
        let range = ToolSizeStep.brushRadius
        let bigger = ToolSizeStep.stepped(0.04, by: 1, within: range)
        XCTAssertEqual(bigger, 0.05, accuracy: 1e-6)
        XCTAssertEqual(ToolSizeStep.stepped(bigger, by: -1, within: range), 0.04, accuracy: 1e-6)
        XCTAssertLessThan(ToolSizeStep.stepped(0.04, by: -1, within: range), 0.04)
    }

    func testStepsStopAtTheSliderEnds() {
        XCTAssertEqual(ToolSizeStep.stepped(0.19, by: 3, within: ToolSizeStep.brushRadius), 0.2)
        XCTAssertEqual(ToolSizeStep.stepped(0.006, by: -3, within: ToolSizeStep.brushRadius), 0.005)
        XCTAssertEqual(ToolSizeStep.stepped(590, by: 1, within: ToolSizeStep.healRadiusPixels), 600)
        // No image yet: the size reads as zero and steps up to the smallest.
        XCTAssertEqual(ToolSizeStep.stepped(0, by: 1, within: ToolSizeStep.healRadiusPixels), 4)
    }
}

final class LocalSliderResetTests: XCTestCase {
    /// Double-click reset used to put 0 into every Local Adjustments row,
    /// below the ranges of brush Size and Flow, luminance Feather and
    /// colour Width.
    func testResetStaysInsideTheSliderRange() {
        XCTAssertEqual(LocalAdjustmentsPanel.resetValue(0, in: 5...90), 5)
        XCTAssertEqual(LocalAdjustmentsPanel.resetValue(0, in: ToolSizeStep.brushRadius), 0.005)
        XCTAssertEqual(LocalAdjustmentsPanel.resetValue(0.04, in: ToolSizeStep.brushRadius), 0.04)
        XCTAssertEqual(LocalAdjustmentsPanel.resetValue(2, in: 0...1), 1)
    }
}
