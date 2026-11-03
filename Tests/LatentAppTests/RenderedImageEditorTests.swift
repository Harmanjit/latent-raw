import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PixelEngine
@testable import latent_app

/// A JPEG, PNG or TIFF in the editor: it opens, the raw-only panels know
/// it, the view stays SDR, and an edit to it saves and loads back.
@MainActor
final class RenderedImageEditorTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-editor-formats-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writePNG(width: Int = 40, height: Int = 30) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = UInt8(i / 4 % 256); bytes[i + 1] = 90 }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let url = folder.appendingPathComponent("Scan.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testAPictureOpensWithTheRawOnlyToolsSetAside() async throws {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        XCTAssertTrue(model.isReady)
        model.open(url: try writePNG(), catalogImageID: 7)
        XCTAssertTrue(model.hasImage, model.status)
        XCTAssertTrue(model.isRenderedImage)
        XCTAssertEqual(model.status, "PNG · 8-bit · 40×30")
        XCTAssertFalse(model.aiDenoiseSupported)
        XCTAssertFalse(model.hasLensProfile)
        XCTAssertTrue(model.lensProfileDescription.contains("raw files"), model.lensProfileDescription)
        XCTAssertEqual(model.displayOutput.headroom, 1, "a picture made for SDR stays SDR on an HDR screen")
    }

    /// An edit to a picture is an ordinary edit stack: saved, and applied
    /// again when the picture is opened with it.
    func testAnEditToAPictureSavesAndLoadsBack() async throws {
        _ = try await GPUContext.shared()
        let url = try writePNG()
        let model = EditorModel()
        var saved: [(Int64, String?)] = []
        model.onEditSettled = { saved.append(($0, $1)) }
        model.open(url: url, catalogImageID: 7)
        model.parameters.exposureEV = 0.7
        model.parameters.sharpenAmount = 0.5
        model.flushPendingSave()
        let json = try XCTUnwrap(saved.last?.1)
        XCTAssertEqual(saved.last?.0, 7)

        let again = EditorModel()
        again.open(url: url, catalogImageID: 7, editStackJSON: json)
        XCTAssertEqual(again.parameters.exposureEV, 0.7, accuracy: 1e-6)
        XCTAssertEqual(again.parameters.sharpenAmount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(again.parameters.whiteBalance, model.parameters.whiteBalance)
        XCTAssertNil(again.newerEditImageID)
    }
}
