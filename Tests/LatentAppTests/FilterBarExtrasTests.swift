import XCTest
import AppKit
import SwiftUI
@testable import Catalog
@testable import PixelEngine
@testable import latent_app

/// The filter bar's presets and label exclusion, the grid's keyword badge,
/// the edited pencil's tooltip and View › Grid Marks.
@MainActor
final class FilterBarExtrasTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "FilterBarExtrasTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPresetsSaveRenameRemoveAndPersist() {
        let store = FilterPresetStore(defaults: defaults)
        XCTAssertTrue(store.names.isEmpty)
        var filter = LibraryFilter()
        filter.minRating = 3
        filter.isoRange = 100...400
        filter.recentlyAddedIDs = [7]
        store.save(filter, as: "  Keepers ")
        store.save(LibraryFilter(), as: "   ")
        XCTAssertEqual(store.names, ["Keepers"], "trimmed, and an empty name saves nothing")
        XCTAssertNil(store.presets["Keepers"]?.recentlyAddedIDs, "the Recently Added list isn't a setting")
        XCTAssertEqual(store.presets["Keepers"]?.isoRange, 100...400)

        store.save(LibraryFilter(), as: "Another")
        XCTAssertFalse(store.rename("Keepers", to: "Another"), "names stay unique")
        XCTAssertTrue(store.rename("Keepers", to: "Best"))
        XCTAssertEqual(FilterPresetStore(defaults: defaults).names, ["Another", "Best"], "kept in the preferences")
        store.remove("Another")
        XCTAssertEqual(FilterPresetStore(defaults: defaults).names, ["Best"])
    }

    func testGridMarksModeDefaultsToAlwaysAndPersists() {
        let settings = GridMarksSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .always)
        settings.mode = .minimal
        XCTAssertEqual(GridMarksSettings(defaults: defaults).mode, .minimal)
    }

    func testLabelExclusionTogglesAndSummaries() {
        var selection: Set<LabelFilterChoice> = [.color(.red)]
        var excluded: Set<LabelFilterChoice> = []
        let s = Binding(get: { selection }, set: { selection = $0 })
        let e = Binding(get: { excluded }, set: { excluded = $0 })
        LabelFilterExclusion.toggleExcluded(.color(.red), selection: s, excluded: e)
        XCTAssertEqual(excluded, [.color(.red)])
        XCTAssertTrue(selection.isEmpty, "excluding a label takes it out of the included ones")
        selection = [.color(.blue)]
        XCTAssertEqual(LabelFilterExclusion.summary(selection: selection, excluded: excluded), "−Red, Blue")
        XCTAssertEqual(LabelFilterExclusion.spoken(selection: selection, excluded: excluded), "Blue; not Red")
        LabelFilterExclusion.toggleExcluded(.color(.red), selection: s, excluded: e)
        XCTAssertTrue(excluded.isEmpty)
    }

    func testRatingRangeWording() {
        var f = LibraryFilter()
        XCTAssertEqual(RatingRangeText.summary(f), "Any rating")
        f.minRating = 3
        XCTAssertEqual(RatingRangeText.summary(f), "3 stars or more")
        f.ratingOperator = .between
        f.maxRating = 4
        XCTAssertEqual(RatingRangeText.summary(f), "3 to 4 stars")
        f.ratingOperator = .atMost
        f.maxRating = 2
        XCTAssertEqual(RatingRangeText.shownRating(f), 2, "the bar's stars show the top under At most")
    }

    func testEditedTooltipListsTheChangedGroups() throws {
        var stack = EditStack()
        stack.modules.exposure = .init(ev: 0.7)
        let json = try stack.encodeJSON()
        let groups = EditedGroupsSummary.changedGroups(json: json)
        XCTAssertEqual(groups, [.tone])
        XCTAssertEqual(EditedGroupsSummary.toolTip(groups), "Edited: Tone")
        XCTAssertEqual(EditedGroupsSummary.changedGroups(json: try EditStack().encodeJSON()), [])
        XCTAssertEqual(EditedGroupsSummary.changedGroups(json: "not json"), [])
    }

    func testKeywordBadgeTooltipAndCellModes() {
        let badge = KeywordBadgeView()
        XCTAssertTrue(badge.setKeywords(["Places|France", "beach"]))
        XCTAssertFalse(badge.setKeywords(["beach", "Places|France"]), "same keywords, no redraw")
        XCTAssertEqual(badge.toolTip, "Keywords: beach, Places › France")
        badge.setKeywords([])
        XCTAssertNil(badge.toolTip)

        var record = ImageRecord(id: 1, relPath: "a.NEF", preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                                 captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil,
                                 aperture: nil, focal: nil, width: nil, height: nil, orientation: nil, rating: 0,
                                 label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
        XCTAssertEqual(ThumbnailCellView.infoText(record), "")
        record.shutter = 1.0 / 250
        record.aperture = 2.8
        record.iso = 400
        XCTAssertEqual(ThumbnailCellView.infoText(record), "1/250 s  f/2.8  ISO 400")

        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 176, height: 210))
        cell.setMarks(name: "c.NEF", rating: 3, flag: 1, isEdited: true)
        XCTAssertEqual(text(in: cell), ["c.NEF", "✎  ✓"], "Always: the marks as they were")
        cell.marksMode = .minimal
        XCTAssertEqual(text(in: cell), ["✓"], "Minimal: the flag, no name, no pencil")
        cell.marksMode = .always
        XCTAssertEqual(text(in: cell), ["c.NEF", "✎  ✓"])
    }

    /// The visible text fields' strings, top to bottom.
    private func text(in view: NSView) -> [String] {
        view.subviews.compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            .map(\.stringValue)
    }
}
