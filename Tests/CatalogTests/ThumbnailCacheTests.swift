import XCTest
import Combine
import CoreGraphics
import UniformTypeIdentifiers
@testable import Catalog

/// Settings › Performance's thumbnail settings and cache commands, and the
/// thumbnail pass's progress reaching the Library at a bounded rate.
@MainActor
final class ThumbnailCacheTests: XCTestCase {
    nonisolated(unsafe) var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-thumbcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writePictures(_ count: Int, width: Int = 48, height: Int = 32) throws {
        for index in 0..<count {
            try RenderedImageCatalogTests.writePicture(to: root.appendingPathComponent(String(format: "P%03d.JPG", index)),
                                                       type: .jpeg, seed: index, width: width, height: height)
        }
    }

    /// Opens `root` and waits for the first thumbnail pass to finish.
    private func openAndWait() async throws -> Library {
        let library = Library()
        try await library.open(folder: root, defaultSubfolderMode: .included)
        try await waitForThumbnails(library)
        return library
    }

    private func waitForThumbnails(_ library: Library, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let catalog = library.catalog, try await catalog.thumbnailJobs().isEmpty,
               library.thumbnailsDone >= library.thumbnailsTotal {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("thumbnails never finished")
    }

    // MARK: - Settings

    func testPriorityMapsToConcurrencyAndTaskPriority() {
        typealias Priority = ThumbnailGenerationSettings.Priority
        XCTAssertEqual(Priority.low.concurrency(activeProcessors: 10), 2)
        XCTAssertEqual(Priority.normal.concurrency(activeProcessors: 10), 4)
        XCTAssertEqual(Priority.high.concurrency(activeProcessors: 10), 8)
        XCTAssertEqual(Priority.high.concurrency(activeProcessors: 4), 4, "never fewer than Normal")
        XCTAssertEqual(Priority.low.taskPriority, .background)
        XCTAssertEqual(Priority.normal.taskPriority, .utility, "the default stays what it always was")
        XCTAssertEqual(ThumbnailGenerationSettings().quality.heicQuality, Thumbnailer.defaultQuality)
    }

    func testQualityChangesTheFileWritten() throws {
        let source = root.appendingPathComponent("Big.JPG")
        try RenderedImageCatalogTests.writePicture(to: source, type: .jpeg, seed: 3, width: 900, height: 600)
        let low = root.appendingPathComponent("low.heic"), high = root.appendingPathComponent("high.heic")
        try Thumbnailer.makeFromEmbeddedPreview(rawFileAt: source, to: low, quality: 0.3)
        try Thumbnailer.makeFromEmbeddedPreview(rawFileAt: source, to: high, quality: 1)
        let size = { (url: URL) in try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        XCTAssertLessThan(try size(low), try size(high))
        XCTAssertNotNil(Thumbnailer.load(from: low))
    }

    // MARK: - Cache commands

    func testRebuildRemakesOnlyTheGivenPhotos() async throws {
        try writePictures(3)
        let library = try await openAndWait()
        let catalog = try XCTUnwrap(library.catalog)
        let target = try XCTUnwrap(library.images.first)
        try await catalog.discardThumbnailKeys(forRelPaths: [target.relPath])
        let stale = try await catalog.thumbnailJobs().map(\.record.relPath)
        XCTAssertEqual(stale, [target.relPath])
        let targetThumbnail = await catalog.thumbnailURL(forRelPath: target.relPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetThumbnail.path),
                      "the old picture shows until the new one replaces it")

        library.rebuildThumbnails(for: [target])
        await library.waitForPendingWork()
        try await waitForThumbnails(library)
        let after = try await catalog.thumbnailJobs()
        XCTAssertTrue(after.isEmpty)
    }

    func testUsageCountsAndPurgeRemovesOnlyOrphans() async throws {
        try writePictures(2)
        let library = try await openAndWait()
        let catalog = try XCTUnwrap(library.catalog)
        let directory = await catalog.thumbnailDirectory
        let orphan = directory.appendingPathComponent("Gone.JPG.heic")
        try Data(repeating: 7, count: 5000).write(to: orphan)

        let measured = try await library.thumbnailCacheUsage()
        let usage = try XCTUnwrap(measured)
        XCTAssertEqual(usage.files, 3)
        XCTAssertEqual(usage.orphanFiles, 1)
        XCTAssertGreaterThanOrEqual(usage.orphanBytes, 5000)
        XCTAssertGreaterThan(usage.bytes, usage.orphanBytes)

        let freed = try await library.purgeOrphanThumbnails()
        XCTAssertEqual(freed, usage.orphanBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let remeasured = try await library.thumbnailCacheUsage()
        let after = try XCTUnwrap(remeasured)
        XCTAssertEqual(after.files, 2, "every photo keeps its thumbnail")
        XCTAssertEqual(after.orphanFiles, 0)
    }

    func testDiscardAllMakesEveryThumbnailAgain() async throws {
        try writePictures(4)
        let library = try await openAndWait()
        let catalog = try XCTUnwrap(library.catalog)
        try await library.discardAllThumbnails()
        try await waitForThumbnails(library)
        for record in library.images {
            let path = await catalog.thumbnailURL(forRelPath: record.relPath).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), record.relPath)
        }
        let measured = try await library.thumbnailCacheUsage()
        XCTAssertEqual(try XCTUnwrap(measured).files, 4)
    }

