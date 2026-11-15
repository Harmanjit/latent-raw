import XCTest
import RawCore
@testable import latent_app

/// The bounded cache of decodes behind photo switching (plan fix #17).
/// A metadata-only read of the D750 raw stands in for the decode, so the
/// tests are quick; a gate holds the decode queues where order matters.
@MainActor
final class RawDecodeCacheTests: XCTestCase {
    /// Holds the stand-in decodes while set.
    nonisolated(unsafe) private static var hold: DecodeGate?
    nonisolated(unsafe) private var decodes: DecodeCounter!

    override func setUp() async throws {
        let source = try TestAssets.d750URL()
        let counter = DecodeCounter()
        decodes = counter
        RawDecodeJob.decode = { url in
            Self.hold?.wait()
            counter.add(url)
            return try RawFile(path: source.path, metadataOnly: true)
        }
    }

    override func tearDown() async throws {
        Self.hold?.open()
        Self.hold = nil
        RawDecodeJob.decode = { try EditorModel.decodeForOpening($0) }
        RawDecodeJob.bytesOf = { $0.sensorPlane?.allocationLength ?? $0.linearPlane?.allocationLength ?? 0 }
    }

    private func holdDecodes() -> DecodeGate {
        let gate = DecodeGate()
        Self.hold = gate
        return gate
    }

