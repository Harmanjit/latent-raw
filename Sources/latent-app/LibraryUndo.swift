import SwiftUI
import AppKit
import Combine
import Catalog

/// Undo and Redo outside Develop: the Library's actions (ratings, flags,
/// rotation, keywords, pasted settings and presets) are filed on the
/// window's undo manager, the one its text fields use for typing. Develop
/// keeps its own edit history (EditHistory).
///
/// This gives the Library that undo manager and keeps the Edit menu's
/// titles up to date as actions are filed, undone and dropped.
@MainActor
final class LibraryUndoObserver: ObservableObject {
    /// "Rating (12 Images)"-style names of what Undo and Redo would do,
    /// nil when there is nothing to.
    struct Labels: Equatable {
        var undo: String?
        var redo: String?
    }

    @Published private(set) var labels = Labels()
    private weak var manager: UndoManager?
    private var notificationObservers: [any NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshScheduled = false

    /// Hands `manager` to `library` and follows it. Called whenever the
    /// window's view lands in a window; a window opened again brings a new
    /// undo manager.
    func attach(_ manager: UndoManager, to library: Library) {
        library.undoManager = manager
        if subscriptions.isEmpty {
            // Another folder drops the old one's actions, which the undo
            // manager doesn't announce; typing starting or stopping may add
            // or remove a field's own.
            library.$folderURL.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
            KeyWindowTextFocus.shared.$isEditingText.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        }
        guard manager !== self.manager else { return }
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
                              redo: manager.flatMap { $0.canRedo ? $0.redoActionName : nil })
            if next != labels { labels = next }
        }
    }
}

/// Reports the undo manager of the window this sits in, once it's in one.
struct WindowUndoManagerReader: NSViewRepresentable {
    let onAttach: @MainActor (UndoManager) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onAttach = onAttach
    }

    final class ReaderView: NSView {
        var onAttach: (@MainActor (UndoManager) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let manager = window?.undoManager else { return }
            // Moving into a window can happen during a view update.
            Task { @MainActor [weak self] in self?.onAttach?(manager) }
        }
    }
}
