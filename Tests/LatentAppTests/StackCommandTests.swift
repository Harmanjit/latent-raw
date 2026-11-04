import XCTest
@testable import Catalog
@testable import latent_app

/// The stack commands' keys and enabling, the grid's stack badge, and the
/// export preset's Add to This Catalog options.
@MainActor
final class StackCommandTests: XCTestCase {
    private func library(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 2
        state.hasCatalog = true
        change(&state)
        return state
    }

    func testLightroomKeys() {
        XCTAssertEqual(Shortcuts.shortcut(for: .stack(.group))?.glyphs, "⌘G")
        XCTAssertEqual(Shortcuts.shortcut(for: .stack(.unstack))?.glyphs, "⇧⌘G")
        // S is shared with Develop's Soft Proofing; the Library's is the stack's.
        XCTAssertTrue(Shortcuts.commands(for: BareKeyPress(.character("s"))).contains(.stack(.toggleExpanded)))
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character("s"), shift: true)), .stack(.moveToTop))
    }

    func testEnabling() {
        XCTAssertTrue(library().isEnabled(.stack(.group)))
        XCTAssertFalse(library { $0.selectionCount = 1 }.isEnabled(.stack(.group)))
        XCTAssertFalse(library { $0.mode = .develop }.isEnabled(.stack(.group)))
        XCTAssertFalse(library { $0.fileOperationRunning = true }.isEnabled(.stack(.group)))
        XCTAssertFalse(library().isEnabled(.stack(.unstack)))
        XCTAssertTrue(library { $0.stacking.selectionInStack = true }.isEnabled(.stack(.toggleExpanded)))
        XCTAssertFalse(library().isEnabled(.stack(.moveToTop)))
        XCTAssertTrue(library { $0.stacking.primaryBelowTop = true }.isEnabled(.stack(.moveToTop)))
        XCTAssertFalse(library().isEnabled(.stack(.collapseAll)))
        XCTAssertTrue(library { $0.stacking.hasStacks = true }.isEnabled(.stack(.expandAll)))
        XCTAssertTrue(library().isEnabled(.stack(.autoStackByCaptureTime)))
    }

    func testBadgeText() {
        XCTAssertNil(StackBadgeView.text(nil))
        let collapsed = StackMembership(stackID: 1, position: 0, count: 3, isCollapsed: true)
        XCTAssertEqual(StackBadgeView.text(collapsed), "▤ 3")
        XCTAssertEqual(StackBadgeView.spokenText(collapsed), "stack of 3")
        let expanded = StackMembership(stackID: 1, position: 1, count: 3, isCollapsed: false)
        XCTAssertEqual(StackBadgeView.text(expanded), "2/3")
        XCTAssertEqual(StackBadgeView.spokenText(expanded), "2 of 3 in stack")
    }

    func testPresetOptionsRoundTripAndDefaultOff() throws {
        let old = try JSONDecoder().decode(ExportPreset.self, from: Data("{}".utf8))
        XCTAssertFalse(old.addToCatalog)
        XCTAssertEqual(old.stackWithOriginal, .off)
        var preset = ExportPreset()
        preset.addToCatalog = true
        preset.stackWithOriginal = .below
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(back, preset)

        var record = ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        record.id = 7
        let url = URL(fileURLWithPath: "/tmp/A.jpg")
        XCTAssertEqual(back.exportedFile(url, from: record),
                       Library.ExportedFile(url: url, sourceID: 7, placement: .below))
        XCTAssertNil(ExportPreset().exportedFile(url, from: record))
    }
}
