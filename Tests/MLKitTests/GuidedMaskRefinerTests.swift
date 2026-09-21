import XCTest
import CoreGraphics
@testable import MLKit
@testable import PixelEngine

/// The guided filter that sharpens a coarse mask against the picture
/// (docs/Retouch.md §5), on pictures made here.
final class GuidedMaskRefinerTests: XCTestCase {
    /// A mask blurred across a sharp edge in the guide snaps to the edge.
    /// The blur must be of the filter's own scale (a model's soft edge of
    /// a pixel or two, upsampled: here two coarse pixels, 16 in the
    /// guide, against a radius of 8); the fit is local, so a ramp many
    /// times wider than the window keeps most of its width. Beside the
    /// edge the refined mask jumps where the bilinear upsample creeps, and
    /// away from it both sides are fully on and off.
    func testStepEdgeSharpensAgainstTheGuide() {
        let size = 256
        let guide = SyntheticImage.make(width: size, height: size) { x, _ in
            x < 128 ? (51, 51, 51) : (204, 204, 204)
        }
        // A 32² mask: on up to x = 15, half at 16, off from 17.
        var coarse = [UInt8](repeating: 0, count: 32 * 32)
        for y in 0..<32 {
            for x in 0..<32 { coarse[y * 32 + x] = x < 16 ? 255 : (x == 16 ? 128 : 0) }
        }
        let mask = MaskBitmap(width: 32, height: 32, data: coarse)
        let refined = GuidedMaskRefiner.refine(mask, guide: guide)
        let bilinear = mask.resampled(width: size, height: size)
        XCTAssertEqual(refined.width, size)
        XCTAssertEqual(refined.height, size)

        let row = 128 * size
        // Across the three pixels round the edge the bilinear ramp moves
        // about 49 (its slope is 127 per 8 px); the refined mask makes
        // most of its jump right there.
        func jump(_ m: MaskBitmap) -> Int { Int(m.data[row + 126]) - Int(m.data[row + 129]) }
        print("GUIDED beside the edge: refined \(refined.data[row + 126]) → \(refined.data[row + 129]), " +
              "bilinear \(bilinear.data[row + 126]) → \(bilinear.data[row + 129])")
        XCTAssertGreaterThan(jump(refined), 100, "the refined mask steps with the guide")
        XCTAssertGreaterThan(jump(refined), 2 * jump(bilinear), "the bilinear upsample creeps across it")
        XCTAssertGreaterThan(refined.data[row + 100], 240, "28 px inside the dark side: on")
        XCTAssertLessThan(refined.data[row + 156], 15, "28 px into the bright side: off")
        XCTAssertGreaterThan(refined.data[row + 125], refined.data[row + 130])
        // Nothing happens along the edge: every row is the same.
        for y in [10, 64, 200, 250] {
            XCTAssertEqual(refined.data[y * size + 125], refined.data[row + 125])
            XCTAssertEqual(refined.data[y * size + 130], refined.data[row + 130])
        }
    }

    /// With nothing to follow in the guide the fit is a constant, so a
    /// gradient mask comes back as itself (box means of a ramp are the
    /// ramp, away from the borders).
    func testFlatGuideKeepsTheMask() {
        let size = 128
        let guide = SyntheticImage.make(width: size, height: size) { _, _ in (128, 128, 128) }
        var coarse = [UInt8](repeating: 0, count: 16 * 16)
        for y in 0..<16 { for x in 0..<16 { coarse[y * 16 + x] = UInt8(x * 17) } }
        let mask = MaskBitmap(width: 16, height: 16, data: coarse)
        let refined = GuidedMaskRefiner.refine(mask, guide: guide)
        let bilinear = mask.resampled(width: size, height: size)
        for y in stride(from: 20, to: size - 20, by: 9) {
            for x in stride(from: 20, to: size - 20, by: 7) {
                XCTAssertEqual(Int(refined.data[y * size + x]), Int(bilinear.data[y * size + x]), accuracy: 3, "(\(x), \(y))")
            }
        }
    }

    /// The box filter: a constant stays put, an impulse spreads evenly
    /// over its window, and a window at the corner shrinks to fit.
    func testBoxFilterMeans() {
        let width = 40, height = 30, r = 3
        let flat = [Float](repeating: 0.25, count: width * height)
        for v in GuidedMaskRefiner.boxFiltered(flat, width: width, height: height, radius: r) {
            XCTAssertEqual(v, 0.25, accuracy: 1e-6)
        }
        var impulse = [Float](repeating: 0, count: width * height)
        impulse[15 * width + 20] = 1
        let spread = GuidedMaskRefiner.boxFiltered(impulse, width: width, height: height, radius: r)
        let window = Float((2 * r + 1) * (2 * r + 1))
        XCTAssertEqual(spread[15 * width + 20], 1 / window, accuracy: 1e-6)
        XCTAssertEqual(spread[(15 + r) * width + (20 - r)], 1 / window, accuracy: 1e-6)
        XCTAssertEqual(spread[(15 + r + 1) * width + 20], 0, accuracy: 1e-6)
        XCTAssertEqual(spread.reduce(0, +), 1, accuracy: 1e-4, "the mean filter conserves the sum away from the edges")
        var corner = [Float](repeating: 0, count: width * height)
        corner[0] = 1
        let shrunk = GuidedMaskRefiner.boxFiltered(corner, width: width, height: height, radius: r)
        XCTAssertEqual(shrunk[0], 1 / Float((r + 1) * (r + 1)), accuracy: 1e-6)
    }

    /// The guide's luminance is read the right way up.
    func testLuminanceIsTopLeftOrigin() throws {
        let image = SyntheticImage.make(width: 4, height: 2) { _, y in y == 0 ? (255, 255, 255) : (0, 0, 0) }
        let luminance = try XCTUnwrap(GuidedMaskRefiner.luminance(of: image))
        XCTAssertEqual(luminance.count, 8)
        XCTAssertEqual(luminance[0], 1, accuracy: 0.01)
        XCTAssertEqual(luminance[7], 0, accuracy: 0.01)
    }
}
