import XCTest
import ImageIO
@testable import MLKit
@testable import PixelEngine
import ColorKit

/// `ExportWorker.render`, which the export sheet encodes for its size
/// estimate and quality comparison: it must be the pixels `export` writes,
/// watermark and gain map included, and its encode the file's size.
final class ExportWorkerRenderTests: XCTestCase {
    func testRenderEncodesToTheExportedFileWithWatermark() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("latent-render-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }

        let mark = ExportWatermark(text: "© {year} {name}", corner: .bottomLeft, size: 0.05, opacity: 0.8)
        let settings = ExportSettings(format: .jpeg, quality: 0.8, hdrGainMap: true, watermark: mark)
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: nil, userRotation: 0,
            settings: settings, colorSpace: .sRGB, maxLongEdge: 600, keywords: ["k"], rating: 2)
        let rendered = try await ExportWorker.render(request, gpu: gpu)
        let outcome = try await ExportWorker.export(request, gpu: gpu)

        XCTAssertEqual(rendered.pixelWidth, outcome.pixelWidth)
        XCTAssertEqual(rendered.pixelHeight, outcome.pixelHeight)
        XCTAssertNotNil(rendered.image.gainMap)
        let year = Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(rendered.metadata?.captureDate))
        XCTAssertEqual(rendered.settings.watermark?.text, "© \(year) golden_nikon_d750_cc0", "tokens filled in")

        let data = try rendered.encoded(with: rendered.settings)
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int)
        XCTAssertEqual(data.count, fileSize, "the estimate's encode is the file")
        let lower = try rendered.encoded(with: ExportSettings(format: .jpeg, quality: 0.4, hdrGainMap: true))
        XCTAssertLessThan(lower.count, data.count)

        // Without a watermark the render differs only in the bottom-left corner.
        var plainRequest = request
        plainRequest.settings.watermark = nil
        let plain = try await ExportWorker.render(plainRequest, gpu: gpu)
        let a = try XCTUnwrap(plain.image.image.dataProvider?.data) as Data
        let b = try XCTUnwrap(rendered.image.image.dataProvider?.data) as Data
        XCTAssertEqual(a.count, b.count)
        let w = plain.pixelWidth, h = plain.pixelHeight
        var changedTopHalf = 0, changedBottomLeft = 0
        for y in 0..<h {
            for x in 0..<w where a[(y * w + x) * 4] != b[(y * w + x) * 4] {
                if y < h / 2 { changedTopHalf += 1 } else if x < w / 2 { changedBottomLeft += 1 }
            }
        }
        XCTAssertEqual(changedTopHalf, 0)
        XCTAssertGreaterThan(changedBottomLeft, 100)
    }

    /// The export sheet renders once without the watermark and with the
    /// metadata read, then finishes copies with its settings: each must be
    /// the render those settings would have made, pixels, gain map and
    /// metadata alike.
    func testFinishingAPlainRenderIsRenderingWithTheSettings() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let mark = ExportWatermark(text: "© {year} {name}", corner: .topRight, size: 0.06, opacity: 0.7)
        for (format, gainMap, space) in [(ExportSettings.Format.jpeg, true, ColorKit.OutputSpace.sRGB),
                                          (.tiff, false, .displayP3)] {
            let plainRequest = ExportWorker.Request(
                sourceURL: URL(fileURLWithPath: path), destinationURL: URL(fileURLWithPath: "/dev/null"),
                editStackJSON: nil, userRotation: 0, settings: ExportSettings(format: format, hdrGainMap: gainMap),
                colorSpace: space, maxLongEdge: 500, keywords: ["k"], rating: 3,
                includeMetadata: true, includeLocation: true)
            let plain = try await ExportWorker.render(plainRequest, gpu: gpu)
            for (watermark, metadata, location) in [(mark, true, false), (nil, false, false), (mark, false, false)] {
                var request = plainRequest
                request.settings.watermark = watermark
                request.includeMetadata = metadata
                request.includeLocation = location
                let direct = try await ExportWorker.render(request, gpu: gpu)
                let finished = try plain.finished(watermark: watermark, includeMetadata: metadata,
                                                  includeLocation: location)
                let label = "\(format) watermark \(watermark != nil) metadata \(metadata)"
                XCTAssertEqual(finished.settings.watermark, direct.settings.watermark, label)
                XCTAssertEqual(finished.image.image.bitsPerComponent, direct.image.image.bitsPerComponent, label)
                XCTAssertEqual(try XCTUnwrap(finished.image.image.dataProvider?.data) as Data,
                               try XCTUnwrap(direct.image.image.dataProvider?.data) as Data, label)
                XCTAssertEqual(finished.image.gainMap?.pixels, direct.image.gainMap?.pixels, label)
                XCTAssertEqual(finished.metadata == nil, direct.metadata == nil, label)
                XCTAssertEqual(finished.metadata?.includeLocation, direct.metadata?.includeLocation, label)
                XCTAssertEqual(try finished.encoded(with: finished.settings), try direct.encoded(with: direct.settings),
                               label)
            }
        }
    }

    func testRenderStopsWhenCancelled() async throws {
        let path = AIMaskTests.assetPath("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let request = ExportWorker.Request(
            sourceURL: URL(fileURLWithPath: path), destinationURL: URL(fileURLWithPath: "/dev/null"),
            editStackJSON: nil, userRotation: 0, settings: ExportSettings(), colorSpace: .sRGB, maxLongEdge: 400)
        let task = Task.detached { try await ExportWorker.render(request, gpu: gpu) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled render should throw")
        } catch is CancellationError {
        }
    }
}
