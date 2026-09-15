import XCTest
import AppKit
@testable import latent_app

/// The single-key table and the monitor's decisions, without a window.
final class BareKeyTests: XCTestCase {
    private func press(_ characters: String, shift: Bool = false, command: Bool = false,
                       option: Bool = false, control: Bool = false) -> BareKeyPress? {
        BareKeyPress(charactersIgnoringModifiers: characters, shift: shift, command: command,
                     option: option, control: control)
    }

    private func command(_ characters: String, shift: Bool = false) -> KeyCommand? {
        press(characters, shift: shift).flatMap(KeyCommand.command(for:))
    }

    func testModifiedKeysAreNotBareKeys() {
        XCTAssertNil(press("g", command: true))
        XCTAssertNil(press("g", option: true))
        XCTAssertNil(press("g", control: true))
        XCTAssertNil(press("ab"))
    }

    func testSpecialKeysAreRead() {
        XCTAssertEqual(press("\u{F702}")?.key, .leftArrow)
        XCTAssertEqual(press("\u{F703}")?.key, .rightArrow)
        XCTAssertEqual(press("\r")?.key, .returnKey)
        XCTAssertEqual(press("\u{1B}")?.key, .escape)
        XCTAssertEqual(press("\u{7F}")?.key, .delete)
        XCTAssertEqual(press("\u{08}")?.key, .delete)
        XCTAssertEqual(press("G", shift: true), BareKeyPress(.character("g"), shift: true))
    }

    func testLightroomKeys() {
        XCTAssertEqual(command("g"), .library)
        XCTAssertEqual(command("e"), .loupe)
        XCTAssertEqual(command("c"), .compare)
        XCTAssertEqual(command("d"), .develop)
        XCTAssertEqual(command(" "), .toggleLoupe)
        XCTAssertEqual(command("z"), .toggleZoom)
        XCTAssertEqual(command("\u{F703}"), .step(1))
        XCTAssertEqual(command("\u{F702}"), .step(-1))
        XCTAssertEqual(command("\r"), .openSelection)
        XCTAssertEqual(command("p"), .pick)
        XCTAssertEqual(command("x"), .reject)
        XCTAssertEqual(command("u"), .unflag)
        XCTAssertEqual(command("\\"), .beforeAfter)
        XCTAssertEqual(command("r"), .crop)
        XCTAssertEqual(command("h"), .heal)
        XCTAssertEqual(command("\u{7F}"), .deleteHeal)
        XCTAssertEqual(command("\u{1B}"), .disarmTools)
        XCTAssertEqual(command("["), .toolSize(-1))
        XCTAssertEqual(command("]"), .toolSize(1))
    }

    func testRatingsAreZeroToFiveOnly() {
        for stars in 0...5 {
            XCTAssertEqual(command(String(stars)), .rate(stars))
        }
        XCTAssertNil(command("6"))
        XCTAssertNil(command("٣"), "Only ASCII digits rate")
    }

    func testShiftOnlyMakesSelect() {
        XCTAssertEqual(command("X", shift: true), .makeSelect)
        XCTAssertEqual(command("x", shift: true), .makeSelect)
        XCTAssertNil(command("G", shift: true))
        XCTAssertNil(command("1", shift: true))
        XCTAssertNil(command("[", shift: true))
    }

    func testCommandShortcutsNeverComeFromBareKeys() {
        // ⌘Z is undo; a bare Z must stay the zoom toggle, and a bare comma nothing.
        XCTAssertEqual(command("z"), .toggleZoom)
        XCTAssertNil(command(","))
        XCTAssertNil(command("o"))
    }

    // MARK: Focus

