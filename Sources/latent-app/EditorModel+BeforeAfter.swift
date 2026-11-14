import Foundation
import PixelEngine

/// Develop's Before when it isn't the unedited image, as Lightroom's
/// Copy After's Settings to Before leaves it: the stack and the file it
/// belongs to, so another image never shows it.
struct BeforeOverride: Equatable {
    var url: URL
    var stack: EditStack
    /// The snapshot it came from (Compare as Before in the History panel),
    /// named in the Before pane's label; nil for Copy After to Before.
    var snapshotName: String? = nil
}

extension EditorModel {
    // MARK: - Before / after settings

    /// The Before as a stack: the override for this image, else the defaults.
    var beforeStack: EditStack {
        if let override = beforeOverride, override.url == sourceURL { return override.stack }
        return EditStack(parameters: defaultParameters)
    }

    /// The Before as parameters: what `\` shows, and the Before pane draws
    /// (with the After's crop, so the two line up; see DevelopViews.swift).
    var beforeParameters: EditParameters {
        guard let override = beforeOverride, override.url == sourceURL else { return defaultParameters }
        var next = override.stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        return next
    }

    /// Whether the Before is something other than the unedited image.
    var hasCustomBefore: Bool { beforeOverride != nil && beforeOverride?.url == sourceURL }

    /// The current edit becomes the Before (⌥⇧⌘←).
    func copyAfterToBefore() {
        guard hasImage, let url = sourceURL else { return }
        beforeOverride = BeforeOverride(url: url, stack: EditStack(parameters: parameters))
        status = "Copied the After's settings to the Before"
    }

    /// The Before becomes the edit (⌥⇧⌘→), one step in the history, so
    /// Undo takes it back.
    func copyBeforeToAfter() {
        guard hasImage else { return }
        restoreSnapshot(EditSnapshot(name: "Before", stack: beforeStack))
        status = "Copied the Before's settings to the After"
    }

    /// The two exchange (⌥⇧⌘↑): the edit becomes the Before and the Before
    /// the edit, which Undo takes back (the Before stays as it now is).
    func swapBeforeAndAfter() {
        guard hasImage, let url = sourceURL else { return }
        let after = EditStack(parameters: parameters)
        restoreSnapshot(EditSnapshot(name: "Before", stack: beforeStack))
        beforeOverride = BeforeOverride(url: url, stack: after)
        status = "Swapped the Before and After settings"
    }

    /// The Before goes back to the unedited image.
    func resetBefore() {
        beforeOverride = nil
    }

    // MARK: - A snapshot as the Before

    /// A snapshot becomes the Before, as darktable's snapshots are compared
    /// with the live edit: the edit itself is untouched, and nothing goes
    /// into the history. DevelopViewState shows it in a split.
    func compareSnapshotAsBefore(_ snapshot: EditSnapshot) {
        guard hasImage, let url = sourceURL else { return }
        beforeOverride = BeforeOverride(url: url, stack: snapshot.stack, snapshotName: snapshot.name)
        status = "Comparing with snapshot “\(snapshot.name)”"
    }

    /// The snapshot the Before shows now, if it is one.
    var beforeSnapshotName: String? {
        hasCustomBefore ? beforeOverride?.snapshotName : nil
    }

    /// The Before pane's label: "Before", or the snapshot it shows.
    var beforeLabel: String {
        beforeSnapshotName.map { "Before: \($0)" } ?? "Before"
    }
}
