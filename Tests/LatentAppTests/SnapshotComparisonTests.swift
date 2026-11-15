import XCTest
import PixelEngine
import Catalog
@testable import latent_app

/// History & Snapshots › Compare…: two snapshots (or a snapshot and a
/// history step, or Current) against each other.
@MainActor
final class SnapshotComparisonTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SnapshotComparisonTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let url = URL(fileURLWithPath: "/tmp/photo.nef")

    private func stack(ev: Double) -> EditStack {
        var p = EditParameters()
        p.exposureEV = Float(ev)
        return EditStack(parameters: p)
    }

    // MARK: Pure state

    func testSwapExchangesTheSides() {
        var c = SnapshotComparison(url: url, left: .snapshot("A"), right: .current)
        c.swap()
        XCTAssertEqual(c.left, .current)
        XCTAssertEqual(c.right, .snapshot("A"))
    }

    func testRightSideStepsThroughCurrentAndSnapshotsAndWraps() {
        var c = SnapshotComparison(url: url, left: .snapshot("A"), right: .current)
        let names = ["A", "B"]
        c.stepRight(by: 1, snapshotNames: names)
        XCTAssertEqual(c.right, .snapshot("A"))
        c.stepRight(by: 1, snapshotNames: names)
        XCTAssertEqual(c.right, .snapshot("B"))
        c.stepRight(by: 1, snapshotNames: names)
        XCTAssertEqual(c.right, .current, "wraps back to Current")
        c.stepRight(by: -1, snapshotNames: names)
        XCTAssertEqual(c.right, .snapshot("B"), "wraps backwards too")
        XCTAssertEqual(c.left, .snapshot("A"), "the left side never moves")
        // From a history step it starts at Current.
        c.right = .historyStep(UUID())
        c.stepRight(by: 1, snapshotNames: names)
        XCTAssertEqual(c.right, .snapshot("A"))
        // No snapshots: it stays on Current.
        c.right = .current
        c.stepRight(by: 1, snapshotNames: [])
        XCTAssertEqual(c.right, .current)
    }

    func testChoicesListCurrentSnapshotsThenHistoryNewestFirst() {
        var history = EditHistory(initial: stack(ev: 0))
        history.record(stack(ev: 1))
        let snapshots = [EditSnapshot(name: "Warm", stack: stack(ev: 0.5))]
        let choices = SnapshotComparison.choices(snapshots: snapshots, history: history)
        XCTAssertEqual(choices.map(\.title), ["Current", "Warm", "Step 2: Exposure", "Step 1: Original"])
        XCTAssertEqual(choices[2].source, .historyStep(history.steps[1].id))
    }

    func testStacksAndLabelsResolveAndFallBackToCurrent() {
        let history = EditHistory(initial: stack(ev: 0))
        let snapshots = [EditSnapshot(name: "Warm", stack: stack(ev: 0.5))]
        XCTAssertNil(SnapshotComparison.stack(for: .current, snapshots: snapshots, history: history))
        XCTAssertEqual(SnapshotComparison.stack(for: .snapshot("Warm"), snapshots: snapshots, history: history),
                       snapshots[0].stack)
        XCTAssertEqual(SnapshotComparison.stack(for: .historyStep(history.steps[0].id), snapshots: snapshots,
                                                history: history), history.steps[0].stack)
        XCTAssertEqual(SnapshotComparison.label(for: .snapshot("Warm"), snapshots: snapshots, history: history), "Warm")
        // A deleted snapshot shows the live edit and says so.
        XCTAssertNil(SnapshotComparison.stack(for: .snapshot("Gone"), snapshots: snapshots, history: history))
        XCTAssertEqual(SnapshotComparison.label(for: .snapshot("Gone"), snapshots: snapshots, history: history), "Current")
        XCTAssertEqual(SnapshotComparison.label(for: .historyStep(UUID()), snapshots: snapshots, history: history),
                       "Current")
    }

    func testComparisonCommandsAreEnabledOnlyWhileComparing() {
        var state = CommandState()
        state.mode = .develop
        state.hasImage = true
        XCTAssertFalse(state.isEnabled(.view(.stepComparison(1))))
        XCTAssertFalse(state.isEnabled(.view(.endComparison)))
        state.views.comparing = true
        XCTAssertTrue(state.isEnabled(.view(.stepComparison(-1))))
        XCTAssertTrue(state.isEnabled(.view(.swapComparison)))
        state.mode = .library
        XCTAssertFalse(state.isEnabled(.view(.swapComparison)))
    }

    func testKeysStepTheRightPane() {
        XCTAssertEqual(Shortcuts.shortcut(for: .view(.stepComparison(1)))?.glyphs, "⌃⌥→")
        XCTAssertEqual(Shortcuts.shortcut(for: .view(.stepComparison(-1)))?.glyphs, "⌃⌥←")
        XCTAssertEqual(Shortcuts.shortcut(for: .view(.stepComparison(1)))?.scope, .develop)
    }

    func testWithoutAnImageNothingStarts() {
        let state = DevelopViewState(defaults: defaults)
        state.startComparison(left: .snapshot("A"), right: .current)
        XCTAssertNil(state.comparison)
        XCTAssertEqual(state.kind, .single)
    }

    // MARK: On a real image

    private func openModel() async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: try TestAssets.d750URL(), catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testComparingNeverChangesTheEditAndExitsToOneImage() async throws {
        let model = try await openModel()
        let state = DevelopViewState(defaults: defaults)
        state.attach(main: model, library: Library())
        state.show()
        defer { state.hide() }

        model.parameters.exposureEV = 1
        model.saveSnapshot(named: "Bright")
        model.parameters.exposureEV = -1
        model.saveSnapshot(named: "Dark")
        model.parameters.exposureEV = 0.25
        let edit = model.parameters
        let historyBefore = model.history

        state.startComparison(left: .snapshot("Bright"), right: .snapshot("Dark"))
        XCTAssertEqual(state.kind, .beforeAfter)
        XCTAssertEqual(state.comparison?.left, .snapshot("Bright"))
        XCTAssertEqual(state.composedBefore()?.exposureEV, 1, "the left side draws in the Before pane")
        XCTAssertEqual(state.composedRight()?.exposureEV, -1)
        XCTAssertEqual(state.commandState(main: model).comparing, true)

        state.perform(.swapComparison, load: { _ in })
        XCTAssertEqual(state.composedBefore()?.exposureEV, -1)
        XCTAssertEqual(state.composedRight()?.exposureEV, 1)

        // Stepping the right pane reaches Current, which the editor shows.
        state.perform(.stepComparison(-1), load: { _ in })
        XCTAssertEqual(state.comparison?.right, .current)
        XCTAssertNil(state.composedRight())

        // The sides keep the edit's crop so the panes line up.
        var crop = model.parameters.crop
        crop.size = SIMD2<Float>(0.5, 0.5)
        model.parameters.crop = crop
        state.setComparison(right: .snapshot("Bright"))
        XCTAssertEqual(state.composedRight()?.crop, crop)
        XCTAssertEqual(state.composedBefore()?.crop, crop)

        // Changing the layout keeps the comparison.
        state.perform(.beforeAfter(.topBottomSplit), load: { _ in })
        XCTAssertNotNil(state.comparison)

        var expected = edit
        expected.crop = crop
        XCTAssertEqual(model.parameters, expected, "comparing never changes the edit")
        XCTAssertEqual(model.history.steps.count, historyBefore.steps.count, "nor adds history")

        state.perform(.endComparison, load: { _ in })
        XCTAssertNil(state.comparison)
        XCTAssertEqual(state.kind, .single)
        XCTAssertEqual(model.parameters, expected)
    }

    func testOneImageAndCompareAsBeforeEndTheComparison() async throws {
        let model = try await openModel()
        let state = DevelopViewState(defaults: defaults)
        state.attach(main: model, library: Library())
        model.parameters.exposureEV = 1
        model.saveSnapshot(named: "Bright")

        state.startComparison(left: .snapshot("Bright"), right: .current)
        state.perform(.beforeAfter(nil), load: { _ in })
        XCTAssertNil(state.comparison)

        state.startComparison(left: .snapshot("Bright"), right: .current)
        state.compareSnapshot(EditSnapshot(name: "Bright", stack: model.snapshots[0].stack))
        XCTAssertNil(state.comparison)
        XCTAssertEqual(model.beforeSnapshotName, "Bright")
        XCTAssertEqual(state.kind, .beforeAfter)
    }

    func testAHistoryStepCanBeASide() async throws {
        let model = try await openModel()
        let state = DevelopViewState(defaults: defaults)
        state.attach(main: model, library: Library())
        let first = model.history.steps[0]
        model.parameters.exposureEV = 2
        state.startComparison(left: .historyStep(first.id), right: .current)
        let expected = model.comparisonParameters(.historyStep(first.id))
        XCTAssertEqual(state.composedBefore()?.exposureEV, expected.exposureEV)
        XCTAssertEqual(model.comparisonLabel(.historyStep(first.id)), "Step 1: \(first.label)")
        XCTAssertEqual(model.parameters.exposureEV, 2)
    }
}
