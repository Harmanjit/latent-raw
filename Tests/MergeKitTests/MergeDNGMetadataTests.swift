import XCTest
import RawCore
@testable import MergeKit

final class MergeDNGMetadataTests: XCTestCase {
    /// A RawSummary as the decoder service would send it (RawSummary has no
    /// public initialiser; its wire form does).
    private func summary(multipliers: [Float] = [2.078125, 1, 1.207031, 0], flip: Int = 6,
                         lensModel: String = "NIKKOR Z 24-70mm f/4 S", timestamp: Int64 = 1_789_498_800) throws -> RawSummary {
        let json: [String: Any] = [
            "width": 6048, "height": 4024, "leftMargin": 0, "topMargin": 0, "rawWidth": 6064, "rawHeight": 4040,
            "cfaCode": 0x94, "cameraMultipliers": multipliers, "blackLevel": 600, "whiteLevel": 15520,
            "cameraMake": "Nikon", "cameraModel": "Z 6_2", "lensModel": lensModel,
            "iso": 400, "shutter": 1.0 / 60, "aperture": 4, "focalLength": 24, "timestamp": timestamp,
            "orientation": flip, "lensMake": "Nikon", "lensMakerNotesName": "", "makerLensID": 0,
            "nikonLensID": 0, "nikonLensType": 0, "minFocal": 24, "maxFocal": 70,
            "maxApertureAtMinFocal": 4, "maxApertureAtMaxFocal": 4, "cropFactor": 1,
            "thumbnailError": 0, "isMetadataOnly": true, "planeSampleCount": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(RawSnapshotMetadata.self, from: data).summary
    }

    func testInitialisesFromARawSummary() throws {
        let m = try MergeDNGMetadata(summary: summary(), cameraToXYZ: Fixtures.d750CamXYZ + [0, 0, 0],
                                     softwareVersion: "1.2", baselineExposure: -1.25)
        XCTAssertEqual(m.make, "Nikon")
        XCTAssertEqual(m.model, "Z 6_2")
        XCTAssertEqual(m.uniqueCameraModel, "Nikon Z 6_2")
        XCTAssertEqual(m.colorMatrix1.count, 9, "the 4th row of a 4x3 cam_xyz is dropped")
        XCTAssertEqual(m.colorMatrix1[0], 0.902, accuracy: 1e-6)
        XCTAssertEqual(m.asShotNeutral[0], 1 / 2.078125, accuracy: 1e-9)
        XCTAssertEqual(m.asShotNeutral[1], 1)
        XCTAssertEqual(m.baselineExposure, -1.25)
        XCTAssertEqual(m.orientation, 6)
        XCTAssertEqual(m.software, "Latent 1.2")
        XCTAssertEqual(m.captureDate, Date(timeIntervalSince1970: 1_789_498_800))
        XCTAssertEqual(m.exposureTime, 1.0 / 60)
        XCTAssertEqual(m.fNumber, 4)
        XCTAssertEqual(m.iso, 400)
        XCTAssertEqual(m.focalLength, 24)
        XCTAssertEqual(m.lensMake, "Nikon")
        XCTAssertEqual(m.lensModel, "NIKKOR Z 24-70mm f/4 S")
        XCTAssertEqual(m.lensSpecification, .init(minFocalLength: 24, maxFocalLength: 70,
                                                  maxApertureAtMinFocal: 4, maxApertureAtMaxFocal: 4))
        XCTAssertNil(m.defaultCrop)
    }

    func testRefusesAReferenceWithoutColourOrWhiteBalance() throws {
        XCTAssertThrowsError(try MergeDNGMetadata(summary: summary(), cameraToXYZ: nil, softwareVersion: "1"))
        XCTAssertThrowsError(try MergeDNGMetadata(summary: summary(multipliers: [0, 0, 0, 0]),
                                                  cameraToXYZ: Fixtures.d750CamXYZ, softwareVersion: "1"))
        XCTAssertThrowsError(try MergeDNGMetadata.colorMatrix(fromCamXYZ: [Float](repeating: 0, count: 9)))
        XCTAssertThrowsError(try MergeDNGMetadata.colorMatrix(fromCamXYZ: [1, 2, 3]))
        XCTAssertThrowsError(try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: [1, .nan, 1]))
    }

    func testMissingValuesAreLeftOut() throws {
        let m = try MergeDNGMetadata(summary: summary(lensModel: "", timestamp: 0),
                                     cameraToXYZ: Fixtures.d750CamXYZ, softwareVersion: "")
        XCTAssertNil(m.lensModel)
        XCTAssertNil(m.captureDate)
        XCTAssertEqual(m.software, "Latent")
    }

    func testOrientationIsLibRawsTableInverted() {
        // LibRaw: flip = "50132467"[tiffOrientation & 7] - '0'.
        let table = Array("50132467").map { Int(String($0))! }
        for tiff in 1...8 {
            XCTAssertEqual(MergeDNGMetadata.tiffOrientation(libRawFlip: table[tiff & 7]), UInt16(tiff), "TIFF \(tiff)")
        }
    }

    func testUniqueCameraModel() {
        XCTAssertEqual(MergeDNGMetadata.uniqueCameraModel(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertEqual(MergeDNGMetadata.uniqueCameraModel(make: "FUJIFILM", model: "X-T5"), "FUJIFILM X-T5")
        XCTAssertEqual(MergeDNGMetadata.uniqueCameraModel(make: "Sony", model: ""), "Sony")
        XCTAssertEqual(MergeDNGMetadata.uniqueCameraModel(make: "", model: ""), "Unknown camera")
    }

    func testExposureTimesReadLikeShutterSpeeds() {
        XCTAssertEqual(DNGTagValues.exposureTimeRational(1.0 / 8000), TIFFRational(1, 8000))
        XCTAssertEqual(DNGTagValues.exposureTimeRational(Double(Float(1.0 / 60))), TIFFRational(1, 60),
                       "a Float-rounded 1/60 is still 1/60")
        XCTAssertEqual(DNGTagValues.exposureTimeRational(0.3), TIFFRational(300_000, 1_000_000), "0.3 s isn't 1/3")
        XCTAssertEqual(DNGTagValues.exposureTimeRational(2.5), TIFFRational(2500, 1000))
        XCTAssertEqual(DNGTagValues.exposureTimeRational(30), TIFFRational(30_000, 1000))
        XCTAssertNil(DNGTagValues.exposureTimeRational(0))
    }

    func testEXIFDatesUseTheGivenZone() {
        let date = Date(timeIntervalSince1970: 1_789_498_800)
        XCTAssertEqual(DNGTagValues.exifDate(date, in: Fixtures.utc), "2026:09:15 19:00:00")
        XCTAssertEqual(DNGTagValues.exifDate(date, in: TimeZone(secondsFromGMT: 9 * 3600)!), "2026:09:16 04:00:00")
    }
}
