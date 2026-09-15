import XCTest
import ImageIO
@testable import MLKit
@testable import PixelEngine
import ColorKit

/// The gain-map option through the whole export: ExportWorker renders the
/// HDR half itself when the settings ask for one.
final class ExportWorkerGainMapTests: XCTestCase {
    func testHDRGainMapOptionWritesAnISOGainMap() async throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        for format in [ExportSettings.Format.jpeg, .png] {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("latent-export-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: out) }
            let request = ExportWorker.Request(
                sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: nil, userRotation: 0,
                settings: ExportSettings(format: format, hdrGainMap: true), colorSpace: .sRGB, maxLongEdge: 1024)
            let outcome = try await ExportWorker.export(request, gpu: gpu)
            XCTAssertEqual(max(outcome.pixelWidth, outcome.pixelHeight), 1024)

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
            let map = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
            if format.supportsGainMap {
                XCTAssertNotNil(map, "no gain map in the \(format.displayName)")
                let hdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
                    source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
                XCTAssertGreaterThan(hdr.contentHeadroom, 1)
            } else {
                // PNG has nowhere to put one: the option is ignored, not an error.
                XCTAssertNil(map)
            }
        }
    }
}
