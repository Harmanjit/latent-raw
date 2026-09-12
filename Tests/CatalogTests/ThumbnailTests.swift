import XCTest
import ImageIO
@testable import Catalog

final class ThumbnailTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawhead-thumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                         toPath: folder.appendingPathComponent("sub/A.NEF").path)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testGeneratesHEICAtTargetSizeOnce() async throws {
        let catalog = try Catalog.open(at: folder)
        try await catalog.setDefaultSubfolderMode(.included)
        _ = try await catalog.reconcile()

        var report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 1, "\(report.failures)")

        let url = await catalog.thumbnailURL(forRelPath: "sub/A.NEF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.heic")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        XCTAssertEqual(max(w, h), Thumbnailer.size)
        XCTAssertGreaterThan(w, h, "the sample is landscape")

        // Recorded, so the next pass has nothing to do.
        let images = try await catalog.allImages()
        XCTAssertEqual(images[0].thumbKey, Thumbnailer.embeddedPreviewKey)
        report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 0)

        // Deleting the file makes it needed again.
        try FileManager.default.removeItem(at: url)
        report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 1)
    }

    func testRotationSwapsDimensions() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        let turned = Thumbnailer.rotated(image, quarterTurns: 1)
        XCTAssertEqual(turned.width, 20)
        XCTAssertEqual(turned.height, 40)
        let flipped = Thumbnailer.rotated(image, quarterTurns: 2)
        XCTAssertEqual(flipped.width, 40)
    }
}
