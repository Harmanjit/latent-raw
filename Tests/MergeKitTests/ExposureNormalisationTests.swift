import XCTest
@testable import MergeKit

final class ExposureNormalisationTests: XCTestCase {
    func testShiftIsTheSmallestPowerOfTwoThatFits() throws {
        let cases: [(Float, Int)] = [
            (0, 0), (-3, 0), (0.25, 0), (1, 0),               // already fits, including exactly 1.0
            (Float(1).nextUp, 1), (1.5, 1), (2, 1),           // just over 1 needs a stop; exactly 2 needs only 1
            (2.0001, 2), (3, 2), (4, 2), (4.0001, 3),
            (64, 6), (100, 7), (128, 7), (129, 8),
            (65504, 16),                                      // the largest half float
            (Float.leastNonzeroMagnitude, 0),
        ]
        for (maximum, shift) in cases {
            XCTAssertEqual(try ExposureNormalisation.shift(forMaximum: maximum), shift, "maximum \(maximum)")
            let n = try ExposureNormalisation(maximum: maximum)
            XCTAssertLessThanOrEqual(n.stored(maximum), 1, "maximum \(maximum) fits")
            if shift > 0 { XCTAssertGreaterThan(maximum * 2 * n.scale, 1, "one stop fewer wouldn't fit") }
        }
    }

    func testNonFiniteMaximumThrows() {
        for bad in [Float.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ExposureNormalisation(maximum: bad)) { error in
                guard case MergeDNGError.invalidMaximum = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testBaselineExposureGainsTheShift() throws {
        let n = try ExposureNormalisation(maximum: 100)
        XCTAssertEqual(n.shift, 7)
        XCTAssertEqual(n.scale, 1.0 / 128)
        XCTAssertEqual(n.storedBaselineExposure(-1.585), -1.585 + 7, accuracy: 1e-12)
        XCTAssertEqual(n.stored(128), 1)
        XCTAssertEqual(ExposureNormalisation(shift: -2).shift, 0, "never multiplies up")
    }

    func testCPUMaximumIgnoresAlphaAndReportsNaN() {
        XCTAssertEqual(ExposureNormalisation.maximum(of: [0.5, 3, 1, 9] as [Float16], channelsPerPixel: 4), 3)
        XCTAssertEqual(ExposureNormalisation.maximum(of: [0.5, 2, 1, 7, 0, 0] as [Float16]), 7)
        XCTAssertEqual(ExposureNormalisation.maximum(of: [] as [Float16]), 0)
        XCTAssertEqual(ExposureNormalisation.maximum(of: [-1, -2, -3] as [Float16]), 0)
        XCTAssertTrue(ExposureNormalisation.maximum(of: [0.5, .nan, 1] as [Float16]).isNaN)
        XCTAssertEqual(ExposureNormalisation.maximum(of: [0.5, .infinity, 1] as [Float16]), .infinity)
    }

    func testRecipeNormalisationRescalesClipLevel() throws {
        let recipe = Fixtures.recipe(clipLevel: 128)
        let stored = recipe.normalised(by: try ExposureNormalisation(maximum: 128))
        XCTAssertEqual(stored.clipLevel, 1)
        XCTAssertEqual(stored.baselineShift, 7)
        XCTAssertEqual(stored.sources, recipe.sources)
    }
}
