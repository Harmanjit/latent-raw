import XCTest
import ImageIO
import CoreGraphics
@testable import MLKit
@testable import PixelEngine
@testable import RawCore
@testable import MergeKit
import ColorKit

/// The export options added for Lightroom parity, end to end through
/// `ExportWorker` on the golden raw: DNG export, converted colour spaces,
/// image sizing, Limit File Size, ppi, output sharpening and metadata levels.
final class ExportOutputWorkerTests: XCTestCase {
    private var golden: URL { TestAssets.url(TestAssets.goldenName) }

    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("latent-out-\(UUID().uuidString).\(ext)")
    }

    private func request(_ settings: ExportSettings, to url: URL, maxLongEdge: Int? = 800,
                         json: String? = nil) -> ExportWorker.Request {
        ExportWorker.Request(sourceURL: golden, destinationURL: url, editStackJSON: json, userRotation: 0,
                             settings: settings, colorSpace: .sRGB, maxLongEdge: maxLongEdge)
    }

    /// The pixels of an image file drawn into sRGB at 8 bits, RGBA.
    private func srgbPixels(_ url: URL) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try Self.srgb(image)
    }

    static func srgb(_ image: CGImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, bytes)
    }

    /// Mean absolute difference per channel, 0...255.
    static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            total += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
        }
        return Double(total) / Double(min(a.count, b.count) / 4 * 3)
    }

    // MARK: - DNG

    /// A photo exported to DNG opens in Latent looking like the photo's
    /// scene-referred edit with the default look: same size, same colours.
    func testRenderedDNGOpensLikeTheEditsSceneReferredPart() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: golden.path))
        let gpu = try GPUContext()
        var edit = EditParameters()
        edit.exposureEV = 0.5
        edit.whiteBalance = .init(temperature: 4800, tint: 5)
        edit.crop = CropParameters(centre: [0.45, 0.5], size: [0.7, 0.8], angle: 2)
        edit.clarity = 0.6   // the look: not baked
        let json = try EditStack(parameters: edit).encodeJSON()

        let rendered = try await ExportWorker.renderSceneLinear(sourceURL: golden, editStackJSON: json, userRotation: 1,
                                                                gpu: gpu)
        let url = temporary("dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try RenderedDNGExport.write(texture: rendered.texture, commandQueue: gpu.commandQueue, summary: rendered.summary,
                                    cameraToXYZ: rendered.cameraToXYZ, lensModel: rendered.lensModel, preview: rendered.preview,
                                    source: .init(path: "golden.nef", hash: "xxh64:0", captureTime: 0),
                                    softwareVersion: "test", to: url, replacingExisting: false)

        // Reopened as Latent opens any raw, with no edit.
        let file = try RawFile(path: url.path)
        XCTAssertEqual(file.summary.rawWidth, rendered.texture.width)
        XCTAssertEqual(file.summary.rawHeight, rendered.texture.height)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let reopened = try pipeline.render(session, scale: .binned(quads: 2), parameters: defaults, output: .file(.sRGB))
        let reopenedImage = try Exporter(gpu: gpu).cgImage(from: reopened, colorSpace: .sRGB, maxLongEdge: 600)

        // The DNG's own preview is that same picture, made from the raw.
        let preview = try Self.srgb(rendered.preview)
        let scaledPreview = try XCTUnwrap(Self.resized(rendered.preview, width: reopenedImage.width,
                                                        height: reopenedImage.height))
        let opened = try Self.srgb(reopenedImage)
        XCTAssertGreaterThan(preview.width, 100)
        let difference = Self.meanDifference(opened.bytes, try Self.srgb(scaledPreview).bytes)
        XCTAssertLessThan(difference, 3, "the DNG opens \(difference) levels away from its preview")
        // No cast: each channel's average within a level and a half.
        for (a, b) in zip(Self.means(opened.bytes), Self.means(try Self.srgb(scaledPreview).bytes)) {
            XCTAssertEqual(a, b, accuracy: 1.5)
        }
    }

    // MARK: - Image files

    /// Adobe RGB through the worker: rendered in Rec. 2020, converted,
    /// tagged, and the same picture as the sRGB export when both are shown.
    func testAdobeRGBExportMatchesSRGBOnScreen() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: golden.path))
        let gpu = try GPUContext()
        let srgbURL = temporary("tif"), adobeURL = temporary("tif")
        defer { try? FileManager.default.removeItem(at: srgbURL); try? FileManager.default.removeItem(at: adobeURL) }
        _ = try await ExportWorker.export(request(ExportSettings(format: .tiff), to: srgbURL), gpu: gpu)
        var adobe = ExportSettings(format: .tiff)
        adobe.colorProfile = .adobeRGB
        let outcome = try await ExportWorker.export(request(adobe, to: adobeURL), gpu: gpu)
        XCTAssertEqual(max(outcome.pixelWidth, outcome.pixelHeight), 800)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(adobeURL as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertTrue((props[kCGImagePropertyProfileName as String] as? String ?? "").contains("Adobe RGB"))
        let a = try srgbPixels(srgbURL), b = try srgbPixels(adobeURL)
        XCTAssertEqual(a.width, b.width)
        XCTAssertLessThan(Self.meanDifference(a.bytes, b.bytes), 1.5)
    }

    /// Sizing by short edge, enlarging, Limit File Size, ppi, output
    /// sharpening and a metadata level, each through the worker.
    func testSizingLimitResolutionSharpeningAndMetadataLevel() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: golden.path))
        let gpu = try GPUContext()

        let shortURL = temporary("jpg")
        defer { try? FileManager.default.removeItem(at: shortURL) }
        var sized = request(ExportSettings(format: .jpeg), to: shortURL, maxLongEdge: nil)
        sized.sizing = ExportSizing(mode: .shortEdge, shortEdge: 500)
        let short = try await ExportWorker.export(sized, gpu: gpu)
        XCTAssertEqual(min(short.pixelWidth, short.pixelHeight), 500)

        // The golden raw cropped small, then enlarged past its own size.
        var edit = EditParameters()
        edit.crop = CropParameters(centre: [0.5, 0.5], size: [0.1, 0.1])
        let json = try EditStack(parameters: edit).encodeJSON()
        let grownURL = temporary("png")
        defer { try? FileManager.default.removeItem(at: grownURL) }
        var grown = request(ExportSettings(format: .png), to: grownURL, maxLongEdge: nil, json: json)
        grown.sizing = ExportSizing(mode: .longEdge, longEdge: 1200, dontEnlarge: false)
        let enlarged = try await ExportWorker.export(grown, gpu: gpu)
        XCTAssertEqual(max(enlarged.pixelWidth, enlarged.pixelHeight), 1200)

        let limitedURL = temporary("jpg")
        defer { try? FileManager.default.removeItem(at: limitedURL) }
        var settings = ExportSettings(format: .jpeg, quality: 1)
        settings.ppi = 240
        var limited = request(settings, to: limitedURL)
        limited.sizeLimitBytes = 60 * 1024
        limited.metadataLevel = .copyrightOnly
        limited.keywords = ["kept out"]
        _ = try await ExportWorker.export(limited, gpu: gpu)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: limitedURL.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 60 * 1024)
        let props = try XCTUnwrap(CGImageSourceCreateWithURL(limitedURL as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
        XCTAssertEqual(props[kCGImagePropertyDPIWidth as String] as? Double ?? 0, 240, accuracy: 0.5)
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel as String], "copyright only: no camera")
        XCTAssertNil((props[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCKeywords as String])

        // Sharpening changes the file; without it the file is as before.
        let plainURL = temporary("png"), sharpURL = temporary("png")
        defer { try? FileManager.default.removeItem(at: plainURL); try? FileManager.default.removeItem(at: sharpURL) }
        _ = try await ExportWorker.export(request(ExportSettings(format: .png), to: plainURL), gpu: gpu)
        var sharp = ExportSettings(format: .png)
        sharp.outputSharpening = OutputSharpening(medium: .screen, strength: .high)
        _ = try await ExportWorker.export(request(sharp, to: sharpURL), gpu: gpu)
        let plain = try srgbPixels(plainURL), sharpened = try srgbPixels(sharpURL)
        let change = Self.meanDifference(plain.bytes, sharpened.bytes)
        XCTAssertGreaterThan(change, 0.2, "sharpening did something")
        XCTAssertLessThan(change, 6, "and not too much")
        for (a, b) in zip(Self.means(plain.bytes), Self.means(sharpened.bytes)) {
            XCTAssertEqual(a, b, accuracy: 1, "sharpening doesn't change the overall tone")
        }
    }

    static func means(_ b: [UInt8]) -> [Double] {
        var m = [0.0, 0.0, 0.0]
        for i in stride(from: 0, to: b.count, by: 4) { for k in 0..<3 { m[k] += Double(b[i + k]) } }
        return m.map { $0 / Double(b.count / 4) }
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
