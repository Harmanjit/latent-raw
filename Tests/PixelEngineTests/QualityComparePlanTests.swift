import XCTest
@testable import PixelEngine

final class QualityComparePlanTests: XCTestCase {
    func testDefaultQualitiesIncludeTheChosenOne() {
        XCTAssertEqual(QualityComparePlan.defaultQualities(chosen: 0.92, count: 3), [0.72, 0.82, 0.92])
        XCTAssertEqual(QualityComparePlan.defaultQualities(chosen: 0.92, count: 2), [0.82, 0.92])
        XCTAssertEqual(QualityComparePlan.defaultQualities(chosen: 0.35, count: 4), [0.35, 0.4, 0.45, 0.5])
        XCTAssertEqual(QualityComparePlan.defaultQualities(chosen: 1, count: 4), [0.7, 0.8, 0.9, 1])
        XCTAssertEqual(QualityComparePlan.defaultQualities(chosen: 0.5, count: 9).count, 4)
    }

    func testTileStartsOnTheBlockGridAndCoversTheView() {
        let view = CGSize(width: 500, height: 300)
        let center = CGPoint(x: 1000, y: 700)
        let tile = QualityComparePlan.tile(center: center, view: view, imageWidth: 6000, imageHeight: 4000, margin: 100)
        XCTAssertEqual(Int(tile.minX) % 64, 0)
        XCTAssertEqual(Int(tile.minY) % 64, 0)
        XCTAssertEqual(Int(tile.maxX) % 64, 0)
        XCTAssertTrue(tile.contains(QualityComparePlan.visibleRect(center: center, view: view)))
        XCTAssertTrue(QualityComparePlan.covers(tile, center: center, view: view, imageWidth: 6000, imageHeight: 4000))
        XCTAssertTrue(QualityComparePlan.covers(tile, center: CGPoint(x: 1090, y: 700), view: view,
                                                imageWidth: 6000, imageHeight: 4000), "within the margin")
        XCTAssertFalse(QualityComparePlan.covers(tile, center: CGPoint(x: 1300, y: 700), view: view,
                                                 imageWidth: 6000, imageHeight: 4000))
    }

    func testTileIsClippedToTheImage() {
        let tile = QualityComparePlan.tile(center: CGPoint(x: 990, y: 20), view: CGSize(width: 400, height: 400),
                                           imageWidth: 1000, imageHeight: 700)
        XCTAssertEqual(tile.minY, 0)
        XCTAssertEqual(tile.maxX, 1000, "the image's own edge, off the grid")
        XCTAssertEqual(Int(tile.minX) % 64, 0)
        let small = QualityComparePlan.tile(center: CGPoint(x: 50, y: 40), view: CGSize(width: 800, height: 800),
                                            imageWidth: 100, imageHeight: 80)
        XCTAssertEqual(small, CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testCenterKeepsTheViewOverTheImage() {
        let view = CGSize(width: 400, height: 300)
        XCTAssertEqual(QualityComparePlan.clampedCenter(CGPoint(x: -50, y: 5000), view: view, imageWidth: 2000, imageHeight: 1000),
                       CGPoint(x: 200, y: 850))
        XCTAssertEqual(QualityComparePlan.clampedCenter(CGPoint(x: 10, y: 10), view: view, imageWidth: 300, imageHeight: 1000),
                       CGPoint(x: 150, y: 150))
    }
}
