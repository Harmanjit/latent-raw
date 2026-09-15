import XCTest
@testable import latent_app

@MainActor
/// docs/wiki/Keyboard-Shortcuts.md is generated from `Shortcuts`. To
/// update it after changing the table:
///
///     LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests
final class ShortcutsPageTests: XCTestCase {
    private var pageURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/wiki/Keyboard-Shortcuts.md")
    }

    func testCommittedPageMatchesTheTable() throws {
        let generated = Shortcuts.pageMarkdown()
        if ProcessInfo.processInfo.environment["LATENT_WRITE_SHORTCUTS_PAGE"] != nil {
            try generated.write(to: pageURL, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: pageURL, encoding: .utf8)
        XCTAssertEqual(committed, generated,
                       "The shortcuts page is out of date; run LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests")
    }

    func testEveryShortcutIsOnThePageOnce() {
        var listed: [KeyCommand] = []
        for section in Shortcuts.page {
            for row in section.rows {
                if case .commands(let commands) = row.keys { listed += commands }
            }
        }
        for shortcut in Shortcuts.all {
            XCTAssertEqual(listed.filter { $0 == shortcut.command }.count, 1, "\(shortcut.command)")
        }
        for command in listed {
            XCTAssertNotNil(Shortcuts.shortcut(for: command), "\(command) is on the page without a key")
        }
    }

    func testSystemRowsNameSystemShortcuts() {
        for section in Shortcuts.page {
            for row in section.rows {
                if case .system(let title) = row.keys {
                    XCTAssertTrue(Shortcuts.system.contains { $0.title == title }, title)
                }
            }
        }
    }

    func testPageSpellsKeysAsTheMenusDo() {
        let page = Shortcuts.pageMarkdown()
        XCTAssertTrue(page.contains("| 0–5 | Stars |"))
        XCTAssertTrue(page.contains("| G, E, C, D | Library, Loupe, Compare, Develop |"))
        XCTAssertTrue(page.contains("| ⇧⌘E | Export the selection |"))
        XCTAssertTrue(page.contains("| `\\` | Before / after |"))
        XCTAssertTrue(page.contains("| ⌘, | Settings |"))
    }

    func testDigitRunsCollapse() {
        XCTAssertEqual(Shortcuts.collapsingDigitRuns(["0", "1", "2", "3"]), ["0–3"])
        XCTAssertEqual(Shortcuts.collapsingDigitRuns(["1", "2"]), ["1", "2"])
        XCTAssertEqual(Shortcuts.collapsingDigitRuns(["P", "1", "2", "3", "X"]), ["P", "1–3", "X"])
        XCTAssertEqual(Shortcuts.collapsingDigitRuns(["1", "3", "4", "5"]), ["1", "3–5"])
        XCTAssertEqual(Shortcuts.collapsingDigitRuns(["⌘0", "⌘1"]), ["⌘0", "⌘1"])
    }
}
