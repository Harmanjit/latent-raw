import XCTest
@testable import Catalog

final class ExportSizeEstimateTests: XCTestCase {
    func testOutputPixelsFitTheLongEdgeWithoutEnlarging() {
        XCTAssertEqual(ExportSizeEstimate.outputPixels(width: 6000, height: 4000, maxLongEdge: 2048), 2048 * 1365)
        XCTAssertEqual(ExportSizeEstimate.outputPixels(width: 4000, height: 6000, maxLongEdge: 3000), 2000 * 3000)
        XCTAssertEqual(ExportSizeEstimate.outputPixels(width: 1000, height: 800, maxLongEdge: 2048), 800_000)
        XCTAssertEqual(ExportSizeEstimate.outputPixels(width: 6000, height: 4000, maxLongEdge: nil), 24_000_000)
        XCTAssertNil(ExportSizeEstimate.outputPixels(width: nil, height: 4000, maxLongEdge: nil))
        XCTAssertNil(ExportSizeEstimate.outputPixels(width: 0, height: 4000, maxLongEdge: nil))
    }

    func testBatchExtrapolatesBytesPerPixel() {
        // The sample: 10 MB for 20 MP (a cropped 24 MP image), half a byte a pixel.
        let one = ExportSizeEstimate.totalBytes(sampleBytes: 10_000_000, samplePixels: 20_000_000, others: [],
                                                maxLongEdge: nil)
        XCTAssertEqual(one, 10_000_000, "one image is its own encode")
        let batch = ExportSizeEstimate.totalBytes(
            sampleBytes: 10_000_000, samplePixels: 20_000_000,
            others: [(6000, 4000), (3000, 2000), (nil, nil)], maxLongEdge: nil)
        XCTAssertEqual(batch, 10_000_000 + 12_000_000 + 3_000_000 + 10_000_000)
        let resized = ExportSizeEstimate.totalBytes(
            sampleBytes: 1_000_000, samplePixels: 2_000_000, others: [(6000, 4000)], maxLongEdge: 2000)
        XCTAssertEqual(resized, 1_000_000 + 2000 * 1333 / 2)
    }
}
