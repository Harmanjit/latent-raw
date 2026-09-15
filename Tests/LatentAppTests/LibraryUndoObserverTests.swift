import XCTest
import Catalog
@testable import latent_app

/// The Edit menu's titles outside Develop follow the window's undo manager
/// as actions are filed and undone.
@MainActor
final class LibraryUndoObserverTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    func testLabelsFollowTheUndoManager() async {
        let observer = LibraryUndoObserver()
        let library = Library()
        let manager = UndoManager()
        manager.groupsByEvent = false
        observer.attach(manager, to: library)
        XCTAssertTrue(library.undoManager === manager, "the Library files on the window's manager")
        XCTAssertEqual(observer.labels, .init())

        let target = Filer(manager)
        target.file()
        await eventually { observer.labels == .init(undo: "Rating (2 Images)", redo: nil) }

        manager.undo()
        await eventually { observer.labels == .init(undo: nil, redo: "Rating (2 Images)") }
        manager.redo()
        await eventually { observer.labels == .init(undo: "Rating (2 Images)", redo: nil) }
    }
}

/// Files an action that files itself again when undone or redone; the
/// handler captures nothing, whatever the SDK says it must be.
private final class Filer {
    let manager: UndoManager
    init(_ manager: UndoManager) { self.manager = manager }

    @MainActor func file() {
        let own = manager.groupingLevel == 0
        if own { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { filer in MainActor.assumeIsolated { filer.file() } }
        manager.setActionName("Rating (2 Images)")
        if own { manager.endUndoGrouping() }
    }
}
