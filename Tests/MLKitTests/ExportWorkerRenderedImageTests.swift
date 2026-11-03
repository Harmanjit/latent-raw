import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MLKit
@testable import PixelEngine

/// Exporting a JPEG, PNG or TIFF: it goes through the same worker as a
/// raw, keeps its EXIF, and never gets an HDR gain map it has nothing for.
final class ExportWorkerRenderedImageTests: XCTestCase {
    func testAPictureExportsWithoutAGainMapAndKeepsItsEXIF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-export-formats-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let width = 120, height = 80
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = UInt8(i / 4 % 251); bytes[i + 2] = 40 }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let source = folder.appendingPathComponent("Phone.jpg")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [80]],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let out = folder.appendingPathComponent("out.jpg")
        let request = ExportWorker.Request(
            sourceURL: source, destinationURL: out, editStackJSON: #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}"#,
            userRotation: 0, settings: ExportSettings(format: .jpeg, hdrGainMap: true), colorSpace: .sRGB, maxLongEdge: nil)
        let outcome = try await ExportWorker.export(request, gpu: try GPUContext())
        XCTAssertEqual(outcome.pixelWidth, width)
        XCTAssertEqual(outcome.pixelHeight, height)

        let written = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, kCGImageAuxiliaryDataTypeISOGainMap),
                     "no gain map for an SDR source")
        let properties = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "iPhone 16 Pro")
    }
}