    func testLoweringTheMemoryBudgetEvicts() async {
        let loader = ThumbnailLoader(memoryCacheBytes: 100_000_000, workerLimit: 1,
                                     decode: ThumbnailLoaderTests.fakeDecode)
        for id in Int64(1)...3 {
            _ = await withCheckedContinuation { continuation in
                loader.request(id: id, url: URL(fileURLWithPath: "/nonexistent/\(id).heic"), quarterTurns: 0,
                               pixelSize: 512) { _ in continuation.resume() }
            }
        }
        XCTAssertGreaterThan(loader.cachedBytes, 0)
        XCTAssertEqual(loader.memoryBudget, 100_000_000)
        loader.memoryBudget = 0
        XCTAssertEqual(loader.cachedBytes, 0)
        loader.memoryBudget = 50_000_000
        XCTAssertEqual(loader.memoryBudget, 50_000_000)
    }

    // MARK: - Progress

    func testThrottleLetsThroughFirstLastAndOnePerInterval() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = Clock()
        let throttle = ProgressThrottle(interval: 0.1, clock: { clock.now })
        XCTAssertTrue(throttle.shouldReport(done: 1, total: 100))
        clock.now = 0.05
        XCTAssertFalse(throttle.shouldReport(done: 2, total: 100))
        clock.now = 0.11
        XCTAssertTrue(throttle.shouldReport(done: 3, total: 100))
        clock.now = 0.12
        XCTAssertFalse(throttle.shouldReport(done: 4, total: 100))
        XCTAssertTrue(throttle.shouldReport(done: 100, total: 100), "the last always lands")
    }

    /// Each progress report the Library publishes redraws the whole main
    /// window. Before, a pass published `thumbnailsDone` and
    /// `thumbnailsTotal` for every file: 2 × 60 here.
    func testAPassPublishesProgressAtABoundedRate() async throws {
        try writePictures(60)
        let library = Library()
        var progressPublishes = 0
        var bag: Set<AnyCancellable> = []
        library.$thumbnailsDone.dropFirst().sink { _ in progressPublishes += 1 }.store(in: &bag)
        library.$thumbnailsTotal.dropFirst().sink { _ in progressPublishes += 1 }.store(in: &bag)
        let start = Date()
        try await library.open(folder: root, defaultSubfolderMode: .included)
        try await waitForThumbnails(library)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(library.thumbnailsDone, 60)
        XCTAssertEqual(library.thumbnailsTotal, 60)
        // Resets at the start, first, last, and at most ten a second between.
        let bound = 6 + Int(seconds * 10) * 2
        print("PERF thumbnail progress: \(progressPublishes) publishes for 60 files in \(String(format: "%.2f", seconds)) s (was 120)")
        XCTAssertLessThanOrEqual(progressPublishes, bound)
        XCTAssertLessThan(progressPublishes, 120)
    }
}
