import XCTest
import ImageIO
@testable import MLKit
@testable import PixelEngine
import ColorKit

/// Renders for a page (Print, Contact Sheet) come from the same steps as
/// an export, so a printed photo is the exported photo.
final class ExportWorkerImageTests: XCTestCase {
    func testPageRenderIsTheExportsPixels() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        var edit = EditParameters()
        edit.exposureEV = 0.5
        let json = try EditStack(parameters: edit).encodeJSON()
        let source = URL(fileURLWithPath: path)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-page-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await ExportWorker.export(ExportWorker.Request(
            sourceURL: source, destinationURL: out, editStackJSON: json, userRotation: 1,
            settings: ExportSettings(format: .png), colorSpace: .sRGB, maxLongEdge: 640, includeMetadata: false), gpu: gpu)
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil)), 0, nil))

        let page = try await ExportWorker.renderImage(ExportWorker.ImageRequest(
            sourceURL: source, editStackJSON: json, userRotation: 1, colorSpace: .sRGB, maxLongEdge: 640,
            bitsPerComponent: 8, runsAIDenoise: false), gpu: gpu).cgImage
        XCTAssertEqual(page.width, exported.width)
        XCTAssertEqual(page.height, exported.height)
        XCTAssertEqual(max(page.width, page.height), 640)
        XCTAssertEqual(try Self.bytes(page), try Self.bytes(exported))

        // Print's render: 16 bits in Display P3, never enlarged.
        let wide = try await ExportWorker.renderImage(ExportWorker.ImageRequest(
            sourceURL: source, editStackJSON: json, userRotation: 0, colorSpace: .displayP3, maxLongEdge: 1000),
                                                     gpu: gpu).cgImage
        XCTAssertEqual(wide.bitsPerComponent, 16)
        XCTAssertEqual(wide.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(max(wide.width, wide.height), 1000)
        XCTAssertEqual(page.width < page.height, wide.width > wide.height, "a quarter turn swaps the sides")
    }

    /// A cropped photo still reaches the size asked for: the render bins
    /// for the crop, not for the whole frame, which cropped would come out
    /// smaller (the exporter never enlarges), for a file and a page alike.
    func testACroppedRenderReachesTheRequestedSize() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        var edit = EditParameters()
        edit.crop = CropParameters(size: [0.5, 0.5])
        let json = try EditStack(parameters: edit).encodeJSON()
        let source = URL(fileURLWithPath: path)

        let page = try await ExportWorker.renderImage(ExportWorker.ImageRequest(
            sourceURL: source, editStackJSON: json, userRotation: 0, colorSpace: .sRGB, maxLongEdge: 700,
            bitsPerComponent: 8, runsAIDenoise: false), gpu: gpu).cgImage
        XCTAssertEqual(max(page.width, page.height), 700)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-crop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await ExportWorker.export(ExportWorker.Request(
            sourceURL: source, destinationURL: out, editStackJSON: json, userRotation: 0,
            settings: ExportSettings(format: .png), colorSpace: .sRGB, maxLongEdge: 700, includeMetadata: false), gpu: gpu)
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil)), 0, nil))
        XCTAssertEqual(max(exported.width, exported.height), 700)
    }

    func testAnUnreadableEditIsAnErrorNotAnUneditedPhoto() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        do {
            _ = try await ExportWorker.renderImage(ExportWorker.ImageRequest(
                sourceURL: URL(fileURLWithPath: path), editStackJSON: "{not json", userRotation: 0, colorSpace: .sRGB,
                maxLongEdge: 256), gpu: gpu)
            XCTFail("rendered")
        } catch ExportWorkerError.unreadableEdit {
        }
    }

    /// The image's RGB bytes, drawn into 8-bit sRGB.
    static func bytes(_ image: CGImage) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }
}
