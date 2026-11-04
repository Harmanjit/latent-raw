import XCTest
import ImageIO
import CoreGraphics
@testable import MLKit
@testable import PixelEngine
@testable import RawCore
@testable import MergeKit
import ColorKit

/// DNG contents (full look, original) and full HDR output, end to end
/// through `ExportWorker` on the golden raw.
final class ExportDNGContentAndHDRTests: XCTestCase {
    private var golden: URL { TestAssets.url(TestAssets.goldenName) }

    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("latent-out-\(UUID().uuidString).\(ext)")
    }

    /// With the full look baked in, the DNG opens in Latent, with no edit,
    /// looking like the edit itself (its preview), tone and colour included.
    func testFullLookDNGOpensLikeTheEdit() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: golden.path))
        let gpu = try GPUContext()
        var edit = EditParameters()
        edit.exposureEV = 0.3
        edit.contrast = 1.9       // the look: baked this time
        edit.vibrance = 0.4
        let json = try EditStack(parameters: edit).encodeJSON()

        let rendered = try await ExportWorker.renderSceneLinear(sourceURL: golden, editStackJSON: json, userRotation: 0,
                                                                gpu: gpu, content: .fullLook)
        let url = temporary("dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = EditParameters()
        try RenderedDNGExport.write(texture: rendered.texture, commandQueue: gpu.commandQueue, summary: rendered.summary,
                                    cameraToXYZ: rendered.cameraToXYZ, lensModel: rendered.lensModel,
                                    preview: rendered.preview,
                                    source: .init(path: "golden.nef", hash: "xxh64:0", captureTime: 0),
                                    softwareVersion: "test", to: url, replacingExisting: false,
                                    look: .init(contrast: defaults.contrast, greyPoint: defaults.greyPoint))

        let file = try RawFile(path: url.path)
        let session = try ImageSession(file: file, gpu: gpu)
        var open = EditParameters()
        open.whiteBalance = session.asShotWhiteBalance
        let reopened = try RenderPipeline(gpu: gpu).render(session, scale: .binned(quads: 2), parameters: open,
                                                           output: .file(.sRGB))
        let image = try Exporter(gpu: gpu).cgImage(from: reopened, colorSpace: .sRGB, maxLongEdge: 600)
        let preview = try XCTUnwrap(ExportOutputWorkerTests.resized(rendered.preview, width: image.width,
                                                                    height: image.height))
        let difference = ExportOutputWorkerTests.meanDifference(try ExportOutputWorkerTests.srgb(image).bytes,
                                                                try ExportOutputWorkerTests.srgb(preview).bytes)
        XCTAssertLessThan(difference, 5, "the full-look DNG opens \(difference) levels away from the edit")
    }

    /// Original raw as DNG ignores the edit: uncropped, unrotated by the
    /// user, at the defaults.
    func testOriginalContentIgnoresTheEdit() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: golden.path))
        let gpu = try GPUContext()
        var edit = EditParameters()
        edit.crop = CropParameters(centre: [0.5, 0.5], size: [0.5, 0.5], angle: 0)
        let json = try EditStack(parameters: edit).encodeJSON()
        let full = try await ExportWorker.renderSceneLinear(sourceURL: golden, editStackJSON: nil, userRotation: 0,
                                                            gpu: gpu)
        let original = try await ExportWorker.renderSceneLinear(sourceURL: golden, editStackJSON: json, userRotation: 1,
                                                                gpu: gpu, content: .original)
        XCTAssertEqual(original.texture.width, full.texture.width)
        XCTAssertEqual(original.texture.height, full.texture.height)
    }

    /// HDR Output with Maximize Compatibility off: a 10-bit PQ HEIC (and
    /// AVIF where this Mac writes it) that decodes brighter than SDR white;
    /// with it on, an AVIF gets a gain map.
    func testFullHDRAndAVIFGainMapExports() async throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        for format in [ExportSettings.Format.heic, .avif] where format.isAvailable {
            for full in [true, false] {
                let out = temporary(format.fileExtension)
                defer { try? FileManager.default.removeItem(at: out) }
                var settings = ExportSettings(format: format, hdrGainMap: true)
                settings.hdrFull = full
                let request = ExportWorker.Request(
                    sourceURL: URL(fileURLWithPath: path), destinationURL: out, editStackJSON: nil, userRotation: 0,
                    settings: settings, colorSpace: .displayP3, maxLongEdge: 640)
                let outcome = try await ExportWorker.export(request, gpu: gpu)
                XCTAssertEqual(max(outcome.pixelWidth, outcome.pixelHeight), 640)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let map = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
                let name = "\(format.displayName) full \(full)"
                if full {
                    XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 10, name)
                    XCTAssertTrue((properties[kCGImagePropertyProfileName as String] as? String ?? "").contains("PQ"), name)
                    XCTAssertNil(map, name)
                } else {
                    XCTAssertNotNil(map, name)
                }
                let hdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
                    source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
                XCTAssertGreaterThan(hdr.contentHeadroom, 1, name)
            }
        }
    }
}
