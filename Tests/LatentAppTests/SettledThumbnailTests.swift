import XCTest
import CoreGraphics
import PixelEngine
import RawCore
import Catalog
@testable import latent_app

/// Plan #28: a settled edit's thumbnail rendered from the editor's open
/// session, handed over before the save starts the thumbnail pass.
@MainActor
final class SettledThumbnailTests: XCTestCase {
    func testDebouncedSaveOffersTheThumbnailFirstAndMatchesAFreshRender() async throws {
        let gpu = try await GPUContext.shared()
        let url = try TestAssets.d750URL()
        let model = EditorModel()
        var events: [String] = []
        var offered: (id: Int64, json: String, image: CGImage)?
        model.onSettledThumbnail = { id, json, image in
            events.append("thumbnail")
            offered = (id, json, image)
        }
        var savedJSON: String?
        model.onEditSettled = { _, json in
            events.append("save")
            savedJSON = json
        }
        model.open(url: url, catalogImageID: 7)
        XCTAssertTrue(model.hasImage, model.status)
        let previewBefore = try XCTUnwrap(model.preview?.texture)

        model.parameters.exposureEV = 1
        let start = Date()
        model.flushPendingSave(renderingThumbnail: true)
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "settled thumbnail + save on the main actor: %.1f ms", ms))

        XCTAssertEqual(events, ["thumbnail", "save"], "handed over before the save starts the pass")
        let thumbnail = try XCTUnwrap(offered)
        XCTAssertEqual(thumbnail.id, 7)
        XCTAssertEqual(thumbnail.json, savedJSON)
        XCTAssertLessThanOrEqual(max(thumbnail.image.width, thumbnail.image.height), Thumbnailer.size)
        XCTAssertGreaterThan(max(thumbnail.image.width, thumbnail.image.height), Thumbnailer.size / 2)
        XCTAssertTrue(model.preview?.texture === previewBefore, "the preview on screen is left alone")

        // The same pixels the pass would make from the file.
        let fresh = try PipelineThumbnailRenderer(gpu: gpu).renderThumbnail(rawFileAt: url,
                                                                           editStackJSON: thumbnail.json)
        XCTAssertEqual(fresh.width, thumbnail.image.width)
        XCTAssertEqual(fresh.height, thumbnail.image.height)
        XCTAssertLessThan(Self.meanAbsoluteDifference(fresh, thumbnail.image), 0.5)
    }

    func testOtherSavesDoNotRender() async throws {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        var offers = 0
        model.onSettledThumbnail = { _, _, _ in offers += 1 }
        model.onEditSettled = { _, _ in }
        model.open(url: try TestAssets.d750URL(), catalogImageID: 7)
        model.parameters.exposureEV = 1
        model.flushPendingSave()   // switching photos, exporting, quitting
        XCTAssertEqual(offers, 0)
    }

    private static func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func bytes(_ image: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return out
        }
        let x = bytes(a), y = bytes(b)
        var sum = 0
        for i in x.indices where i % 4 != 3 { sum += abs(Int(x[i]) - Int(y[i])) }
        return Double(sum) / Double(x.count / 4 * 3)
    }
}