    @MainActor func testFocusKinds() {
        let editable = NSTextView()
        XCTAssertEqual(KeyFocus(editable), .text)
        let readOnly = NSTextView()
        readOnly.isEditable = false
        XCTAssertEqual(KeyFocus(readOnly), .other)
        XCTAssertEqual(KeyFocus(NSButton(checkboxWithTitle: "On", target: nil, action: nil)), .control)
        XCTAssertEqual(KeyFocus(NSButton(title: "Go", target: nil, action: nil)), .control)
        XCTAssertEqual(KeyFocus(NSPopUpButton()), .control)
        XCTAssertEqual(KeyFocus(NSSegmentedControl()), .control)
        XCTAssertEqual(KeyFocus(NSSwitch()), .control)
        XCTAssertEqual(KeyFocus(NSSlider()), .slider)
        XCTAssertEqual(KeyFocus(DoubleClickSlider()), .slider)
        XCTAssertEqual(KeyFocus(NSTableView()), .list)
        XCTAssertEqual(KeyFocus(NSOutlineView()), .list)
        // The thumbnail grid and filmstrip: single keys stay commands.
        XCTAssertEqual(KeyFocus(NSCollectionView()), .other)
        XCTAssertEqual(KeyFocus(NSView()), .other)
        XCTAssertEqual(KeyFocus(nil), .other)
    }

    func testTextTakesEveryKey() {
        for characters in ["g", " ", "\r", "\u{F703}", "\u{1B}", "1"] {
            XCTAssertTrue(press(characters)!.belongs(to: .text), characters)
        }
    }

    /// With Full Keyboard Access, Space on a focused button presses it
    /// instead of switching to the loupe; Return likewise.
    func testFocusedControlsTakeSpaceAndReturnOnly() {
        XCTAssertTrue(press(" ")!.belongs(to: .control))
        XCTAssertTrue(press("\r")!.belongs(to: .control))
        XCTAssertFalse(press("\u{F703}")!.belongs(to: .control))
        XCTAssertFalse(press("g")!.belongs(to: .control))
        XCTAssertFalse(press("\u{1B}")!.belongs(to: .control))
    }

    /// The folder sidebar with the keyboard: arrows move and expand, Return
    /// and Space open, letters and digits jump to a folder, instead of
    /// stepping, switching modes or rating.
    func testFocusedListsTakeTheirKeys() {
        for characters in ["\u{F702}", "\u{F703}", "\r", " ", "g", "d", "2"] {
            XCTAssertTrue(press(characters)!.belongs(to: .list), characters)
        }
        XCTAssertTrue(press("G", shift: true)!.belongs(to: .list))
        XCTAssertFalse(press("\u{1B}")!.belongs(to: .list), "Escape still disarms tools")
        XCTAssertFalse(press("\u{7F}")!.belongs(to: .list))
    }

    /// With Full Keyboard Access a focused slider moves with ← and →
    /// instead of loading another image; its other keys stay commands.
    func testFocusedSlidersTakeLeftAndRight() {
        XCTAssertTrue(press("\u{F702}")!.belongs(to: .slider))
        XCTAssertTrue(press("\u{F703}", shift: true)!.belongs(to: .slider))
        XCTAssertFalse(press("\r")!.belongs(to: .slider))
        XCTAssertFalse(press(" ")!.belongs(to: .slider))
        XCTAssertFalse(press("g")!.belongs(to: .slider))
    }

    func testNothingElseTakesKeys() {
        XCTAssertFalse(press(" ")!.belongs(to: .other))
        XCTAssertFalse(press("\r")!.belongs(to: .other))
        XCTAssertFalse(press("\u{F703}")!.belongs(to: .other))
    }

    /// The Edit menu learns that typing started from key-value observing
    /// on the window's first responder; this is the AppKit behaviour it
    /// relies on.
    @MainActor func testFirstResponderChangesAreObservable() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(text)
        var seen: [KeyFocus] = []
        let observation = window.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated { seen.append(KeyFocus(window.firstResponder)) }
        }
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertTrue(window.makeFirstResponder(nil))
        observation.invalidate()
        // AppKit may report one change more than once; the monitor passes
        // on changes of kind only.
        XCTAssertEqual(seen.first, .text)
        XCTAssertEqual(seen.last, .other)
    }
}
