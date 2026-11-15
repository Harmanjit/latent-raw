import XCTest
import ImageIO
@testable import Catalog

final class ThumbnailTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        let sample = try TestAssets.d750Path()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-thumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: sample,
                                         toPath: folder.appendingPathComponent("sub/A.NEF").path)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testGeneratesJPEGAtTargetSizeOnce() async throws {
        let catalog = try Catalog.open(at: folder)
        try await catalog.setDefaultSubfolderMode(.included)
        _ = try await catalog.reconcile()

        var report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 1, "\(report.failures)")

        let url = await catalog.thumbnailURL(forRelPath: "sub/A.NEF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
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

    func testKeysCarryTheCacheVersion() {
        XCTAssertEqual(Thumbnailer.embeddedPreviewKey, Data("embedded:v2".utf8))
        let key = Thumbnailer.key(forEditStack: "{}")
        XCTAssertTrue(key.starts(with: Data("edit:v2:".utf8)))
    }

    /// A catalog from before cache version 2 has HEIC files and v1 keys:
    /// the grid shows the HEIC until the pass makes the JPEG, which then
    /// replaces it.
    func testVersion1HEICIsShownUntilReplaced() async throws {
        let catalog = try Catalog.open(at: folder)
        try await catalog.setDefaultSubfolderMode(.included)
        _ = try await catalog.reconcile()
        _ = try await catalog.generateMissingThumbnails()
        let jpeg = await catalog.thumbnailURL(forRelPath: "sub/A.NEF")
        XCTAssertEqual(jpeg.pathExtension, "jpg")
        let heic = Catalog.legacyThumbnailURL(for: jpeg)
        XCTAssertEqual(heic.lastPathComponent, "A.NEF.heic")

        // Turn it into what version 1 left behind.
        let image = try XCTUnwrap(Thumbnailer.load(from: jpeg))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try FileManager.default.removeItem(at: jpeg)
        try await catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE images SET thumb_key = ?", arguments: [Data("embedded:v1".utf8)])
        }

        // Shown meanwhile, and not counted as an orphan.
        XCTAssertNotNil(ThumbnailLoader.decodeFile(jpeg, 256))
        let usage = try await catalog.thumbnailCacheUsage()
        XCTAssertEqual(usage.orphanFiles, 0)

        let report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 1)
        XCTAssertEqual(report.replacedRelPaths, ["sub/A.NEF"], "the shown HEIC is replaced, so caches drop it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path))
        let images = try await catalog.allImages()
        XCTAssertEqual(images[0].thumbKey, Thumbnailer.embeddedPreviewKey)
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
