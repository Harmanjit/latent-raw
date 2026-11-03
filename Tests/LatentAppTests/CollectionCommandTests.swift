import XCTest
import Catalog
@testable import latent_app

/// The collection commands: when the menu bar offers them, which keys
/// give them, and what B does to a real catalog.
@MainActor
final class CollectionCommandTests: XCTestCase {
    func testWhenCommandsAreOffered() {
        var state = CommandState()
        for command: KeyCommand in [.newCollection, .newSmartCollection, .newCollectionSet,
                                    .saveFilterAsSmartCollection, .addToTargetCollection, .removeFromCollection] {
            XCTAssertFalse(state.isEnabled(command), "\(command) with no folder open")
        }
        state.hasCatalog = true
        XCTAssertTrue(state.isEnabled(.newCollection))
        XCTAssertTrue(state.isEnabled(.newCollectionSet))
        XCTAssertFalse(state.isEnabled(.saveFilterAsSmartCollection), "nothing to save")
        XCTAssertFalse(state.isEnabled(.addToTargetCollection), "nothing selected")
        state.filterActive = true
        state.hasSelection = true
        state.selectionCount = 2
        XCTAssertTrue(state.isEnabled(.saveFilterAsSmartCollection))
        XCTAssertTrue(state.isEnabled(.addToTargetCollection))
        XCTAssertFalse(state.isEnabled(.removeFromCollection), "the grid isn't showing a collection")
        state.showsRegularCollection = true
        XCTAssertTrue(state.isEnabled(.removeFromCollection))
    }

    func testKeys() {
        XCTAssertEqual(Shortcuts.shortcut(for: .addToTargetCollection)?.glyphs, "B")
        XCTAssertEqual(Shortcuts.shortcut(for: .newCollection)?.glyphs, "⌘N")
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character("b"))), .addToTargetCollection)
    }

    func testNewCommandsAskForTheirSheets() {
        let library = Library()
        let sheets = CollectionSheets.shared
        defer { sheets.request = nil }
        CollectionCommands.perform(.newSmartCollection, library: library)
        XCTAssertEqual(sheets.request, .new(.smart, parent: nil))
        CollectionCommands.perform(.saveFilterAsSmartCollection, library: library)
        XCTAssertEqual(sheets.request, .smartFromFilter)
    }

    func testBAddsTheSelectionToTheQuickCollection() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(atPath: try TestAssets.d750Path(), toPath: folder.appendingPathComponent("A.NEF").path)
        let library = Library()
        try await library.open(folder: folder)
        let a = try XCTUnwrap(library.images.first?.id)
        library.setSelection([a], primary: a)
        CollectionCommands.perform(.addToTargetCollection, library: library)
        XCTAssertEqual(library.collections.targetCollection?.name, "Quick Collection")
        XCTAssertTrue(library.collections.targetContains([a]))
        XCTAssertEqual(CollectionCommands.targetTitle(library), "Add to Quick Collection")
        await library.waitForPendingWork()
    }
}
