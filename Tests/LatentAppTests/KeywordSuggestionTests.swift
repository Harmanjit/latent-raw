import XCTest
import Catalog
import PixelEngine
@testable import latent_app

/// Quick keyword entry, the keyword chips' Recent list, moving keywords by
/// dragging, and what "Edit changes" smart collections read of an edit.
@MainActor
final class KeywordSuggestionTests: XCTestCase {
    func testAddKeywordsCommand() {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.addKeywords), "no folder open")
        state.hasCatalog = true
        XCTAssertFalse(state.isEnabled(.addKeywords), "nothing selected")
        state.hasSelection = true
        state.selectionCount = 1
        XCTAssertTrue(state.isEnabled(.addKeywords))
        XCTAssertEqual(Shortcuts.shortcut(for: .addKeywords)?.glyphs, "⌘K")
        let before = KeywordEntryFocus.shared.request
        KeywordEntryFocus.shared.requestFocus()
        XCTAssertEqual(KeywordEntryFocus.shared.request, before + 1)
    }

    func testRecentKeywordsKeepTheNewestFirst() {
        var list: [String] = []
        list = RecentKeywords.recording(["sky", "sea"], in: list)
        XCTAssertEqual(list, ["sky", "sea"])
        list = RecentKeywords.recording(["dog", "sea"], in: list)
        XCTAssertEqual(list, ["dog", "sea", "sky"])
        list = RecentKeywords.recording((0..<20).map { "k\($0)" }, in: list)
        XCTAssertEqual(list.count, RecentKeywords.limit)
        XCTAssertEqual(list.first, "k0")
    }

    func testKeywordDragDestinations() {
        XCTAssertEqual(KeywordDrag.path(fromDropped: KeywordDrag.prefix + "Places|Paris"), "Places|Paris")
        XCTAssertNil(KeywordDrag.path(fromDropped: "file:///Users/x/A.NEF"))
        XCTAssertEqual(KeywordDrag.destination(moving: "Paris", onto: "Places|France"), "Places|France|Paris")
        XCTAssertEqual(KeywordDrag.destination(moving: "Places|France|Paris", onto: nil), "Paris", "to the top level")
        XCTAssertNil(KeywordDrag.destination(moving: "Paris", onto: nil), "already at the top")
        XCTAssertNil(KeywordDrag.destination(moving: "Places", onto: "Places|France"), "not into itself")
        XCTAssertNil(KeywordDrag.destination(moving: "Places|France", onto: "Places"), "already there")
    }

    func testEditGroupsReader() throws {
        var p = EditParameters()
        p.exposureEV = 1
        let json = try EditStack(parameters: p).encodeJSON()
        let groups = SmartCollectionEditGroups.reader(json)
        XCTAssertTrue(groups.contains(EditGroup.tone.rawValue))
        XCTAssertFalse(groups.contains(EditGroup.crop.rawValue))
        XCTAssertEqual(SmartCollectionEditGroups.reader(try EditStack(parameters: EditParameters()).encodeJSON()), [],
                       "the defaults change nothing")
        XCTAssertEqual(SmartCollectionEditGroups.reader("{nonsense"), [])
    }
}
