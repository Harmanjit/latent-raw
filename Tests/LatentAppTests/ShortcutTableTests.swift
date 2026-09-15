import XCTest
import SwiftUI
@testable import latent_app

@MainActor
final class ShortcutTableTests: XCTestCase {
    private struct Binding {
        let name: String
        let key: BareKeyPress.Key
        let modifiers: ShortcutModifiers
        let scope: ShortcutScope
    }

    private var bindings: [Binding] {
        Shortcuts.all.map { Binding(name: "\($0.command)", key: $0.key, modifiers: $0.modifiers, scope: $0.scope) }
            + Shortcuts.system.map { Binding(name: $0.title, key: $0.key, modifiers: $0.modifiers, scope: .everywhere) }
    }

    /// Two commands on the same keys where both apply would leave one of
    /// them unreachable (Cmd-Shift-C and V used to be declared twice).
    func testNoTwoCommandsShareKeysInTheSameScope() {
        let all = bindings
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] where a.key == b.key && a.modifiers == b.modifiers {
                XCTAssertFalse(a.scope.overlaps(b.scope),
                               "\(a.name) and \(b.name) both use \(Shortcuts.glyphs(a.key, a.modifiers))")
            }
        }
    }

    func testEachCommandHasOneShortcut() {
        for (i, a) in Shortcuts.all.enumerated() {
            for b in Shortcuts.all[(i + 1)...] {
                XCTAssertNotEqual(a.command, b.command, "\(a.command) is listed twice")
            }
        }
    }

    /// Option and Control are never bare keys, and a single key is only
    /// a hint in a menu title.
    func testBareKeysStayOutOfMenuKeyEquivalents() throws {
        XCTAssertTrue(try XCTUnwrap(Shortcuts.shortcut(for: .pick)).isBare)
        XCTAssertTrue(try XCTUnwrap(Shortcuts.shortcut(for: .makeSelect)).isBare)
        XCTAssertFalse(try XCTUnwrap(Shortcuts.shortcut(for: .undo)).isBare)
        XCTAssertFalse(Shortcut(.library, "g", .option).isBare)
        XCTAssertEqual(Shortcuts.menuTitle("Pick", for: .pick), "Pick (P)")
        XCTAssertEqual(Shortcuts.menuTitle("Make Select", for: .makeSelect), "Make Select (⇧X)")
        XCTAssertEqual(Shortcuts.menuTitle("Grid ↔ Loupe", for: .toggleLoupe), "Grid ↔ Loupe (Space)")
        XCTAssertEqual(Shortcuts.menuTitle("Undo", for: .undo), "Undo")
        XCTAssertEqual(Shortcuts.menuTitle("Swap", for: .swapCompare), "Swap")
    }

    func testGlyphsFollowTheMenuBarOrder() {
        XCTAssertEqual(Shortcuts.glyphs(.character("e"), [.command, .shift]), "⇧⌘E")
        XCTAssertEqual(Shortcuts.glyphs(.character("f"), [.command, .control]), "⌃⌘F")
        XCTAssertEqual(Shortcuts.glyphs(.character("h"), [.command, .option]), "⌥⌘H")
        XCTAssertEqual(Shortcuts.glyphs(.leftArrow, []), "←")
        XCTAssertEqual(Shortcuts.glyphs(.delete, []), "⌫")
        XCTAssertEqual(Shortcuts.glyphs(.escape, []), "Esc")
    }

    func testKeyEquivalentsMatchTheTable() throws {
        let redo = try XCTUnwrap(Shortcuts.shortcut(for: .redo))
        XCTAssertEqual(redo.keyEquivalent, KeyEquivalent("z"))
        XCTAssertEqual(redo.eventModifiers, [.command, .shift])
        XCTAssertEqual(Shortcut(.step(1), .rightArrow).keyEquivalent, .rightArrow)
        XCTAssertEqual(Shortcut(.openSelection, .returnKey).keyEquivalent, .return)
    }

    /// Menus take their keys from the table; a `.keyboardShortcut` written
    /// out anywhere else must at least be a key the table knows, or the
    /// uniqueness check above can't see it.
    func testLiteralKeyboardShortcutsAreInTheTable() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/latent-app")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\("(.)"(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?\)"#)
        let sample = #"Button("") {}.keyboardShortcut("u", modifiers: [.command, .shift])"#
        XCTAssertEqual(pattern.numberOfMatches(in: sample, range: NSRange(sample.startIndex..., in: sample)), 1)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = Character(String(text[Range(match.range(at: 1), in: text)!]).lowercased())
                let spelled = match.range(at: 2).location == NSNotFound ? "" : String(text[Range(match.range(at: 2), in: text)!])
                var modifiers: ShortcutModifiers = []
                if spelled.contains("command") { modifiers.insert(.command) }
                if spelled.contains("shift") { modifiers.insert(.shift) }
                if spelled.contains("option") { modifiers.insert(.option) }
                if spelled.contains("control") { modifiers.insert(.control) }
                if match.range(at: 2).location == NSNotFound { modifiers = .command }
                let known = Shortcuts.all.contains { $0.key == .character(key) && $0.modifiers == modifiers }
                    || Shortcuts.system.contains { $0.key == .character(key) && $0.modifiers == modifiers }
                XCTAssertTrue(known, "\(file.lastPathComponent): \(Shortcuts.glyphs(.character(key), modifiers)) is not in Shortcuts.all or Shortcuts.system")
            }
        }
    }
}
