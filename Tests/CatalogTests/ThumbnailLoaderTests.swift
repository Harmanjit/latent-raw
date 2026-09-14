import XCTest
import CoreGraphics
@testable import Catalog

private func fakeURL(_ id: Int64) -> URL { URL(fileURLWithPath: "/nonexistent/\(id).heic") }

/// Requests a thumbnail and waits for it.
private func thumbnail(_ loader: ThumbnailLoader, _ id: Int64, turns: Int = 0,
                       pixelSize: Int = 512, url: URL? = nil) async -> CGImage? {
    let boxed: ThumbnailImage? = await withCheckedContinuation { continuation in
        loader.request(id: id, url: url ?? fakeURL(id), quarterTurns: turns, pixelSize: pixelSize) { image in
            continuation.resume(returning: image.map(ThumbnailImage.init))
        }
    }
    return boxed?.cgImage
}

/// The grid's thumbnail loader, with a stand-in decoder so decodes can be
/// counted and ordered without real files.
@MainActor
final class ThumbnailLoaderTests: XCTestCase {
    /// A solid image `maxPixelSize` wide and half as tall.
    nonisolated static func fakeDecode(_ url: URL, _ maxPixelSize: Int) -> CGImage? {
        guard url.lastPathComponent != "broken" else { return nil }
        return solidImage(width: maxPixelSize, height: maxPixelSize / 2)
    }

    nonisolated static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private func loader(bytes: Int = 100_000_000, workers: Int = 1) -> ThumbnailLoader {
        ThumbnailLoader(memoryCacheBytes: bytes, workerLimit: workers, decode: Self.fakeDecode)
    }

    private func url(_ id: Int64) -> URL { fakeURL(id) }

    @MainActor final class Recorder {
        var ids: [Int64] = []
    }

    func testTierSelection() {
        XCTAssertEqual(ThumbnailLoader.tier(forPixelSize: 1), 256)
        XCTAssertEqual(ThumbnailLoader.tier(forPixelSize: 256), 256)
        XCTAssertEqual(ThumbnailLoader.tier(forPixelSize: 257), 512)
        XCTAssertEqual(ThumbnailLoader.tier(forPixelSize: 4000), 512)
    }

