import XCTest
@testable import Catalog

/// Where the stars, badges and tag dots sit under a grid thumbnail.
final class GridCellMarksLayoutTests: XCTestCase {
    func testMarksFitEveryCellSize() {
        for side in stride(from: ThumbnailGridLayout.sizeRange.lowerBound, through: ThumbnailGridLayout.sizeRange.upperBound,
                           by: ThumbnailGridLayout.sizeStep) {
            let layout = ThumbnailGridLayout(side: side)
            let item = CGRect(origin: .zero, size: layout.itemSize)
            XCTAssertTrue(item.contains(layout.starsFrame), "\(side)")
            XCTAssertEqual(layout.starsFrame.maxX, layout.thumbnailArea.maxX, "stars end with the thumbnail")
            XCTAssertLessThanOrEqual(layout.flagBadgeFrame.maxX, layout.starsFrame.minX, "badges never under the stars")
            XCTAssertGreaterThanOrEqual(layout.flagBadgeFrame.width, 20, "room for ✎ and a flag at \(side)")
            let dots = layout.tagDotsFrame(tagCount: 5)
            XCTAssertEqual(dots.width, 18, "three dots at most")
            XCTAssertLessThanOrEqual(layout.nameFrame(tagCount: 5).maxX, dots.minX)
            XCTAssertEqual(dots.maxX, layout.nameFrame.maxX)
            XCTAssertGreaterThanOrEqual(dots.minY, layout.nameFrame.minY)
            XCTAssertEqual(layout.nameFrame(tagCount: 0), layout.nameFrame, "no tags, full width name")
        }
    }

    func testStarHitsAndClickRule() {
        XCTAssertNil(ThumbnailGridLayout.star(atX: -1))
        XCTAssertEqual(ThumbnailGridLayout.star(atX: 0), 1)
        XCTAssertEqual(ThumbnailGridLayout.star(atX: 9.9), 1)
        XCTAssertEqual(ThumbnailGridLayout.star(atX: 10), 2)
        XCTAssertEqual(ThumbnailGridLayout.star(atX: 49.9), 5)
        XCTAssertNil(ThumbnailGridLayout.star(atX: 50))
        XCTAssertEqual(ThumbnailGridLayout.rating(afterClicking: 3, current: 0), 3)
        XCTAssertEqual(ThumbnailGridLayout.rating(afterClicking: 3, current: 3), 0, "the current rating clears")
        XCTAssertEqual(ThumbnailGridLayout.rating(afterClicking: 1, current: 4), 1)
    }
}
