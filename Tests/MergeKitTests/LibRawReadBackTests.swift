import XCTest
import RawCore
@testable import MergeKit

/// The vendored LibRaw reading a merge's DNG back through RawCore, in
/// process. What today's RawCore can open: metadata only, since decoding
/// three-sample float data arrives with the linear-source work (see
/// LibRawPixelRoundTripTests for the pixel half).
final class LibRawReadBackTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws { folder = try Fixtures.temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testLibRawReadsTheMetadataBack() throws {
        let (width, height) = (320, 200)
        var metadata = try Fixtures.metadata(baselineExposure: -1)
        metadata.orientation = 8
        var writer = LinearRawDNGWriter(tileSize: 128)
        writer.availableCapacity = { _ in nil }
        let result = try writer.write(
            .buffer(Fixtures.pixels(width: width, height: height, maximum: 4), width: width, height: height),
            maximum: 4, metadata: metadata, recipe: Fixtures.recipe(), preview: Fixtures.previewImage(),
            to: folder.appendingPathComponent("libraw.dng"))

        let descriptor = open(result.url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let file = try RawFile(fileDescriptor: descriptor, metadataOnly: true)
        let s = file.summary
        XCTAssertEqual(s.cameraMake, "Nikon")
        XCTAssertEqual(s.cameraModel, "D750")
        XCTAssertEqual([s.width, s.height], [width, height])
        XCTAssertEqual(s.iso, 100)
        XCTAssertEqual(s.shutter, 1.0 / 250, accuracy: 1e-9)
        XCTAssertEqual(s.aperture, 8, accuracy: 1e-6)
        XCTAssertEqual(s.focalLength, 35, accuracy: 1e-6)
        XCTAssertEqual(s.orientation, 5, "TIFF orientation 8 is LibRaw's flip 5")
        XCTAssertEqual(s.lensModel, "AF-S NIKKOR 24-70mm f/2.8E ED VR")

        // LibRaw's cam_mul is AsShotNeutral inverted: the D750 multipliers back.
        let m = s.cameraMultipliers
        XCTAssertEqual(m.0 / m.1, Fixtures.d750Multipliers[0], accuracy: 1e-4)
        XCTAssertEqual(m.2 / m.1, Fixtures.d750Multipliers[2], accuracy: 1e-4)
        let matrix = try XCTUnwrap(file.cameraToXYZMatrixRaw)
        for (read, written) in zip(matrix, Fixtures.d750CamXYZ) { XCTAssertEqual(read, written, accuracy: 1e-4) }
        XCTAssertEqual(s.blackLevel, 0)
    }
}
