import XCTest
import ImageIO
import Metal
@testable import MLKit
@testable import PixelEngine
@testable import RawCore
import ColorKit

final class ExportWorkerScreenTests: XCTestCase {
    private func sharedCopy(_ slide: SlideTexture, gpu: GPUContext) throws -> [UInt8] {
        let source = slide.texture
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: source.width,
                                                         height: source.height, mipmapped: false)
        d.storageMode = .shared
        let copy = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        let commands = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        copy.getBytes(&bytes, bytesPerRow: source.width * 4, from: MTLRegionMake2D(0, 0, source.width, source.height),
                      mipmapLevel: 0)
        return bytes
    }

    /// A slide is the file an export of the same size would write: same
    /// edit, same pipeline, same resize, same colour space.
    func testASlideMatchesAnExportOfTheSameSize() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        var p = EditParameters()
        p.exposureEV = 0.5
        p.vibrance = 0.3
        let json = try EditStack(parameters: p).encodeJSON()
        let screen = CGSize(width: 1440, height: 900)
        let slide = try await ExportWorker.renderForScreen(sourceURL: URL(fileURLWithPath: path), editStackJSON: json,
                                                           userRotation: 0, screen: screen, gpu: gpu)
        let size = slide.pixelSize
        XCTAssertTrue(size.width <= screen.width && size.height <= screen.height, "\(size)")
        XCTAssertTrue(size.width == screen.width || size.height == screen.height, "fits one way exactly: \(size)")

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-slide-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: json, userRotation: 0,
            settings: ExportSettings(format: .png), colorSpace: .displayP3,
            maxLongEdge: Int(max(size.width, size.height)), includeMetadata: false)
        _ = try await ExportWorker.export(request, gpu: gpu)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGSize(width: image.width, height: image.height), size)
        let fileBytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        let slideBytes = try sharedCopy(slide, gpu: gpu)
        let stride = image.bitsPerPixel / 8
        var largest = 0
        for pixel in 0..<(image.width * image.height) {
            for channel in 0..<3 {
                largest = max(largest, abs(Int(fileBytes[pixel * stride + channel]) - Int(slideBytes[pixel * 4 + channel])))
            }
        }
        XCTAssertLessThanOrEqual(largest, 1)

        // Set LATENT_SLIDESHOW_TEST_OUT to a folder to look at a frame.
        if let folder = ProcessInfo.processInfo.environment["LATENT_SLIDESHOW_TEST_OUT"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: folder).appendingPathComponent("slide.png"))
        }
    }

    func testACroppedSlideStillFillsTheScreen() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        var p = EditParameters()
        p.crop = CropParameters(centre: [0.5, 0.5], size: [0.5, 0.5])
        let json = try EditStack(parameters: p).encodeJSON()
        let screen = CGSize(width: 1440, height: 900)
        let slide = try await ExportWorker.renderForScreen(sourceURL: URL(fileURLWithPath: path), editStackJSON: json,
                                                           userRotation: 1, screen: screen, gpu: gpu)
        // A quarter turn makes it portrait: 900 high, and a 3:2 shape.
        XCTAssertEqual(slide.pixelSize.height, 900)
        XCTAssertEqual(slide.pixelSize.width, 600, accuracy: 2)
    }
}
