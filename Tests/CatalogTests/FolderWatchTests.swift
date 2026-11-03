import XCTest
import CoreServices
@testable import Catalog

/// Folder watching: which file-system events matter, the FSEvents stream
/// itself, and the Library following a folder changed in Finder.
final class FolderWatcherFilterTests: XCTestCase {
    private let root = "/Volumes/Photos/Shoot"
    private let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)
    private let dir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)

    func testRawFilesAndFoldersMatter() {
        XCTAssertTrue(FolderWatcher.isRelevant(path: "\(root)/A.NEF", flags: file, root: root))
        XCTAssertTrue(FolderWatcher.isRelevant(path: "\(root)/Day 2/b.cr3", flags: file, root: root))
        XCTAssertTrue(FolderWatcher.isRelevant(path: "\(root)/Day 2", flags: dir, root: root))
        XCTAssertTrue(FolderWatcher.isRelevant(path: "\(root)/A.jpg", flags: file, root: root),
                      "JPEG, HEIC, TIFF and PNG files are photos in the library too")
    }

    func testLatentsOwnFilesAndOtherFilesDont() {
        XCTAssertFalse(FolderWatcher.isRelevant(path: "\(root)/_latent/xmp/A.NEF.xmp", flags: file, root: root),
                       "a rating writes a sidecar; rescanning for it would loop")
        XCTAssertFalse(FolderWatcher.isRelevant(path: "\(root)/_latent/thumbnails", flags: dir, root: root))
        XCTAssertFalse(FolderWatcher.isRelevant(path: "\(root)/Day 2/_rawhead/catalog.sqlite", flags: file, root: root))
        XCTAssertFalse(FolderWatcher.isRelevant(path: "\(root)/.latent-rename-1234", flags: file, root: root),
                       "hidden temporary names of Latent's own moves")
        XCTAssertFalse(FolderWatcher.isRelevant(path: "\(root)/.DS_Store", flags: file, root: root))
        XCTAssertFalse(FolderWatcher.isRelevant(path: "\(root)/notes.txt", flags: file, root: root))
        XCTAssertFalse(FolderWatcher.isRelevant(path: "/Volumes/Photos/Other/A.NEF", flags: file, root: root))
        XCTAssertFalse(FolderWatcher.isRelevant(path: "/Volumes/Photos/Shoot2/A.NEF", flags: file, root: root))
    }

    func testLostEventsAlwaysRescan() {
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertTrue(FolderWatcher.isRelevant(path: "\(root)/_latent", flags: dropped, root: root))
        let moved = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        XCTAssertTrue(FolderWatcher.isRelevant(path: root, flags: moved, root: root))
    }
}

final class FolderWatcherStreamTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_latent"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testANewRawIsReportedAndLatentsOwnWritesAreNot() throws {
        let raw = expectation(description: "raw file seen")
        raw.assertForOverFulfill = false
        let calls = OSAllocatedUnfairLockBox()
        let watcher = try XCTUnwrap(FolderWatcher(root: folder, latency: 0.1) {
            calls.increment()
            raw.fulfill()
        })
        defer { watcher.stop() }
        // Give the stream a moment to start before anything changes.
        Thread.sleep(forTimeInterval: 0.3)
        try Data("sidecar".utf8).write(to: folder.appendingPathComponent("_latent/A.NEF.xmp"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(calls.value, 0, "only Latent's bookkeeping and a text file changed")
        try Data("raw".utf8).write(to: folder.appendingPathComponent("A.NEF"))
        wait(for: [raw], timeout: 10)
    }

    func testStopEndsTheCalls() throws {
        let calls = OSAllocatedUnfairLockBox()
        let watcher = try XCTUnwrap(FolderWatcher(root: folder, latency: 0.1) { calls.increment() })
        watcher.stop()
        try Data("raw".utf8).write(to: folder.appendingPathComponent("B.NEF"))
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(calls.value, 0)
    }
}

/// A counter the watcher's queue and the test can both touch.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// The Library following a folder changed outside Latent, end to end with
/// a real raw. Skips without one (see TestAssets/README.md).
@MainActor
final class LibraryFolderWatchTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-libwatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func testFilesCopiedInRenamedAndDeletedShowWithoutReopening() async throws {
        let library = Library()
        let watch = LibraryFolderWatch(library: library, debounce: .milliseconds(200))
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 1)
        XCTAssertNotNil(watch.watchedFolder)
        try await Task.sleep(for: .milliseconds(300))

        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        await waitUntil { library.images.count == 2 }
        XCTAssertEqual(Set(library.images.map(\.relPath)), ["A.NEF", "B.NEF"])

        let id = library.images.first { $0.relPath == "B.NEF" }?.id
        try FileManager.default.moveItem(at: folder.appendingPathComponent("B.NEF"),
                                         to: folder.appendingPathComponent("C.NEF"))
        await waitUntil { library.images.contains { $0.relPath == "C.NEF" } }
        XCTAssertEqual(library.images.first { $0.relPath == "C.NEF" }?.id, id, "a rename keeps the photo's row")

        try FileManager.default.removeItem(at: folder.appendingPathComponent("C.NEF"))
        await waitUntil { library.images.count == 1 }
        XCTAssertEqual(library.images.map(\.relPath), ["A.NEF"])
        await library.waitForPendingWork()
        XCTAssertNil(library.lastError)
    }

    func testOffWatchesNothingAndRefreshStillWorks() async throws {
        let library = Library()
        let watch = LibraryFolderWatch(library: library, isEnabled: false, debounce: .milliseconds(100))
        try await library.open(folder: folder)
        XCTAssertNil(watch.watchedFolder)
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(library.images.count, 1, "not watched")
        XCTAssertEqual(watch.refreshCount, 0)

        library.refreshFromDisk()
        await library.waitForPendingWork()
        XCTAssertEqual(library.images.count, 2, "File › Refresh Folder")

        watch.isEnabled = true
        XCTAssertNotNil(watch.watchedFolder)
    }

    func testABurstOfChangesIsOneRefresh() async throws {
        let library = Library()
        let watch = LibraryFolderWatch(library: library, debounce: .milliseconds(400))
        try await library.open(folder: folder)
        for _ in 0..<5 { watch.changesSeen() }
        try await Task.sleep(for: .milliseconds(900))
        await library.waitForPendingWork()
        XCTAssertEqual(watch.refreshCount, 1)
    }
}
