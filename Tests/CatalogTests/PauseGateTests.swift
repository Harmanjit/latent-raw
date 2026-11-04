import XCTest
@testable import Catalog

/// The Pause switch background jobs read between items, and thumbnail
/// generation honouring it.
final class PauseGateTests: XCTestCase {
    var folder: URL?

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testDoesNotWaitWhenRunning() async {
        let gate = PauseGate()
        let waited = await gate.waitWhilePaused()
        XCTAssertFalse(waited)
        XCTAssertFalse(gate.isPaused)
    }

    func testWaitsUntilResumed() async throws {
        let gate = PauseGate()
        gate.pause()
        let waiter = Task { await gate.waitWhilePaused() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(gate.isPaused)
        gate.resume()
        let waited = await waiter.value
        XCTAssertTrue(waited)
    }

    /// Cancelling a paused job (Cancel, quitting, closing the catalog)
    /// ends the wait without resuming the gate.
    func testCancellingEndsTheWait() async {
        let gate = PauseGate()
        gate.pause()
        let waiter = Task { () -> Bool in
            _ = await gate.waitWhilePaused()
            return Task.isCancelled
        }
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(gate.isPaused, "still paused: cancelling is not resuming")
    }

    private func catalogWithOnePhoto() async throws -> Catalog {
        let sample = try TestAssets.d750Path()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-pause-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: sample, toPath: folder.appendingPathComponent("A.NEF").path)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        return catalog
    }

    /// A paused pass starts no file; on Resume it makes it.
    func testThumbnailPassHoldsWhilePaused() async throws {
        let catalog = try await catalogWithOnePhoto()
        let gate = PauseGate()
        gate.pause()
        let pass = Task { try await catalog.generateMissingThumbnails(pause: gate) }
        try await Task.sleep(for: .milliseconds(400))
        let url = await catalog.thumbnailURL(forRelPath: "A.NEF")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing starts while paused")
        gate.resume()
        let report = try await pass.value
        XCTAssertEqual(report.generated, 1, "\(report.failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Cancelled while paused (the catalog closed), the pass ends quietly
    /// without making anything.
    func testThumbnailPassCancelledWhilePausedEnds() async throws {
        let catalog = try await catalogWithOnePhoto()
        let gate = PauseGate()
        gate.pause()
        let pass = Task { try await catalog.generateMissingThumbnails(pause: gate) }
        try await Task.sleep(for: .milliseconds(200))
        pass.cancel()
        let report = try await pass.value
        XCTAssertEqual(report.generated, 0)
        let needed = try await catalog.imagesNeedingThumbnails().count
        XCTAssertEqual(needed, 1, "left for the next pass")
    }
}
