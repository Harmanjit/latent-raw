import XCTest
import CoreGraphics
@testable import Catalog

/// A renderer that paints a solid colour, so the test needs no GPU.
struct SolidRenderer: EditedThumbnailRenderer {
    func renderThumbnail(rawFileAt url: URL, editStackJSON: String) throws -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        return ctx.makeImage()!
    }
}

final class EditedThumbnailTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-edthumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                         toPath: folder.appendingPathComponent("A.NEF").path)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testEditChangesTheKeyAndRegenerates() async throws {
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        _ = try await catalog.generateMissingThumbnails()
        let firstImage = try await catalog.image(forRelPath: "A.NEF")
        let id = try XCTUnwrap(firstImage?.id)
        XCTAssertEqual(firstImage?.thumbKey, Thumbnailer.embeddedPreviewKey)

        // Saving an edit makes the thumbnail stale.
        let json = #"{"schema":1,"modules":{"exposure":{"ev":1}}}"#
        try await catalog.setEditStack(json, forImageID: id)
        var jobs = try await catalog.thumbnailJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].editStackJSON, json)
        XCTAssertEqual(jobs[0].expectedKey, Thumbnailer.key(forEditStack: json))

        // Without a renderer, edited images are skipped, not failed.
        var report = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(report.generated, 0)
        XCTAssertEqual(report.failures.count, 0)

        // With one, the file is replaced and the key recorded.
        report = try await catalog.generateMissingThumbnails(editedRenderer: SolidRenderer())
        XCTAssertEqual(report.generated, 1)
        XCTAssertEqual(report.regeneratedRelPaths, ["A.NEF"])
        let edited = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(edited?.thumbKey, Thumbnailer.key(forEditStack: json))
        let url = await catalog.thumbnailURL(forRelPath: "A.NEF")
        let image = try XCTUnwrap(Thumbnailer.load(from: url))
        XCTAssertEqual(image.width, 64, "the renderer's image was written")

        // Same edit again: nothing to do.
        jobs = try await catalog.thumbnailJobs()
        XCTAssertTrue(jobs.isEmpty)

        // Clearing the edit brings the embedded preview back.
        try await catalog.setEditStack(nil, forImageID: id)
        report = try await catalog.generateMissingThumbnails(editedRenderer: SolidRenderer())
        XCTAssertEqual(report.generated, 1)
        let cleared = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(cleared?.thumbKey, Thumbnailer.embeddedPreviewKey)
        XCTAssertEqual(Thumbnailer.load(from: url)?.width, 512)
    }
}
