import SwiftUI
import AppKit
import Combine
import Catalog

/// Undo and Redo outside Develop: the Library's actions (ratings, flags,
/// rotation, keywords, pasted settings and presets, rearrangements, moves
/// and renames) are filed on the Library's own undo manager, which the Edit
/// menu and ⌘Z undo through `ContentView.perform`. Text fields keep the
/// window's for their typing, so undoing typing stops at the field's own
/// actions. Develop keeps its own edit history (EditHistory).
///
/// This keeps the Edit menu's titles up to date as actions are filed,
/// undone and dropped.
@MainActor
final class LibraryUndoObserver: ObservableObject {
    /// "Rating (12 Images)"-style names of what Undo and Redo would do,
    /// nil when there is nothing to.
    struct Labels: Equatable {
        var undo: String?
        var redo: String?
        /// Undo or Redo would move, copy or rename files (`.changesFiles`).
        var undoChangesFiles = false
        var redoChangesFiles = false
    }

    @Published private(set) var labels = Labels()
    private weak var manager: UndoManager?
    private var notificationObservers: [any NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshScheduled = false

    /// Follows `library`'s undo manager. Called whenever the window's view
    /// appears; following the same manager again adds nothing.
    func attach(to library: Library) {
        if subscriptions.isEmpty {
            // Another folder drops the old one's actions, which the undo
            // manager doesn't announce.
            library.$folderURL.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        }
        guard let manager = library.undoManager, manager !== self.manager else { return }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        // Not the checkpoint notification: asking `canRedo` posts one.
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange]
        notificationObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        self.manager = manager
        scheduleRefresh()
    }

    /// A turn later, once for any number of notifications: they can arrive
    /// in the middle of a view update, which must not publish itself.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let next = Labels(undo: manager.flatMap { $0.canUndo ? $0.undoActionName : nil },
                              redo: manager.flatMap { $0.canRedo ? $0.redoActionName : nil },
                              undoChangesFiles: manager?.undoActionUserInfoValue(forKey: .changesFiles) as? Bool ?? false,
                              redoChangesFiles: manager?.redoActionUserInfoValue(forKey: .changesFiles) as? Bool ?? false)
            if next != labels { labels = next }
        }
    }
}
