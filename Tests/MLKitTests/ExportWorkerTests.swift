import XCTest
import ImageIO
@testable import MLKit
@testable import PixelEngine
@testable import RawCore
import ColorKit

final class ExportWorkerTests: XCTestCase {
    func testResizedHEICWithEditAndMetadata() async throws {
        let path = AIMaskTests.assetPath("HSB_2615.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rawhead-export-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: out) }

        var p = EditParameters(); p.exposureEV = 1
        let json = try EditStack(parameters: p).encodeJSON()
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: json,
            userRotation: 1, settings: ExportSettings(format: .heic, quality: 0.85),
            colorSpace: .displayP3, maxLongEdge: 1600, keywords: ["test", "d750"], rating: 4)
        let outcome = try await ExportWorker.export(request, gpu: gpu)
        print(String(format: "EXPORT %dx%d in %.0f ms", outcome.pixelWidth, outcome.pixelHeight, outcome.seconds * 1000))

        // Portrait file rotated one more turn: long edge 1600, and it's
        // the *width* now (camera portrait + 90° = landscape).
        XCTAssertEqual(max(outcome.pixelWidth, outcome.pixelHeight), 1600)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.heic")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, outcome.pixelWidth)
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "D750")
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first, 200)
        XCTAssertEqual(exif[kCGImagePropertyExifFNumber] as? Double ?? 0, 5.0, accuracy: 0.01)
        let iptc = try XCTUnwrap(props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords] as? [String], ["test", "d750"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCStarRating] as? Int, 4)
        // Colour space tag survives.
        let space = props[kCGImagePropertyProfileName] as? String ?? ""
        XCTAssertTrue(space.lowercased().contains("p3"), "profile: \(space)")
    }

    func testFullSizeTIFFKeeps16BitsAndRegeneratesAIMask() async throws {
        let path = AIMaskTests.assetPath("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        try XCTSkipUnless(SegmentationModel.isAvailable)
        let gpu = try GPUContext()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rawhead-export-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: out) }

        var p = EditParameters()
        p.locals = [LocalAdjustment(name: "sky", shape: .ai(kind: "sky", modelVersion: SegmentationModel.modelVersion), exposureEV: -1)]
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: out,
            editStackJSON: try EditStack(parameters: p).encodeJSON(), userRotation: 0,
            settings: ExportSettings(format: .tiff), colorSpace: .sRGB, maxLongEdge: nil)
        let outcome = try await ExportWorker.export(request, gpu: gpu)
        XCTAssertEqual(outcome.masksGenerated, 1)
        XCTAssertEqual(outcome.pixelWidth, 6032)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 16)
    }
}
