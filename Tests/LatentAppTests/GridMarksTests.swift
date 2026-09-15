import XCTest
import AppKit
import Catalog
@testable import latent_app

/// The grid cell's clickable stars and tag dots, the drag target, and the
/// saved sort.
@MainActor
final class GridMarksTests: XCTestCase {
    func testStarsShowOnlyTheRatingUntilHovered() {
        XCTAssertEqual(StarRatingView.glyphs(rating: 2, cellHovered: false, hoveredStar: nil),
                       [.filled, .filled, .none, .none, .none])
        XCTAssertEqual(StarRatingView.glyphs(rating: 2, cellHovered: true, hoveredStar: nil),
                       [.filled, .filled, .hollow, .hollow, .hollow])
        XCTAssertEqual(StarRatingView.glyphs(rating: 4, cellHovered: true, hoveredStar: 3),
                       [.preview, .preview, .preview, .hollow, .hollow], "the rating a click would set")
    }

    /// A click on a star rates and stays with the stars: the view behind
    /// (the collection view, which would select or start a drag) never
    /// sees it. A click beside the stars goes on as usual.
    func testStarClickIsTakenByTheStars() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let behind = ClickRecorder(frame: window.contentView!.bounds)
        window.contentView = behind
        let layout = ThumbnailGridLayout(side: 160)
        let cell = ThumbnailCellView(frame: NSRect(origin: .zero, size: layout.itemSize))
        cell.layoutInfo = layout
        behind.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        var clicked: [Int] = []
        cell.onRate = { clicked.append($0) }

        // As the window delivers a click: to the deepest view under it,
        // which passes it up the responder chain or keeps it.
        func click(_ point: CGPoint) {
            let inWindow = cell.convert(point, to: nil)
            let event = try! XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [],
                                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: 1, pressure: 1))
            let target = try! XCTUnwrap(behind.hitTest(behind.convert(inWindow, from: nil)))
            target.mouseDown(with: event)
        }
        let stars = layout.starsFrame
        click(CGPoint(x: stars.minX + ThumbnailGridLayout.starWidth * 3.5, y: stars.midY))
        XCTAssertEqual(clicked, [4])
        XCTAssertEqual(behind.clicks, 0, "the grid doesn't select or drag from a star")
        click(CGPoint(x: layout.thumbnailArea.midX, y: layout.thumbnailArea.midY))
        XCTAssertEqual(clicked, [4])
        XCTAssertEqual(behind.clicks, 1, "a click on the picture still reaches the grid")
    }

    func testCellReadsTagsAndOffersRatingsAsActions() throws {
        let cell = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 176, height: 210))
        cell.setMarks(name: "c.NEF", rating: 3, flag: 0, isEdited: false)
        cell.setTags(stored: FinderTag.encode([FinderTag(name: "Red", colorIndex: 6), FinderTag(name: "Work", colorIndex: 0)]))
        XCTAssertEqual(cell.accessibilityLabel(), "c.NEF, 3 stars, tagged Red, Work")
        XCTAssertTrue(cell.subviews.allSatisfy { !$0.isAccessibilityElement() }, "still one element")
        XCTAssertNil(cell.accessibilityCustomActions(), "no actions without a grid to rate through")

        var clicked: [Int] = []
        cell.onRate = { clicked.append($0) }
        let actions = try XCTUnwrap(cell.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Clear rating", "Rate 1 star", "Rate 2 stars", "Rate 3 stars",
                                             "Rate 4 stars", "Rate 5 stars"])
        _ = actions[5].handler?()
        _ = actions[3].handler?()   // already 3: nothing to click
        _ = actions[0].handler?()   // clearing is a click on the current rating
        XCTAssertEqual(clicked, [5, 3])

        cell.setTags(stored: nil)
        XCTAssertEqual(cell.accessibilityLabel(), "c.NEF, 3 stars")
    }

    func testDropTargets() {
        let shown = ["a", "b"]
        XCTAssertEqual(GridDragAndDrop.target(before: 0, in: shown), "a")
        XCTAssertEqual(GridDragAndDrop.target(before: 1, in: shown), "b")
        XCTAssertNil(GridDragAndDrop.target(before: 2, in: shown), "after the last image")
        let collection = NSCollectionView()
        GridDragAndDrop.configure(collection)
        XCTAssertTrue(collection.registeredDraggedTypes.contains(.fileURL))
    }

    func testSortIsSavedAndRestored() throws {
        let suite = "latent-tests-sort-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = LibrarySortDefaults.attached(to: Library(), defaults: defaults)
        XCTAssertEqual(first.sort, .default)
        first.chooseSortKey(.fileName)
        first.sort.ascending = false
        first.chooseSortKey(.custom)

        let second = LibrarySortDefaults.attached(to: Library(), defaults: defaults)
        XCTAssertEqual(second.sort, LibrarySort(key: .custom, ascending: true))
        second.chooseSortKey(.fileName)
        XCTAssertEqual(second.sort, LibrarySort(key: .fileName, ascending: false), "the direction came back too")
    }
}

private final class ClickRecorder: NSView {
    var clicks = 0
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}
