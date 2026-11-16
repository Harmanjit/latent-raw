import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import MLKit
@testable import PixelEngine
import ColorKit

/// A full-size export of a photo wider than the GPU's largest texture is
/// written at the largest size that fits, and says so, rather than failing
/// with "Failed to allocate a GPU buffer or texture".
final class ExportGPULimitTests: XCTestCase {
    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("latent-gpu-limit-\(UUID().uuidString).\(ext)")
    }

    /// A grey TIFF `width` x `height`, small in memory however wide.
    private func writeTIFF(width: Int, height: Int, to url: URL) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testFullSizeExportPastTheTextureLimitFitsAndSaysSo() async throws {
        let gpu = try GPUContext()
        let limit = ExportPlan.maxTextureSide(gpu.device)
        let source = temporary("tif"), out = temporary("jpg")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: out) }
        try writeTIFF(width: limit + 616, height: 64, to: source)

        let request = ExportWorker.Request(sourceURL: source, destinationURL: out, editStackJSON: nil, userRotation: 0,
                                           settings: ExportSettings(format: .jpeg, quality: 0.8), colorSpace: .sRGB,
                                           maxLongEdge: nil, includeMetadata: false)
        let outcome = try await ExportWorker.export(request, gpu: gpu)
        XCTAssertLessThanOrEqual(outcome.pixelWidth, limit)
        XCTAssertEqual(outcome.pixelWidth, (limit + 616) / 2)
        XCTAssertEqual(outcome.reducedFromLongEdge, limit + 616)
    }

    /// An ISO no camera writes (a damaged file) is left out of the
    /// metadata rather than trapping when it is made a whole number.
    func testImpossibleISOIsLeftOut() {
        XCTAssertEqual(ExportWorker.metadataISO(400), 400)
        XCTAssertNil(ExportWorker.metadataISO(0))
        XCTAssertNil(ExportWorker.metadataISO(.nan))
        XCTAssertNil(ExportWorker.metadataISO(.infinity))
        XCTAssertNil(ExportWorker.metadataISO(1e30))
    }
}
