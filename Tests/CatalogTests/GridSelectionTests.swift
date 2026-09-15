import XCTest
@testable import Catalog

@MainActor
final class GridSelectionTests: XCTestCase {
    func testPlainClickLeads() {
        XCTAssertEqual(GridSelection.lead(previous: 3, added: [7], selected: [7]), 7)
        XCTAssertEqual(GridSelection.lead(previous: nil, added: [2], selected: [2]), 2)
    }

    /// Shift-click from 5 to 9 adds 6…9: the clicked end leads, whatever
    /// order the set of added items comes in.
    func testShiftClickLeadsFromTheEndThatMoved() {
        XCTAssertEqual(GridSelection.lead(previous: 5, added: Set([8, 6, 9, 7]), selected: Set(5...9)), 9)
        // Shift-click backwards, from 5 to 1.
        XCTAssertEqual(GridSelection.lead(previous: 5, added: [4, 1, 3, 2], selected: Set(1...5)), 1)
    }

    /// Cmd-click adds one (it leads); Cmd-clicking the lead away hands the
    /// lead to the first image still selected; a deselection elsewhere keeps it.
    func testCommandClickAndDeselection() {
        XCTAssertEqual(GridSelection.lead(previous: 2, added: [10], selected: [2, 10]), 10)
        XCTAssertEqual(GridSelection.lead(previous: 10, added: [], selected: [4, 2]), 2)
        XCTAssertEqual(GridSelection.lead(previous: 4, added: [], selected: [4, 9]), 4)
        XCTAssertNil(GridSelection.lead(previous: 4, added: [], selected: []))
    }

    func testAddedItemsNotSelectedAreIgnored() {
        XCTAssertEqual(GridSelection.lead(previous: 0, added: [12], selected: [3]), 3)
    }

    func testResolvedLeadFromOutsideTheGrid() {
        let records = [record(1, "a"), record(2, "b"), record(3, "c")]
        XCTAssertEqual(GridSelection.resolvedLead(proposed: 3, current: 1, selected: [1, 3], order: records), 3)
        XCTAssertEqual(GridSelection.resolvedLead(proposed: nil, current: 3, selected: [2, 3], order: records), 3)
        XCTAssertEqual(GridSelection.resolvedLead(proposed: 1, current: nil, selected: [3, 2], order: records), 2,
                       "neither proposed nor current is selected: the first in grid order")
        XCTAssertNil(GridSelection.resolvedLead(proposed: 1, current: 1, selected: [], order: records))
        XCTAssertEqual(GridSelection.resolvedLead(proposed: nil, current: nil, selected: [9, 8], order: records), 8,
                       "selected images hidden by a filter still resolve")
    }

    func testThumbnailSizeSteps() {
        XCTAssertEqual(ThumbnailGridLayout.stepped(160, larger: true), 176)
        XCTAssertEqual(ThumbnailGridLayout.stepped(160, larger: false), 144)
        XCTAssertEqual(ThumbnailGridLayout.stepped(150, larger: true), 160, "off-step sizes land on the next step")
        XCTAssertEqual(ThumbnailGridLayout.stepped(150, larger: false), 144)
        XCTAssertEqual(ThumbnailGridLayout.stepped(256, larger: true), 256)
        XCTAssertEqual(ThumbnailGridLayout.stepped(80, larger: false), 80)
        XCTAssertEqual(ThumbnailGridLayout(side: 1000).side, 256)
    }

    /// The largest cell asks for the stored 512 px thumbnail on Retina, and
    /// small cells for the 256 px tier.
    func testLayoutGeometry() {
        let large = ThumbnailGridLayout(side: 256)
        XCTAssertEqual(ThumbnailLoader.tier(forPixelSize: large.pixelSize(backingScale: 2)), 512)
        XCTAssertEqual(ThumbnailLoader.tier(forPixelSize: ThumbnailGridLayout(side: 120).pixelSize(backingScale: 2)), 256)
        XCTAssertEqual(large.itemSize.width, 264)

        let layout = ThumbnailGridLayout(side: 160)
        let portrait = layout.imageFrame(for: CGSize(width: 341, height: 512))
        XCTAssertEqual(portrait.height, 160)
        XCTAssertEqual(portrait.midX, layout.thumbnailArea.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(layout.nameFrame.minY, layout.thumbnailArea.maxY)
        XCTAssertLessThanOrEqual(layout.badgeFrame.maxY, layout.itemSize.height)
    }

    /// Only a change the active filter or sort looks at needs the folder
    /// filtered and sorted again.
    func testChangeDependencies() {
        let old = record(1, "a")
        var rated = old; rated.rating = 3
        var flagged = old; flagged.flag = 1
        var turned = old; turned.userRotation = 1

        var filter = LibraryFilter()
        XCTAssertFalse(filter.dependsOnChange(from: old, to: rated))
        filter.flags = [.picked]
        XCTAssertFalse(filter.dependsOnChange(from: old, to: rated))
        XCTAssertTrue(filter.dependsOnChange(from: old, to: flagged))
        filter.minRating = 2
        XCTAssertTrue(filter.dependsOnChange(from: old, to: rated))
        XCTAssertFalse(filter.dependsOnChange(from: old, to: turned))

        XCTAssertFalse(LibrarySort.default.dependsOnChange(from: old, to: rated))
        XCTAssertTrue(LibrarySort(key: .rating, ascending: false).dependsOnChange(from: old, to: rated))
        XCTAssertFalse(LibrarySort(key: .rating, ascending: false).dependsOnChange(from: old, to: flagged))
    }

    private func record(_ id: Int64, _ name: String) -> ImageRecord {
        ImageRecord(id: id, relPath: "\(name).NEF", preservedName: nil, size: 1, mtime: 1, xxhash: Data(),
                    captureTime: 100, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }
}
