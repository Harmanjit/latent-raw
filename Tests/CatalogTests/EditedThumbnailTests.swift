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
        let sample = try TestAssets.d750Path()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-edthumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: sample,
                                         toPath: folder.appendingPathComponent("A.NEF").path)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testEditChangesTheKeyAndRegenerates() async throws {
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let first = try await catalog.generateMissingThumbnails()
        XCTAssertEqual(first.replacedRelPaths, [], "nothing was there to replace")
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
        XCTAssertEqual(report.replacedRelPaths, ["A.NEF"], "so a memory cache must drop it")
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

    /// Every settled edit starts a thumbnail pass, often while one runs.
    /// The running pass, cancelled, must stop taking files and record what
    /// it finished, and the new one must make only what is left: each file
    /// made once. Before, both passes made every file whose key the first
    /// hadn't recorded yet, and keys were recorded only when a pass ended.
    func testOverlappingPassesMakeEachThumbnailOnce() async throws {
        let fm = FileManager.default
        for n in 2...12 {
            try fm.copyItem(at: folder.appendingPathComponent("A.NEF"), to: folder.appendingPathComponent("A\(n).NEF"))
        }
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let json = #"{"schema":1,"modules":{"exposure":{"ev":1}}}"#
        for image in try await catalog.allImages() {
            try await catalog.setEditStack(json, forImageID: try XCTUnwrap(image.id))
        }
        let counter = CountingRenderer()
        let gate = DispatchSemaphore(value: 0)
        counter.gate = gate

        let first = Task { try await catalog.generateMissingThumbnails(concurrency: 1, editedRenderer: counter) }
        // Wait until the first pass is inside its first file.
        for _ in 0..<500 where counter.calls == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(counter.calls, 1)
        first.cancel()
        let second = Task { try await catalog.generateMissingThumbnails(concurrency: 4, editedRenderer: counter) }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.signal()

        let firstReport = try await first.value
        let secondReport = try await second.value
        XCTAssertEqual(firstReport.generated, 1, "the cancelled pass finished its file and took no more")
        XCTAssertEqual(secondReport.generated, 11, "\(secondReport.failures)")
        XCTAssertEqual(counter.calls, 12, "each thumbnail made once")
        let left = try await catalog.thumbnailJobs()
        XCTAssertTrue(left.isEmpty, "every key recorded")
    }
}

/// Counts renders; the first one waits on `gate` when one is set.
final class CountingRenderer: EditedThumbnailRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var gate: DispatchSemaphore?

    var calls: Int { lock.withLock { count } }

    func renderThumbnail(rawFileAt url: URL, editStackJSON: String) throws -> CGImage {
        let isFirst = lock.withLock { count += 1; return count == 1 }
        if isFirst { gate?.wait() }
        return try SolidRenderer().renderThumbnail(rawFileAt: url, editStackJSON: editStackJSON)
    }
}
