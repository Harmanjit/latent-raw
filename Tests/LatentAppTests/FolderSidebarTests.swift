import XCTest
import AppKit
import Catalog
@testable import latent_app

/// The folder sidebar from the keyboard and VoiceOver: the rules alone,
/// then the outline in a window.
@MainActor
final class FolderSidebarTests: XCTestCase {
    // MARK: Rules

    /// Tab, Full Keyboard Access and VoiceOver give the sidebar the
    /// keyboard; a click, or the window opening, doesn't.
    func testFolderOutlineTakesFocusOnlyFromTheKeyboard() {
        XCTAssertTrue(FolderOutlineKeyboard.takesFocus(during: .keyDown, characters: "\t", voiceOver: false))
        XCTAssertTrue(FolderOutlineKeyboard.takesFocus(during: .keyDown, characters: "\u{19}", voiceOver: false))
        XCTAssertFalse(FolderOutlineKeyboard.takesFocus(during: .leftMouseDown, characters: nil, voiceOver: false))
        XCTAssertFalse(FolderOutlineKeyboard.takesFocus(during: .rightMouseDown, characters: nil, voiceOver: false))
        XCTAssertFalse(FolderOutlineKeyboard.takesFocus(during: nil, characters: nil, voiceOver: false))
        // ⌘N opening a window that picks its first key view.
        XCTAssertFalse(FolderOutlineKeyboard.takesFocus(during: .keyDown, characters: "n", voiceOver: false))
        XCTAssertTrue(FolderOutlineKeyboard.takesFocus(during: nil, characters: nil, voiceOver: true))
        XCTAssertTrue(FolderOutlineKeyboard.takesFocus(during: .leftMouseDown, characters: nil, voiceOver: true))
    }

    func testReturnAndSpaceOpenTheSelectedFolder() {
        XCTAssertTrue(FolderOutlineKeyboard.opensSelection(characters: "\r", modifiers: []))
        XCTAssertTrue(FolderOutlineKeyboard.opensSelection(characters: "\u{3}", modifiers: [.numericPad]))
        XCTAssertTrue(FolderOutlineKeyboard.opensSelection(characters: " ", modifiers: []))
        XCTAssertFalse(FolderOutlineKeyboard.opensSelection(characters: "\r", modifiers: [.command]))
        XCTAssertFalse(FolderOutlineKeyboard.opensSelection(characters: "\u{F703}", modifiers: [.function]))
        XCTAssertFalse(FolderOutlineKeyboard.opensSelection(characters: "g", modifiers: []))
    }

    // MARK: The outline in a window

    // setUp and tearDown are nonisolated overrides, so on Swift 6.1 they
    // can only reach a fixture the class's main-actor isolation doesn't cover.
    nonisolated(unsafe) private var folders: [URL] = []

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderSidebarTests-\(UUID().uuidString)")
        folders = ["Alpha", "Beta"].map { root.appendingPathComponent($0) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        if let root = folders.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeOutline(opened: @escaping (URL) -> Void) throws -> (NSWindow, FolderOutlineController, NSOutlineView) {
        let controller = FolderOutlineController()
        controller.onOpen = { opened($0); return true }
        controller.setFavourites(folders.map { FavouriteFolder(url: $0, bookmark: Data(), isAvailable: true) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap((controller.view as? NSScrollView)?.documentView as? NSOutlineView)
        // The Favourites header, then one row a folder.
        XCTAssertEqual(outline.numberOfRows, 3)
        return (window, controller, outline)
    }

    private func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    func testReturnOpensTheSelectedFolder() throws {
        var opened: [URL] = []
        let (window, _, outline) = try makeOutline { opened.append($0) }
        outline.selectRowIndexes([2], byExtendingSelection: false)
        XCTAssertTrue(opened.isEmpty, "Selecting doesn't open")
        outline.keyDown(with: try key("\r", keyCode: 36, in: window))
        XCTAssertEqual(opened.map(\.lastPathComponent), ["Beta"])
        outline.selectRowIndexes([1], byExtendingSelection: false)
        outline.keyDown(with: try key(" ", keyCode: 49, in: window))
        XCTAssertEqual(opened.map(\.lastPathComponent), ["Beta", "Alpha"])
    }

    func testVoiceOverPressOpensTheRowsFolder() throws {
        var opened: [URL] = []
        let (_, _, outline) = try makeOutline { opened.append($0) }
        let row = try XCTUnwrap(outline.rowView(atRow: 2, makeIfNecessary: true))
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(opened.map(\.lastPathComponent), ["Beta"])
    }

    func testMenuWithoutAClickIsForTheSelectedRow() throws {
        let (_, controller, outline) = try makeOutline { _ in }
        outline.selectRowIndexes([1], byExtendingSelection: false)
        let menu = try XCTUnwrap(outline.menu)
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Add Folder…"], "No row was clicked or asked for")
        XCTAssertTrue(outline.accessibilityPerformShowMenu())
        // The menu pops up a turn later and tracks until cancelled.
        let cancel = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { menu.cancelTrackingWithoutAnimation() }
        }
        RunLoop.current.add(cancel, forMode: .common)
        defer { cancel.invalidate() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(menu.items.map(\.title).contains("Remove from Favourites"), "\(menu.items.map(\.title))")
    }

    func testAClickNeverGivesTheOutlineTheKeyboard() throws {
        let (_, _, outline) = try makeOutline { _ in }
        try XCTSkipIf(NSWorkspace.shared.isVoiceOverEnabled, "VoiceOver gives it the keyboard any time")
        // No key press is being handled: as for a click, or the window opening.
        XCTAssertFalse(outline.acceptsFirstResponder)
    }
}
