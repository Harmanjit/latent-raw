import XCTest
@testable import Catalog

final class MetadataFormatTests: XCTestCase {
    func testShutterBelowOneSecondIsAReciprocal() {
        XCTAssertEqual(MetadataFormat.shutter(1.0 / 250), "1/250 s")
        XCTAssertEqual(MetadataFormat.shutter(1.0 / 8000), "1/8000 s")
        // Thirds are how cameras step; float noise must not leak through.
        XCTAssertEqual(MetadataFormat.shutter(0.33333), "1/3 s")
        XCTAssertEqual(MetadataFormat.shutter(0.5), "1/2 s")
    }

    func testShutterAtOrAboveOneSecond() {
        XCTAssertEqual(MetadataFormat.shutter(1), "1 s")
        XCTAssertEqual(MetadataFormat.shutter(2.5), "2.5 s")
        XCTAssertEqual(MetadataFormat.shutter(30), "30 s")
        XCTAssertEqual(MetadataFormat.shutter(0), "—")
    }

    func testApertureDropsZeroDecimal() {
        XCTAssertEqual(MetadataFormat.aperture(2.8), "ƒ/2.8")
        XCTAssertEqual(MetadataFormat.aperture(8), "ƒ/8")
        XCTAssertEqual(MetadataFormat.aperture(1.8000001), "ƒ/1.8")
        XCTAssertEqual(MetadataFormat.aperture(0), "—")
    }

    func testFocalLength() {
        XCTAssertEqual(MetadataFormat.focalLength(50), "50 mm")
        XCTAssertEqual(MetadataFormat.focalLength(24.5), "24.5 mm")
    }

    func testDimensionsAndMegapixels() {
        XCTAssertEqual(MetadataFormat.dimensions(width: 6016, height: 4016), "6016 × 4016 (24.2 MP)")
        XCTAssertEqual(MetadataFormat.dimensions(width: 0, height: 4016), "—")
    }

    func testExposureLineSkipsMissingValues() {
        XCTAssertEqual(MetadataFormat.exposureLine(shutter: 1.0 / 250, aperture: 2.8, iso: 400, focal: 50),
                       "1/250 s · ƒ/2.8 · ISO 400 · 50 mm")
        XCTAssertEqual(MetadataFormat.exposureLine(shutter: nil, aperture: 4, iso: nil, focal: nil), "ƒ/4")
        XCTAssertEqual(MetadataFormat.exposureLine(shutter: nil, aperture: nil, iso: nil, focal: nil), "")
    }

    func testCaptureTimeUsesGivenTimeZone() {
        // 2026-09-13 17:41:00 UTC
        let s = MetadataFormat.captureTime(1_789_321_260, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(s.contains("2026"), s)
        XCTAssertTrue(s.contains("17:41") || s.contains("5:41"), s)
    }

    func testRecordRowsOmitUnknowns() {
        var record = ImageRecord(
            id: nil, relPath: "a.nef", preservedName: nil, size: 24_300_000, mtime: 0,
            xxhash: Data(count: 8), captureTime: nil, camera: "Nikon D750", lens: nil,
            lensId: nil, iso: 400, shutter: 1.0 / 250, aperture: nil, focal: 50,
            width: 6016, height: 4016, orientation: 1, rating: 0, label: nil, flag: 0,
            sidecarMtime: nil, thumbKey: nil)
        let labels = record.metadataRows.map(\.label)
        XCTAssertEqual(labels, ["Camera", "Shutter", "ISO", "Focal length", "Size", "File"])
        XCTAssertEqual(record.exposureLine, "1/250 s · ISO 400 · 50 mm")

        record.aperture = 2.8
        XCTAssertTrue(record.metadataRows.map(\.label).contains("Aperture"))
    }
}