    func testLoadsDisplayReadyAndCaches() async throws {
        let loader = loader()
        let loaded = await thumbnail(loader, 1)
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.bitmapInfo.rawValue, ThumbnailLoader.displayBitmapInfo, "BGRA, premultiplied")
        XCTAssertTrue(loader.cachedImage(id: 1, quarterTurns: 0, pixelSize: 512) === image)
        XCTAssertTrue(loader.cachedImage(id: 1, quarterTurns: 0, pixelSize: 200) === image,
                      "a larger tier satisfies a smaller request")
        XCTAssertNil(loader.cachedImage(id: 1, quarterTurns: 1, pixelSize: 512), "rotation is part of the key")
        _ = await thumbnail(loader, 1)
        XCTAssertEqual(loader.statistics.decodes, 1, "the second request is served from memory")
    }

    /// The memory cache never holds more than its budget, and evicts the
    /// thumbnails used longest ago.
    func testMemoryCacheStaysWithinBudget() async throws {
        // Each fake 512 thumbnail is 512 × 256 × 4 bytes; room for three.
        let one = 512 * 256 * 4
        let loader = loader(bytes: one * 3 + one / 2)
        for id in Int64(1)...3 { _ = await thumbnail(loader, id) }
        XCTAssertEqual(loader.cachedBytes, one * 3)
        _ = loader.cachedImage(id: 1, quarterTurns: 0, pixelSize: 512)   // 1 is now the most recent
        _ = await thumbnail(loader, 4)
        XCTAssertLessThanOrEqual(loader.cachedBytes, one * 3 + one / 2)
        XCTAssertNil(loader.cachedImage(id: 2, quarterTurns: 0, pixelSize: 512), "least recently used went first")
        XCTAssertNotNil(loader.cachedImage(id: 1, quarterTurns: 0, pixelSize: 512))
        XCTAssertNotNil(loader.cachedImage(id: 4, quarterTurns: 0, pixelSize: 512))
    }

    /// Queued requests run newest first, and asking again for a queued
    /// thumbnail moves it to the front and shares its decode.
    func testRunsNewestRequestFirst() async {
        let loader = loader()
        let recorder = Recorder()
        loader.setSuspended(true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var remaining = 5
            for id: Int64 in [1, 2, 3, 4, 2] {
                loader.request(id: id, url: url(id), quarterTurns: 0, pixelSize: 512) { _ in
                    recorder.ids.append(id)
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
            loader.setSuspended(false)
        }
        XCTAssertEqual(recorder.ids, [2, 2, 4, 3, 1])
        XCTAssertEqual(loader.statistics.decodes, 4)
    }

    /// What a fling does: every cell flown past asks for its thumbnail and
    /// cancels when it scrolls away. Only the screenful where the scroll
    /// stops is decoded.
    func testScrollingPastCancelsWithoutDecoding() async {
        let loader = loader(workers: 2)
        let recorder = Recorder()
        loader.setSuspended(true)
        var requests: [ThumbnailRequest] = []
        for id in Int64(0)..<2000 {
            requests.append(loader.request(id: id, url: url(id), quarterTurns: 0, pixelSize: 256) { _ in
                recorder.ids.append(id)
            })
            // A screenful of 40 stays on screen; older rows have scrolled away.
            if requests.count > 40 { requests.removeFirst().cancel() }
        }
        let landed = Set(Int64(1960)..<2000)
        loader.setSuspended(false)
        let deadline = Date().addingTimeInterval(10)
        while recorder.ids.count < 40, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(Set(recorder.ids), landed, "only the rows the scroll stopped on complete")
        XCTAssertEqual(loader.statistics.decodes, 40)
        XCTAssertEqual(loader.statistics.skippedCancelled, 1960)
    }

    func testIdenticalRequestsShareOneDecode() async {
        let loader = loader(workers: 4)
        async let a = thumbnail(loader, 7)
        async let b = thumbnail(loader, 7)
        let (first, second) = await (a, b)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertEqual(loader.statistics.decodes, 1)
    }

    /// Turning an image reuses the thumbnail already in memory instead of
    /// decoding the file again.
    func testRotationTurnsTheCachedThumbnail() async throws {
        let loader = loader()
        _ = await thumbnail(loader, 3)
        let loaded = await thumbnail(loader, 3, turns: 1)
        let turned = try XCTUnwrap(loaded)
        XCTAssertEqual(turned.width, 256)
        XCTAssertEqual(turned.height, 512)
        XCTAssertEqual(loader.statistics.decodes, 1)
        XCTAssertTrue(loader.cachedImage(id: 3, quarterTurns: 5, pixelSize: 512) === turned, "5 turns is 1")
    }

    func testInvalidateDecodesAgain() async {
        let loader = loader()
        let before = await thumbnail(loader, 9)
        loader.invalidate(ids: [9])
        XCTAssertNil(loader.cachedImage(id: 9, quarterTurns: 0, pixelSize: 512))
        let after = await thumbnail(loader, 9)
        XCTAssertNotNil(after)
        XCTAssertFalse(before === after)
        XCTAssertEqual(loader.statistics.decodes, 2)
    }

    /// Switching catalogs: queued requests finish with nil rather than
    /// hanging, and nothing decoded for the old catalog is cached.
    func testRemoveAllDropsQueuedWork() async {
        let loader = loader()
        loader.setSuspended(true)
        async let queued = thumbnail(loader, 11)
        try? await Task.sleep(for: .milliseconds(50))
        loader.removeAll()
        loader.setSuspended(false)
        let result = await queued
        XCTAssertNil(result)
        XCTAssertEqual(loader.statistics.decodes, 0)
        XCTAssertNil(loader.cachedImage(id: 11, quarterTurns: 0, pixelSize: 512))
    }

    func testCancelledRequestNeverCompletes() async {
        let loader = loader()
        let recorder = Recorder()
        loader.setSuspended(true)
        let request = loader.request(id: 5, url: url(5), quarterTurns: 0, pixelSize: 512) { _ in recorder.ids.append(5) }
        request.cancel()
        XCTAssertTrue(request.isCancelled)
        loader.setSuspended(false)
        _ = await thumbnail(loader, 6)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.ids, [])
        XCTAssertEqual(loader.statistics.decodes, 1, "only the other request decoded")
    }

    /// A file that exists but won't decode fails once; one that's missing
    /// (generation still writing it) is tried again next time.
    func testFailuresRememberedOnlyForExistingFiles() async throws {
        let loader = loader()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = folder.appendingPathComponent("broken")
        try Data([0, 1, 2]).write(to: broken)

        var result = await thumbnail(loader, 20, url: broken)
        XCTAssertNil(result)
        result = await thumbnail(loader, 20, url: broken)
        XCTAssertNil(result)
        XCTAssertEqual(loader.statistics.decodes, 1, "remembered")
        loader.invalidate(ids: [20])
        result = await thumbnail(loader, 20, url: broken)
        XCTAssertNil(result)
        XCTAssertEqual(loader.statistics.decodes, 2, "invalidating forgets the failure")

        let missing = folder.appendingPathComponent("gone").appendingPathComponent("broken")
        result = await thumbnail(loader, 21, url: missing)
        XCTAssertNil(result)
        result = await thumbnail(loader, 21, url: missing)
        XCTAssertNil(result)
        XCTAssertEqual(loader.statistics.decodes, 4, "a missing file is tried again")
    }

    /// A quarter turn clockwise puts the left edge on top, in BGRA.
    func testDisplayReadyTurnsClockwise() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let source = try XCTUnwrap(context.makeImage())

        let turned = ThumbnailLoader.displayReady(source, quarterTurns: 1, in: CGColorSpace(name: CGColorSpace.sRGB)!)
        XCTAssertEqual(turned.width, 1)
        XCTAssertEqual(turned.height, 2)
        let bytes = try XCTUnwrap(turned.dataProvider?.data as Data?)
        let row = turned.bytesPerRow
        // B, G, R, A: the top row is red, the bottom blue.
        XCTAssertEqual(Array(bytes[0..<4]), [0, 0, 255, 255])
        XCTAssertEqual(Array(bytes[row..<(row + 4)]), [255, 0, 0, 255])
    }
}