    /// Distinct (empty) files: the stand-in decode never reads them.
    private func files(_ count: Int) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-decode-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try (0..<count).map { i in
            let url = folder.appendingPathComponent("F\(i).NEF")
            try Data([UInt8(i)]).write(to: url)
            return url
        }
    }

    func testAKeptDecodeIsReusedAndTheOldestGoesPastTheBudget() async throws {
        let cache = RawDecodeCache(maxEntries: 2)
        let urls = try files(3)
        _ = try await cache.jobForOpening(urls[0]).value()
        cache.prefetch([urls[1]], keeping: urls[0])
        _ = try await cache.jobForOpening(urls[1]).value()
        XCTAssertNotNil(cache.decodedFile(for: urls[0]))
        _ = try await cache.jobForOpening(urls[0]).value()
        XCTAssertEqual(decodes.count(urls[0]), 1, "kept, not decoded again")
        // A third file: the least recently used one (urls[1]) goes.
        _ = try await cache.jobForOpening(urls[2]).value()
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.decodedFile(for: urls[1]))
        XCTAssertNotNil(cache.decodedFile(for: urls[0]))
    }

    /// A held arrow key: opens queued behind a running decode are dropped
    /// when a newer one comes, so only the running one and the newest
    /// decode.
    func testOnlyTheNewestQueuedOpenDecodes() async throws {
        let cache = RawDecodeCache()
        let urls = try files(3)
        let hold = holdDecodes()
        let running = cache.jobForOpening(urls[0])
        for _ in 0..<400 where !running.hasStarted { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(running.hasStarted)
        let passed = cache.jobForOpening(urls[1])
        let newest = cache.jobForOpening(urls[2])
        XCTAssertTrue(passed.isFinished && passed.file == nil, "dropped at once, undecoded")
        hold.open()
        do {
            _ = try await passed.value()
            XCTFail("the passed photo's decode was dropped")
        } catch is CancellationError {}
        _ = try await running.value()
        _ = try await newest.value()
        XCTAssertEqual(decodes.count(urls[1]), 0)
        XCTAssertEqual(decodes.count(urls[2]), 1)
    }

    /// A file rewritten since its decode is decoded again.
    func testAChangedFileIsDecodedAgain() async throws {
        let cache = RawDecodeCache()
        let url = try files(1)[0]
        _ = try await cache.jobForOpening(url).value()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: url.path)
        XCTAssertNil(cache.decodedFile(for: url))
        _ = try await cache.jobForOpening(url).value()
        XCTAssertEqual(decodes.count(url), 2)
    }

    /// Memory pressure drops what is kept but not a photo being opened.
    func testMemoryPressureKeepsAnOpenUnderWay() async throws {
        let cache = RawDecodeCache()
        let urls = try files(2)
        _ = try await cache.jobForOpening(urls[0]).value()
        let hold = holdDecodes()
        let opening = cache.jobForOpening(urls[1])
        cache.removeAll(keepingOpens: true)
        XCTAssertEqual(cache.keptPaths, [urls[1].standardizedFileURL.path])
        hold.open()
        _ = try await opening.value()
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    /// Neighbours queued for an earlier photo and not wanted now never
    /// start.
    func testStaleNeighboursAreDroppedBeforeTheyStart() async throws {
        let cache = RawDecodeCache(maxEntries: 5)
        let urls = try files(4)
        let hold = holdDecodes()
        cache.prefetch([urls[0], urls[1]], keeping: nil)
        cache.prefetch([urls[2], urls[3]], keeping: nil)
        hold.open()
        _ = try await cache.jobForOpening(urls[3]).value()
        _ = try await cache.jobForOpening(urls[2]).value()
        // urls[0] may have begun before the second prefetch; urls[1] can't have.
        XCTAssertEqual(decodes.count(urls[1]), 0)
        XCTAssertFalse(cache.keptPaths.contains(urls[1].standardizedFileURL.path))
    }

    /// Waits for the main-actor trims that follow finished decodes.
    private func settle(_ cache: RawDecodeCache) async throws {
        for job in cache.keptJobs { _ = try? await job.value() }
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Large decodes (a folder of linear merges): a neighbour whose
    /// estimated size doesn't fit beside the open photo isn't decoded.
    func testANeighbourThatWouldPassTheByteBudgetIsNotDecoded() async throws {
        RawDecodeJob.bytesOf = { _ in 100 }
        let cache = RawDecodeCache(maxEntries: 3, maxBytes: 250)
        cache.estimatedBytes = { _, _ in 100 }
        let urls = try files(3)
        _ = try await cache.jobForOpening(urls[0]).value()
        cache.prefetch([urls[1], urls[2]], keeping: urls[0])
        try await settle(cache)
        XCTAssertLessThanOrEqual(cache.totalBytes, 250)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.decodedFile(for: urls[0]), "the open photo is kept")
        XCTAssertEqual(decodes.count(urls[2]), 0, "the second neighbour didn't fit and wasn't decoded")
    }

    /// Neighbours guessed small but decoding large are dropped once their
    /// real size is known, so the cache doesn't sit past the budget.
    func testNeighboursGuessedLowAreTrimmedOnceDecoded() async throws {
        RawDecodeJob.bytesOf = { _ in 100 }
        let cache = RawDecodeCache(maxEntries: 3, maxBytes: 250)
        cache.estimatedBytes = { _, _ in 10 }
        let urls = try files(3)
        _ = try await cache.jobForOpening(urls[0]).value()
        cache.prefetch([urls[1], urls[2]], keeping: urls[0])
        XCTAssertEqual(cache.count, 3, "both fit by their guesses")
        try await settle(cache)
        XCTAssertLessThanOrEqual(cache.totalBytes, 250)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.decodedFile(for: urls[0]), "the open photo is kept")
    }

    /// The open photo alone may be past the budget; then no neighbour is
    /// decoded, and neighbours kept from before are dropped.
    func testAnOpenPhotoPastTheBudgetKeepsNoNeighbours() async throws {
        RawDecodeJob.bytesOf = { _ in 100 }
        let cache = RawDecodeCache(maxEntries: 3, maxBytes: 250)
        cache.estimatedBytes = { _, _ in 100 }
        let urls = try files(4)
        _ = try await cache.jobForOpening(urls[0]).value()
        cache.prefetch([urls[1]], keeping: urls[0])
        try await settle(cache)
        XCTAssertEqual(cache.count, 2)
        // Stepping on to a far larger photo.
        RawDecodeJob.bytesOf = { _ in 400 }
        cache.estimatedBytes = { _, _ in 400 }
        _ = try await cache.jobForOpening(urls[3]).value()
        cache.prefetch([urls[2]], keeping: urls[3])
        try await settle(cache)
        XCTAssertEqual(cache.keptPaths, [urls[3].standardizedFileURL.path])
        XCTAssertEqual(decodes.count(urls[2]), 0)
    }
}
