import XCTest
import AppKit
import Catalog
@testable import latent_app

/// The Edit menu's titles outside Develop follow the Library's own undo
/// manager as actions are filed and undone, and a text field's typing is
/// never filed with them.
@MainActor
final class LibraryUndoObserverTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    func testLabelsFollowTheLibrarysUndoManager() async throws {
        let observer = LibraryUndoObserver()
        let library = Library()
        let manager = try XCTUnwrap(library.undoManager, "the Library has an undo manager of its own")
        manager.groupsByEvent = false
        observer.attach(to: library)
        XCTAssertEqual(observer.labels, .init())

        let target = Filer(manager)
        target.file()
        await eventually { observer.labels == .init(undo: "Rating (2 Images)", redo: nil) }

        manager.undo()
        await eventually { observer.labels == .init(undo: nil, redo: "Rating (2 Images)") }
        manager.redo()
        await eventually { observer.labels == .init(undo: "Rating (2 Images)", redo: nil) }
    }

    /// Undoing everything typed in a field (as ⌘Z does while it has the
    /// keyboard, through the window's undo manager) leaves the Library's
    /// actions alone.
    func testUndoingTypingNeverReachesLibraryActions() throws {
        let library = Library()
        let manager = try XCTUnwrap(library.undoManager)
        manager.groupsByEvent = false
        let filer = Filer(manager)
        filer.file()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("tree", replacementRange: editor.selectedRange())
        let windowManager = try XCTUnwrap(editor.undoManager)
        XCTAssertFalse(windowManager === manager)

        for _ in 0..<10 where windowManager.canUndo { windowManager.undo() }
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "Rating (2 Images)")
        window.makeFirstResponder(nil)
    }
}

/// Files an action that files itself again when undone or redone. Main
/// actor, so Swift 6.1 sees nothing non-Sendable sent into the handler.
@MainActor
private final class Filer {
    let manager: UndoManager
    init(_ manager: UndoManager) { self.manager = manager }

    func file() {
        let own = manager.groupingLevel == 0
        if own { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { filer in MainActor.assumeIsolated { filer.file() } }
        manager.setActionName("Rating (2 Images)")
        if own { manager.endUndoGrouping() }
    }
}
