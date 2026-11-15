import Foundation
import PixelEngine

// MARK: - Comparing two snapshots

/// One side of a snapshot comparison: the live edit, a named snapshot, or
/// a step in the history. Snapshots are keyed by name (`EditSnapshot.id`)
/// and steps by their id, so a side survives the lists being reordered.
enum ComparisonSource: Hashable {
    case current
    case snapshot(String)
    case historyStep(UUID)
}

/// A choice in the comparison's pickers.
struct ComparisonChoice: Identifiable, Hashable {
    let source: ComparisonSource
    let title: String
    var id: ComparisonSource { source }
}

/// Two edits of the photo being developed, shown against each other in
/// the Before/After layouts (History & Snapshots › Compare…). The left (or
/// top) side draws in the Before pane, the right (or bottom) side in a
/// second view-only pane, or in the editor itself when it is "Current".
/// Neither side ever changes the edit: this is view state only.
///
/// Pure value type; DevelopViewState holds one while a comparison shows.
struct SnapshotComparison: Equatable {
    /// The file the sides belong to: another image ends the comparison.
    var url: URL
    var left: ComparisonSource
    var right: ComparisonSource

    /// The two sides exchange.
    mutating func swap() {
        (left, right) = (right, left)
    }

    /// The right side steps to the next (or previous, for a negative
    /// `delta`) entry in Current followed by the snapshots, wrapping at
    /// either end. From a history step it starts at Current.
    mutating func stepRight(by delta: Int, snapshotNames: [String]) {
        let cycle: [ComparisonSource] = [.current] + snapshotNames.map { .snapshot($0) }
        guard delta != 0 else { return }
        let start = cycle.firstIndex(of: right) ?? 0
        let count = cycle.count
        right = cycle[(((start + delta) % count) + count) % count]
    }

    /// What the pickers offer: Current, every snapshot, then the history
    /// newest first (as the History panel lists it).
    static func choices(snapshots: [EditSnapshot], history: EditHistory) -> [ComparisonChoice] {
        var list = [ComparisonChoice(source: .current, title: "Current")]
        list += snapshots.map { ComparisonChoice(source: .snapshot($0.id), title: $0.name) }
        for (index, step) in history.steps.enumerated().reversed() {
            list.append(ComparisonChoice(source: .historyStep(step.id), title: stepTitle(step, index: index)))
        }
        return list
    }

    /// The stack a side shows, or nil when it is Current (the live edit)
    /// or names a snapshot or step that no longer exists.
    static func stack(for source: ComparisonSource, snapshots: [EditSnapshot],
                      history: EditHistory) -> EditStack? {
        switch source {
        case .current: return nil
        case .snapshot(let name): return snapshots.first { $0.id == name }?.stack
        case .historyStep(let id): return history.steps.first { $0.id == id }?.stack
        }
    }

    /// A side's pane label. A side whose snapshot or step has gone shows
    /// the live edit, and says so.
    static func label(for source: ComparisonSource, snapshots: [EditSnapshot], history: EditHistory) -> String {
        switch source {
        case .current:
            return "Current"
        case .snapshot(let name):
            return snapshots.contains { $0.id == name } ? name : "Current"
        case .historyStep(let id):
            guard let index = history.steps.firstIndex(where: { $0.id == id }) else { return "Current" }
            return stepTitle(history.steps[index], index: index)
        }
    }

    /// "Step 3: Exposure", numbered from 1 as the list reads oldest first.
    private static func stepTitle(_ step: EditHistory.Step, index: Int) -> String {
        "Step \(index + 1): \(step.label)"
    }
}

extension EditorModel {
    /// The parameters a comparison side draws with: the snapshot's or
    /// step's stack over this image's defaults (an As Shot white balance
    /// as the defaults give it, as `beforeParameters` does), or the live
    /// edit for Current and for a side whose source has gone.
    func comparisonParameters(_ source: ComparisonSource) -> EditParameters {
        guard let stack = SnapshotComparison.stack(for: source, snapshots: snapshots, history: history) else {
            return parameters
        }
        var next = stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        return next
    }

    /// A side's pane label (SnapshotComparison.label).
    func comparisonLabel(_ source: ComparisonSource) -> String {
        SnapshotComparison.label(for: source, snapshots: snapshots, history: history)
    }

    /// The pickers' choices for the open image.
    var comparisonChoices: [ComparisonChoice] {
        SnapshotComparison.choices(snapshots: snapshots, history: history)
    }
}
