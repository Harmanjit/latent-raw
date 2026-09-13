import XCTest
import Catalog
@testable import PixelEngine
@testable import RawCore

/// The app's edited-thumbnail path, end to end on the GPU: pipeline at
/// thumbnail resolution, CGImage out, HEIC in. Mirrors
/// PipelineThumbnailRenderer in the app target.
final class EditedThumbnailRenderTests: XCTestCase {
    func testPipelineThumbnailHasTargetSizeAndReflectsTheEdit() throws {
        let path = TestAssets.path("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let longEdge = max(file.summary.rawWidth, file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / Double(2 * Thumbnailer.size)).rounded(.up)))

        func mean(_ image: CGImage) -> Double {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0
            for i in stride(from: 0, to: bytes.count, by: 4) { sum += Int(bytes[i + 1]) }
            return Double(sum) / Double(w * h)
        }

        var dark = EditParameters(); dark.exposureEV = -2
        var bright = EditParameters(); bright.exposureEV = 1
        let exporter = Exporter(gpu: gpu)
        let rotation = ImageRotation(libRawFlip: file.summary.orientation)

        let darkImage = try exporter.cgImage(
            from: try pipeline.render(session, scale: .binned(quads: quads),
                                      parameters: dark, output: .file(.sRGB)),
            colorSpace: .sRGB, rotation: rotation)
        let brightImage = try exporter.cgImage(
            from: try pipeline.render(session, scale: .binned(quads: quads),
                                      parameters: bright, output: .file(.sRGB)),
            colorSpace: .sRGB, rotation: rotation)

        XCTAssertLessThanOrEqual(max(darkImage.width, darkImage.height), Thumbnailer.size)
        XCTAssertGreaterThan(max(darkImage.width, darkImage.height), Thumbnailer.size / 2)
        XCTAssertGreaterThan(mean(brightImage), mean(darkImage) + 30,
                             "the edit must show in the thumbnail")

        // And it round-trips through the HEIC writer.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawhead-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Thumbnailer.write(brightImage, to: tmp)
        XCTAssertEqual(Thumbnailer.load(from: tmp)?.width, brightImage.width)
    }
}
