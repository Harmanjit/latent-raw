import XCTest
import RawCore
@testable import MergeKit

/// The pixel half of the LibRaw round trip: a merge's DNG, opened through
/// `RawFile` like any photo, must give back every half float the writer
/// stored, plus the colour, exposure and XMP metadata.
final class LibRawPixelRoundTripTests: XCTestCase {
    func testRawFileReadsEveryStoredHalfFloat() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Odd size and 512 px tiles, so edge tiles are padded.
        let (width, height) = (1031, 517)
        let pixels = Fixtures.pixels(width: width, height: height, maximum: 12)
        var writer = LinearRawDNGWriter()
        writer.availableCapacity = { _ in nil }
        let result = try writer.write(.buffer(pixels, width: width, height: height), maximum: 12,
                                      metadata: Fixtures.metadata(baselineExposure: -2), recipe: Fixtures.recipe(),
                                      preview: Fixtures.previewImage(), to: folder.appendingPathComponent("rt.dng"))

        let file = try RawFile(path: result.url.path)
        guard case .linearRGB = file.summary.cfaPattern else { return XCTFail("not opened as a linear source") }
        let plane = try XCTUnwrap(file.linearPlane)               // RGBA half floats
        XCTAssertEqual([plane.width, plane.height], [width, height])
        let expected = pixels.map { $0 / 16 }                     // 12 fits under 2^4
        let rgba = plane.samples
        var mismatches = 0
        for i in 0..<(width * height) {
            for c in 0..<3 where rgba[i * 4 + c].bitPattern != expected[i * 3 + c].bitPattern {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "samples that didn't come back bit-exact")
        XCTAssertEqual(file.summary.baselineExposure, 2, accuracy: 1e-6) // -2 + 4
        let info = try XCTUnwrap(file.summary.mergeInfo)
        XCTAssertEqual(info.kind, result.recipe.kind.rawValue)
        XCTAssertEqual(info.clipLevel, result.recipe.clipLevel, accuracy: 1e-6)
        XCTAssertEqual(info.lensApplied, result.recipe.lensApplied)
        XCTAssertEqual(info.baselineShift, result.recipe.baselineShift)
        let m = file.summary.cameraMultipliers
        XCTAssertEqual(m.0 / m.1, Fixtures.d750Multipliers[0], accuracy: 1e-4)
    }

    /// LibRaw misreads a tiled float DNG smaller than one tile, so the
    /// writer shrinks the tile for small images; this one is 300 x 90.
    func testSmallImageSmallerThanOneTileReadsBack() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (width, height) = (300, 90)
        let pixels = Fixtures.pixels(width: width, height: height, maximum: 1)
        var writer = LinearRawDNGWriter()
        writer.availableCapacity = { _ in nil }
        let result = try writer.write(.buffer(pixels, width: width, height: height), maximum: 1,
                                      metadata: Fixtures.metadata(baselineExposure: 0), recipe: Fixtures.recipe(),
                                      preview: Fixtures.previewImage(), to: folder.appendingPathComponent("small.dng"))
        let file = try RawFile(path: result.url.path)
        let plane = try XCTUnwrap(file.linearPlane)
        XCTAssertEqual([plane.width, plane.height], [width, height])
        let rgba = plane.samples
        var mismatches = 0
        for i in 0..<(width * height) {
            for c in 0..<3 where rgba[i * 4 + c].bitPattern != pixels[i * 3 + c].bitPattern { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(LinearRawDNGWriter.tileSize(512, width: width, height: height), 80)
    }
}
