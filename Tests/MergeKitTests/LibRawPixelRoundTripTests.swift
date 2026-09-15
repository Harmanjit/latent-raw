import XCTest
import RawCore
@testable import MergeKit

/// The pixel half of the LibRaw round trip: a merge's DNG, opened through
/// `RawFile` like any photo, must give back every half float the writer
/// stored, plus the colour, exposure and XMP metadata.
///
/// TODO(Photo Merge phase 1/2 merge): today's RawCore can't decode
/// three-sample float DNGs, so the real test is compiled only with the
/// LATENT_LINEAR_SOURCE flag. Once the linear-source branch lands (RawFile
/// float planes, `CFAPattern.linearRGB`, `LinearPlane`), adapt the names
/// below to its API, then either delete the `#if` or add
/// `swiftSettings: [.define("LATENT_LINEAR_SOURCE")]` to MergeKitTests in
/// Package.swift. The placeholder in the `#else` branch keeps the gap
/// visible in every test run until then.
final class LibRawPixelRoundTripTests: XCTestCase {
#if LATENT_LINEAR_SOURCE
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
        let plane = try XCTUnwrap(file.linearPlane)               // RGBA half floats (adapt to the real API)
        XCTAssertEqual([plane.width, plane.height], [width, height])
        let expected = pixels.map { $0 / 16 }                     // 12 fits under 2^4
        plane.withHalfFloats { rgba in
            for i in 0..<(width * height) {
                for c in 0..<3 {
                    XCTAssertEqual(rgba[i * 4 + c].bitPattern, expected[i * 3 + c].bitPattern, "sample \(i).\(c)")
                }
            }
        }
        XCTAssertEqual(file.baselineExposure, 2, accuracy: 1e-6) // -2 + 4 (adapt to the real API)
        XCTAssertEqual(try MergeXMP.recipe(fromXMP: XCTUnwrap(file.xmpPacket)), result.recipe)
        let m = file.summary.cameraMultipliers
        XCTAssertEqual(m.0 / m.1, Fixtures.d750Multipliers[0], accuracy: 1e-4)
    }
#else
    func testRawFileReadsEveryStoredHalfFloat() throws {
        throw XCTSkip("TODO: needs RawFile float planes from the linear-source branch; "
            + "build with LATENT_LINEAR_SOURCE (see LibRawPixelRoundTripTests.swift)")
    }
#endif
}
