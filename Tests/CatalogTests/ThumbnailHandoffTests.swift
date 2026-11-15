import XCTest
import CoreGraphics
@testable import Catalog

final class ThumbnailHandoffTests: XCTestCase {
    private let hashA = Data([1, 2, 3])
    private let hashB = Data([4, 5, 6])

    func testPreviewIsTakenOnceAndOnlyForTheSameContent() {
        let handoff = ThumbnailHandoff(previewBudget: 100)
        XCTAssertTrue(handoff.offerPreview(Data(count: 40), orientation: 6, relPath: "A.NEF", hash: hashA))
        XCTAssertEqual(handoff.previewBytesHeld, 40)
        XCTAssertNil(handoff.takePreview(relPath: "A.NEF", hash: hashB), "other content")
        XCTAssertEqual(handoff.previewBytesHeld, 0, "a mismatched preview is dropped, not kept")

        handoff.offerPreview(Data(count: 40), orientation: 6, relPath: "A.NEF", hash: hashA)
        let taken = handoff.takePreview(relPath: "A.NEF", hash: hashA)
        XCTAssertEqual(taken?.jpeg.count, 40)
        XCTAssertEqual(taken?.orientation, 6)
        XCTAssertNil(handoff.takePreview(relPath: "A.NEF", hash: hashA), "taken once")
    }

    func testAFullBudgetRefusesNewPreviewsInsteadOfEvicting() {
        let handoff = ThumbnailHandoff(previewBudget: 100)
        XCTAssertTrue(handoff.offerPreview(Data(count: 60), orientation: 0, relPath: "A", hash: hashA))
        XCTAssertFalse(handoff.offerPreview(Data(count: 60), orientation: 0, relPath: "B", hash: hashA))
        XCTAssertEqual(handoff.previewBytesHeld, 60)
        XCTAssertNotNil(handoff.takePreview(relPath: "A", hash: hashA), "the first one stays")
        // Replacing a file's own entry counts only the difference; one too
        // big for the budget drops the stale entry rather than keep it.
        handoff.offerPreview(Data(count: 60), orientation: 0, relPath: "A", hash: hashA)
        XCTAssertTrue(handoff.offerPreview(Data(count: 90), orientation: 0, relPath: "A", hash: hashB))
        XCTAssertFalse(handoff.offerPreview(Data(count: 200), orientation: 0, relPath: "A", hash: hashA))
        XCTAssertEqual(handoff.previewBytesHeld, 0)
    }

    func testDiscardDropsOnlyTheNamedPreviews() {
        let handoff = ThumbnailHandoff(previewBudget: 100)
        handoff.offerPreview(Data(count: 10), orientation: 0, relPath: "A", hash: hashA)
        handoff.offerPreview(Data(count: 20), orientation: 0, relPath: "B", hash: hashA)
        handoff.discardPreviews(forRelPaths: ["A", "C"])
        XCTAssertEqual(handoff.previewBytesHeld, 20)
        handoff.discardAll()
        XCTAssertEqual(handoff.previewBytesHeld, 0)
    }

    func testRenderedImageMatchesItsKeyAndIsBounded() throws {
        let handoff = ThumbnailHandoff()
        let image = try Self.image()
        let key = Thumbnailer.key(forEditStack: "{\"a\":1}")
        handoff.offerRendered(image, imageID: 1, key: key)
        XCTAssertNil(handoff.takeRendered(imageID: 1, key: Thumbnailer.key(forEditStack: "{}")),
                     "rendered for another edit")
        XCTAssertNil(handoff.takeRendered(imageID: 1, key: key), "the stale one was dropped")

        handoff.offerRendered(image, imageID: 1, key: key)
        XCTAssertNotNil(handoff.takeRendered(imageID: 1, key: key))

        for id in 0..<Int64(ThumbnailHandoff.renderedLimit + 2) { handoff.offerRendered(image, imageID: id, key: key) }
        XCTAssertNil(handoff.takeRendered(imageID: 0, key: key), "the oldest went past the limit")
        XCTAssertNil(handoff.takeRendered(imageID: 1, key: key))
        XCTAssertNotNil(handoff.takeRendered(imageID: Int64(ThumbnailHandoff.renderedLimit + 1), key: key))
    }

    /// The pass makes the thumbnail from the preview the reconcile read,
    /// without opening the raw again: here the raw is gone by then.
    func testPassUsesThePreviewTheReconcileRead() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("A.NEF")
        try TestAssets.copyD750(to: raw)

        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        XCTAssertGreaterThan(catalog.thumbnailHandoff.previewBytesHeld, 100_000)

        try FileManager.default.removeItem(at: raw)
        let report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 1, "\(report.failures)")
        XCTAssertEqual(catalog.thumbnailHandoff.previewBytesHeld, 0)
        let url = await catalog.thumbnailURL(forRelPath: "A.NEF")
        let image = try XCTUnwrap(Thumbnailer.load(from: url))
        XCTAssertEqual(max(image.width, image.height), Thumbnailer.size)
        XCTAssertGreaterThan(image.width, image.height, "landscape, as from the file")
    }

    /// Previews of images the pass doesn't make from them (here: edited,
    /// with no renderer) don't stay behind.
    func testPassDropsPreviewsItDidNotUse() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let images = try await catalog.allImages()
        let id = try XCTUnwrap(images.first?.id)
        try await catalog.setEditStack("{}", schemaVersion: 1, processVersion: "1", forImageID: id)
        _ = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(catalog.thumbnailHandoff.previewBytesHeld, 0)
    }

    /// A settled edit the editor rendered is written as it is; the
    /// renderer, which would decode the raw again, isn't called for it.
    func testPassWritesTheEditorsRenderInsteadOfRenderingAgain() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let images = try await catalog.allImages()
        let id = try XCTUnwrap(images.first?.id)
        let json = "{\"exposure\":1}"
        try await catalog.setEditStack(json, schemaVersion: 1, processVersion: "1", forImageID: id)

        let rendered = try Self.image(width: 48, height: 32)
        catalog.thumbnailHandoff.offerRendered(rendered, imageID: id, key: Thumbnailer.key(forEditStack: json))
        let counter = HandoffCountingRenderer()
        var report = try await catalog.generateMissingThumbnails(editedRenderer: counter)
        XCTAssertEqual(report.generated, 1, "\(report.failures)")
        XCTAssertEqual(counter.calls, 0)
        let url = await catalog.thumbnailURL(forRelPath: "A.NEF")
        XCTAssertEqual(Thumbnailer.load(from: url)?.width, 48)

        // A render for an edit since replaced isn't used.
        catalog.thumbnailHandoff.offerRendered(rendered, imageID: id, key: Thumbnailer.key(forEditStack: json))
        try await catalog.setEditStack("{\"exposure\":2}", schemaVersion: 1, processVersion: "1", forImageID: id)
        report = try await catalog.generateMissingThumbnails(editedRenderer: counter)
        XCTAssertEqual(report.generated, 1)
        XCTAssertEqual(counter.calls, 1)
    }

    static func image(width: Int = 8, height: Int = 4) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try XCTUnwrap(ctx.makeImage())
    }
}

private final class HandoffCountingRenderer: EditedThumbnailRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func renderThumbnail(rawFileAt url: URL, editStackJSON: String) throws -> CGImage {
        lock.withLock { count += 1 }
        return try SolidRenderer().renderThumbnail(rawFileAt: url, editStackJSON: editStackJSON)
    }
}
