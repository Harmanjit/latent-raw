import XCTest
@testable import Catalog

/// Holds whatever waits on it until opened, and tells the test when the
/// first waiter has arrived: how a test keeps one open or change in the
/// middle while another runs to the end.
actor Gate {
    private var isOpen = false
    private var hasArrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func arrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Saves that land after another folder has opened. The editor hands an
/// edit over by catalog id, and the write runs a moment later; in the
/// next folder's catalog that id is a different photo.
@MainActor
final class FolderSwitchTests: XCTestCase {
    nonisolated(unsafe) var first: URL!
    nonisolated(unsafe) var second: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("latent-switch-\(UUID().uuidString)", isDirectory: true)
        first = base.appendingPathComponent("First", isDirectory: true)
        second = base.appendingPathComponent("Second", isDirectory: true)
        for (folder, name) in [(first!, "A.NEF"), (second!, "Z.NEF")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: ReconcileTests.sampleNEF, toPath: folder.appendingPathComponent(name).path)
        }
    }

    override func tearDownWithError() throws {
        if let first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    }

    func testEditSavedAfterASwitchLandsInItsOwnCatalog() async throws {
        let library = Library()
        try await library.open(folder: first)
        let oldCatalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first)

        try await library.open(folder: second)
        let z = try XCTUnwrap(library.images.first)
        XCTAssertEqual(a.id, z.id, "the hazard: each catalog's first image has the same id")

        let json = "{\"schema\":1}"
        try await library.saveEditStack(json, schemaVersion: 1, processVersion: "1.0", forImageID: a.id!, in: oldCatalog)
        try await library.setHistory([(json, 1)], forImageID: a.id!, in: oldCatalog)
        try await library.setSnapshots([("Look", json)], forImageID: a.id!, in: oldCatalog)

        let stored = try await oldCatalog.editStack(forImageID: a.id!)
        XCTAssertEqual(stored, json)
        let history = try await oldCatalog.history(forImageID: a.id!)
        XCTAssertEqual(history.count, 1)
        let untouched = try await library.editStack(for: z)
        XCTAssertNil(untouched, "the open catalog's photo with the same id is left alone")
        let snapshots = try await library.snapshots(for: z)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertFalse(library.editedImageIDs.contains(z.id!), "the grid's edited badges follow the open catalog")
    }

    /// Folder A is slow to reconcile, so the user clicks folder B, which
    /// opens first. A's list arriving afterwards must not be shown under
    /// B's catalog, where its ids are other photos.
    func testOvertakenOpenNeverShowsItsList() async throws {
        let library = Library()
        let gate = Gate()
        library.willPublishList = { catalog in
            if await catalog.rootPath.lastPathComponent == "First" { await gate.wait() }
        }
        let slow = Task { try await library.open(folder: first) }
        await gate.arrival()

        let opened = try await library.open(folder: second)
        XCTAssertTrue(opened)
        XCTAssertTrue(library.isBusy, "the first open is still running")
        await gate.open()
        let slowShown = try await slow.value

        XCTAssertFalse(slowShown, "overtaken")
        XCTAssertFalse(library.isBusy)
        XCTAssertEqual(library.folderURL?.lastPathComponent, "Second")
        let root = try await XCTUnwrap(library.catalog).rootPath
        XCTAssertEqual(root.lastPathComponent, "Second")
        XCTAssertEqual(library.images.map(\.fileName), ["Z.NEF"])
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["Z.NEF"])
    }

    /// The same for a refresh of the folder being left.
    func testRefreshOfAFolderLeftBehindIsDropped() async throws {
        let library = Library()
        try await library.open(folder: first)
        let gate = Gate()
        library.willPublishList = { catalog in
            if await catalog.rootPath.lastPathComponent == "First" { await gate.wait() }
        }
        let refresh = Task { try await library.refresh() }
        await gate.arrival()
        try await library.open(folder: second)
        await gate.open()
        try await refresh.value

        XCTAssertEqual(library.folderURL?.lastPathComponent, "Second")
        XCTAssertEqual(library.images.map(\.fileName), ["Z.NEF"])
    }

    /// While the next folder loads, the Library is still wholly the open
    /// one's, so a key pressed then changes the photo on screen; it switches
    /// in one step, telling the app first while the old catalog is open.
    func testLibraryStaysOnTheOpenCatalogUntilTheNextListIsReady() async throws {
        let library = Library()
        try await library.open(folder: first)
        let oldCatalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first)
        library.setSelection([a.id!], primary: a.id)

        @MainActor final class Box { var catalogWhenTold: Catalog? }
        let box = Box()
        library.willReplaceCatalog = { box.catalogWhenTold = library.catalog }
        let gate = Gate()
        library.willPublishList = { catalog in
            if await catalog.rootPath.lastPathComponent == "Second" { await gate.wait() }
        }
        let opening = Task { try await library.open(folder: second) }
        await gate.arrival()

        XCTAssertTrue(library.catalog === oldCatalog)
        XCTAssertEqual(library.folderURL?.lastPathComponent, "First")
        XCTAssertEqual(library.images.map(\.fileName), ["A.NEF"])
        XCTAssertEqual(library.selectedImageID, a.id)
        try await library.setRating(2)
        let rated = try await oldCatalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(rated?.rating, 2)

        await gate.open()
        _ = try await opening.value
        XCTAssertTrue(box.catalogWhenTold === oldCatalog, "told before the switch")
        XCTAssertEqual(library.folderURL?.lastPathComponent, "Second")
        XCTAssertEqual(library.images.map(\.fileName), ["Z.NEF"])
        XCTAssertEqual(library.images.first?.rating, 0)
        XCTAssertNil(library.selectedImageID)
    }

    /// A folder that fails to open (here an included subfolder that can't
    /// be read) leaves the open folder as it was, not its catalog paired
    /// with the old folder's records.
    func testFailedOpenLeavesTheOpenFolderWhole() async throws {
        let library = Library()
        try await library.open(folder: first)
        let oldCatalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first)
        let status = library.statusText

        let locked = second.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        do {
            try await library.open(folder: second, defaultSubfolderMode: .included)
            XCTFail("an unreadable included subfolder fails the reconcile")
        } catch {}

        XCTAssertTrue(library.catalog === oldCatalog)
        XCTAssertEqual(library.folderURL?.lastPathComponent, "First")
        XCTAssertEqual(library.images.map(\.fileName), ["A.NEF"])
        XCTAssertEqual(library.statusText, status)
        XCTAssertFalse(library.isBusy)
        XCTAssertNotNil(library.requestDisplayThumbnail(for: a, pixelSize: 256) { _ in },
                        "thumbnails still load for the open folder")
    }

    /// A batch rating still writing when another folder opens: the writes
    /// finish in their own catalog, and the re-read records are not patched
    /// into the new folder's list under the same ids.
    func testChangeFinishingAfterASwitchLeavesTheNewListAlone() async throws {
        let library = Library()
        try await library.open(folder: first)
        let oldCatalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first)

        let gate = Gate()
        let rating = Task {
            try await library.change([a]) { catalog, id, _ in
                await gate.wait()
                try await catalog.setRating(3, forImageID: id)
            }
        }
        await gate.arrival()
        try await library.open(folder: second)
        let z = try XCTUnwrap(library.images.first)
        XCTAssertEqual(a.id, z.id, "the hazard: the same id in both catalogs")
        await gate.open()
        try await rating.value

        XCTAssertEqual(library.images.map(\.fileName), ["Z.NEF"])
        XCTAssertEqual(library.images.first?.rating, 0)
        XCTAssertEqual(library.visibleImages.first?.fileName, "Z.NEF")
        let written = try await oldCatalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(written?.rating, 3, "the write stays in the catalog it was made in")
        let untouched = try await XCTUnwrap(library.catalog).image(forRelPath: "Z.NEF")
        XCTAssertEqual(untouched?.rating, 0)
    }
}
