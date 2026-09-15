import XCTest
import RawCore
@testable import MergeKit

/// The synthetic brackets the HDR tests are built on must reach the merge
/// the way a camera's raws do: through LibRaw, as Bayer data, with the
/// black levels, white, colour and EXIF they were written with.
final class SyntheticBracketTests: XCTestCase {
    func testLibRawOpensTheSyntheticDNGAsABayerRaw() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = SyntheticBracket.scene(width: 240, height: 160)
        var frame = SyntheticBracket.Frame(exposure: 1, exifShutter: 1.0 / 60)
        frame.orientation = 6
        let url = try XCTUnwrap(SyntheticBracket.write([frame], of: scene, noise: false, to: folder).first)

        let file = try RawFile(path: url.path)
        let s = file.summary
        guard case .bayer(let order) = s.cfaPattern else { return XCTFail("not opened as Bayer: \(s.cfaPattern)") }
        XCTAssertEqual(order & 0x3, 0, "red at (0, 0)")
        XCTAssertEqual([s.width, s.height], [240, 160])
        XCTAssertEqual(s.cameraMake, SyntheticBracket.make)
        XCTAssertEqual(s.cameraModel, SyntheticBracket.model)
        XCTAssertEqual(s.whiteLevel, 15520)
        XCTAssertEqual(s.channelBlackLevels, SIMD4<Float>(600, 600, 640, 600))
        XCTAssertEqual(s.shutter, 1.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(s.iso, 100)
        XCTAssertEqual(s.aperture, 8, accuracy: 1e-6)
        XCTAssertEqual(s.orientation, 6)
        let m = s.cameraMultipliers
        XCTAssertEqual(m.0 / m.1, Fixtures.d750Multipliers[0], accuracy: 1e-3)
        XCTAssertEqual(m.2 / m.1, Fixtures.d750Multipliers[2], accuracy: 1e-3)
        let matrix = try XCTUnwrap(file.cameraToXYZMatrixRaw)
        for (got, want) in zip(matrix, Fixtures.d750CamXYZ) { XCTAssertEqual(got, want, accuracy: 1e-4) }

        // The photosites are the ones written: black plus the scene at exposure 1.
        let plane = try XCTUnwrap(file.rawSensorPlane())
        let expected = SyntheticBracket.photosites(of: scene, exposure: 1, noise: false, seed: 0)
        XCTAssertEqual(Array(plane.prefix(expected.count)), expected)
        XCTAssertEqual(s.dataMaximum, 15520, "the disc clips")
    }

    /// A sensor that saturates at 15520 while its file says white is
    /// 16383: a frame with a clipped plateau clips where the data does, and
    /// a frame whose brightest pixel merely falls short of white keeps the
    /// nominal white (its data maximum isn't a saturation level).
    func testSaturationBelowTheNominalWhite() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = HDRTestSupport.scene
        var clipped = SyntheticBracket.Frame(exposure: 1, exifShutter: 1.0 / 60)
        clipped.whiteLevelTag = 16383
        // At 1/128 the disc (radiance 64) reads 600 + 0.5 x 14000: nothing clips.
        var unclipped = SyntheticBracket.Frame(exposure: 1.0 / 128, exifShutter: 1.0 / 7680)
        unclipped.whiteLevelTag = 16383
        let urls = try SyntheticBracket.write([clipped, unclipped], of: scene, noise: true, to: folder)
        let gpu = try HDRTestSupport.gpu()

        let clippedFile = try RawFile(path: urls[0].path)
        XCTAssertEqual(clippedFile.summary.whiteLevel, 16383)
        XCTAssertEqual(clippedFile.summary.dataMaximum, 15520)
        XCTAssertEqual(try HDRMerger.levels(for: clippedFile, gpu: gpu).clipRaw, 0.98 * 15520, accuracy: 0.01)

        let unclippedFile = try RawFile(path: urls[1].path)
        XCTAssertLessThan(unclippedFile.summary.dataMaximum, 15520)
        XCTAssertEqual(try HDRMerger.levels(for: unclippedFile, gpu: gpu).clipRaw, 0.98 * 16383, accuracy: 0.01)
    }
}