final class ByteBoundedCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedToStayWithinBudget() {
        let cache = ByteBoundedCache<String, Int>(budget: 30)
        cache.insert(1, forKey: "a", cost: 10)
        cache.insert(2, forKey: "b", cost: 10)
        cache.insert(3, forKey: "c", cost: 10)
        XCTAssertEqual(cache.totalCost, 30)
        XCTAssertEqual(cache.value(forKey: "a"), 1)   // a is now the most recent
        cache.insert(4, forKey: "d", cost: 10)
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.keysByRecency, ["d", "a", "c"])
        XCTAssertEqual(cache.totalCost, 30)
    }

    func testReplacingAndRemovingKeepTheCostRight() {
        let cache = ByteBoundedCache<String, Int>(budget: 100)
        cache.insert(1, forKey: "a", cost: 40)
        cache.insert(2, forKey: "a", cost: 20)
        XCTAssertEqual(cache.totalCost, 20)
        XCTAssertEqual(cache.count, 1)
        cache.insert(3, forKey: "b", cost: 30)
        cache.remove("a")
        XCTAssertEqual(cache.totalCost, 30)
        cache.removeAll { $0 == "b" }
        XCTAssertEqual(cache.totalCost, 0)
        XCTAssertEqual(cache.keysByRecency, [])
    }

    func testOversizedValueIsNotKeptAndLoweringTheBudgetEvicts() {
        let cache = ByteBoundedCache<String, Int>(budget: 50)
        cache.insert(1, forKey: "small", cost: 20)
        cache.insert(2, forKey: "huge", cost: 60)
        XCTAssertNil(cache.value(forKey: "huge"))
        XCTAssertEqual(cache.value(forKey: "small"), 1, "the cache wasn't emptied for it")
        cache.insert(3, forKey: "other", cost: 20)
        cache.budget = 25
        XCTAssertEqual(cache.keysByRecency, ["other"])
        XCTAssertLessThanOrEqual(cache.totalCost, 25)
    }
}
