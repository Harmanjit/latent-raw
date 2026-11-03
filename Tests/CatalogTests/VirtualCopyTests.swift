import XCTest
import GRDB
@testable import Catalog

/// Virtual copies: their paths, their rows and sidecars, how they follow
/// their master through reconcile, moves and renames, and undo.
@MainActor
final class VirtualCopyTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-vcopies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private static let edit = #"{"exposure":0.5}"#

    private func openLibrary(_ manager: UndoManager = UndoManager()) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        library.fileOperations.recycle = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        try await library.open(folder: folder)
        return library
    }

    private func record(_ library: Library, _ name: String) -> ImageRecord? {
        library.images.first { $0.fileName == name }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Paths

    func testCopyPathsRoundTripAndNeverMatchAFile() {
        let key = VirtualCopy.Key(number: 2, token: "1a2b3c4d")
        let path = VirtualCopy.relPath(master: "Day 2/DSC_0107.NEF", key: key)
        XCTAssertEqual(path, "Day 2/DSC_0107.NEF#vc002-1a2b3c4d")
        let parsed = VirtualCopy.parse(path)
        XCTAssertEqual(parsed?.masterRelPath, "Day 2/DSC_0107.NEF")
        XCTAssertEqual(parsed?.key, key)
        XCTAssertEqual(VirtualCopy.fileRelPath(path), "Day 2/DSC_0107.NEF")
        XCTAssertEqual(VirtualCopy.parse(VirtualCopy.relPath(master: "a#vc.NEF", key: VirtualCopy.Key(number: 12, token: "ffffffff")))?.key.number, 12)

        for plain in ["DSC_0107.NEF", "a/b.NEF", "#vc001-1a2b3c4d", "x#vc01-1a2b3c4d", "x#vc001-1A2B3C4D",
                      "x#vc001-1a2b3c4", "x#vcabc-1a2b3c4d", "x#xc001-1a2b3c4d", "é#vc0"] {
            XCTAssertNil(VirtualCopy.parse(plain), plain)
            XCTAssertEqual(VirtualCopy.fileRelPath(plain), plain)
        }
        XCTAssertEqual(VirtualCopy.key(fromCompanionName: "vc002-1a2b3c4d.xmp"), key)
        XCTAssertNil(VirtualCopy.key(fromCompanionName: "DSC_0107.NEF.xmp"))
        XCTAssertEqual(VirtualCopy.displayName(fileName: "DSC_0107.NEF", number: 2), "DSC_0107 (Copy 2).NEF")
    }

    // MARK: Making a copy

    func testACopyIsItsOwnRowSharingTheMastersFile() async throws {
        let library = try await openLibrary()
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        try await catalog.setEditStack(Self.edit, forImageID: a.id!)
        try await catalog.setRating(3, forImageID: a.id!)
        try await catalog.setKeywords(["coast"], forImageID: a.id!)
        try await catalog.setSnapshots([("Before", Self.edit)], forImageID: a.id!)

        library.setSelection([a.id!], primary: a.id)
        let ids = try await library.createVirtualCopies(of: [a])
        let copy = try XCTUnwrap(library.images.first { $0.id == ids.first })
        XCTAssertTrue(copy.isVirtualCopy)
        XCTAssertEqual(copy.fileName, "A (Copy 1).NEF")
        XCTAssertEqual(copy.sourceFileName, "A.NEF")
        XCTAssertEqual(library.fileURL(for: copy)?.lastPathComponent, "A.NEF", "the copy opens its master's file")
        XCTAssertEqual(library.selectedImageID, copy.id, "the new copy is selected")
        XCTAssertEqual(copy.rating, 3)
        XCTAssertEqual(copy.xxhash, a.xxhash)
        let value1 = try await catalog.editStack(forImageID: copy.id!)
        XCTAssertEqual(value1, Self.edit)
        let value2 = try await catalog.keywords(forImageID: copy.id!)
        XCTAssertEqual(value2, ["coast"])
        let value3 = try await catalog.snapshots(forImageID: copy.id!).isEmpty
        XCTAssertTrue(value3, "snapshots are the copy's own")
        let value4 = try await catalog.history(forImageID: copy.id!).isEmpty
        XCTAssertTrue(value4)
        let value5 = try await catalog.masterID(ofImageID: copy.id!)
        XCTAssertEqual(value5, a.id)
        XCTAssertTrue(library.editedImageIDs.contains(copy.id!))

        // Its sidecar is named by its key and carries the master's hash.
        let sidecar = await catalog.sidecarURL(forRelPath: copy.relPath)
        XCTAssertEqual(sidecar.deletingLastPathComponent().lastPathComponent, VirtualCopy.companionFolder)
        let fields = try XMPSidecar.read(from: sidecar)
        XCTAssertEqual(fields.sourceHash, a.hashString)
        XCTAssertEqual(fields.rating, 3)
        XCTAssertEqual(fields.editStackJSON, Self.edit)

        // Next to its master under each sort.
        for key in [LibrarySortKey.captureTime, .fileName] {
            library.sort = LibrarySort(key: key, ascending: true)
            let names = library.visibleImages.map(\.fileName)
            XCTAssertEqual(names.firstIndex(of: "A (Copy 1).NEF"), names.firstIndex(of: "A.NEF")! + 1, "\(key): \(names)")
        }

        // Rated on its own; a copy of the copy is the master's second.
        library.setSelection([copy.id!], primary: copy.id)
        try await library.setRating(5)
        XCTAssertEqual(record(library, "A.NEF")?.rating, 3)
        XCTAssertEqual(record(library, "A (Copy 1).NEF")?.rating, 5)
        let second = try await library.createVirtualCopies(of: [try XCTUnwrap(record(library, "A (Copy 1).NEF"))])
        let copy2 = try XCTUnwrap(library.images.first { $0.id == second.first })
        XCTAssertEqual(copy2.fileName, "A (Copy 2).NEF")
        XCTAssertEqual(copy2.rating, 5, "copied from the copy it was made from")
        let value6 = try await catalog.masterID(ofImageID: copy2.id!)
        XCTAssertEqual(value6, a.id)
    }

    func testCopiesGetThumbnailsFromTheMastersFile() async throws {
        let library = try await openLibrary()
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        let copyID = try await catalog.createVirtualCopy(of: a.id!).id
        let all = try await catalog.allImages()
        let copyPath = try XCTUnwrap(all.first { $0.id == copyID }?.relPath)
        let thumbnail = await catalog.thumbnailURL(forRelPath: copyPath)
        try? FileManager.default.removeItem(at: thumbnail)
        let report = try await catalog.generateMissingThumbnails()
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertTrue(exists(thumbnail))
        XCTAssertEqual(thumbnail.deletingLastPathComponent().lastPathComponent, VirtualCopy.companionFolder)
    }

    // MARK: Following the master

    func testCopiesFollowARenameInFinderAndGoWithTheirMaster() async throws {
        let library = try await openLibrary()
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        let archive = try await catalog.createVirtualCopy(of: a.id!)
        try await catalog.setEditStack(Self.edit, forImageID: archive.id)
        try await catalog.setRating(4, forImageID: archive.id)

        try FileManager.default.moveItem(at: folder.appendingPathComponent("A.NEF"),
                                         to: folder.appendingPathComponent("Sunset.NEF"))
        try await library.refresh()
        let copy = try XCTUnwrap(library.images.first { $0.id == archive.id })
        XCTAssertEqual(copy.fileName, "Sunset (Copy 1).NEF")
        XCTAssertEqual(copy.rating, 4)
        let value7 = try await catalog.editStack(forImageID: archive.id)
        XCTAssertEqual(value7, Self.edit)
        XCTAssertEqual(library.fileURL(for: copy)?.lastPathComponent, "Sunset.NEF")

        // Reconcile again: the copy's sidecar still applies, unchanged.
        try await library.refresh()
        XCTAssertEqual(library.images.first { $0.id == archive.id }?.rating, 4)

        // The master's file gone: the copy goes with it.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Sunset.NEF"))
        try await library.refresh()
        XCTAssertNil(library.images.first { $0.id == archive.id })
        XCTAssertEqual(library.images.map(\.fileName), ["B.NEF"])
        let links = try await catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image_keywords WHERE image_id = ?", arguments: [archive.id])
        }
        XCTAssertEqual(links, 0)
    }

    func testCopiesFollowLatentsOwnMoveAndRename() async throws {
        let library = try await openLibrary()
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        let archive = try await catalog.createVirtualCopy(of: a.id!)
        try await catalog.setRating(2, forImageID: archive.id)
        try await library.refresh()

        try await library.fileOperations.rename(try XCTUnwrap(record(library, "A.NEF")), to: "Pier.NEF")
        XCTAssertEqual(library.images.first { $0.id == archive.id }?.fileName, "Pier (Copy 1).NEF")

        let sub = folder.appendingPathComponent("Picks", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try await catalog.setSubfolderMode(.included, forRelPath: "Picks")
        // Moving the copy moves its master's file, once.
        let copy = try XCTUnwrap(library.images.first { $0.id == archive.id })
        let master = try XCTUnwrap(record(library, "Pier.NEF"))
        let report = await library.fileOperations.transfer([master, copy], to: sub, mode: .move)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        let moved = try XCTUnwrap(library.images.first { $0.id == archive.id })
        XCTAssertEqual(moved.relPath, VirtualCopy.relPath(master: "Picks/Pier.NEF", key: archive.key))
        XCTAssertEqual(moved.rating, 2)
        XCTAssertTrue(exists(sub.appendingPathComponent("Pier.NEF")))
    }

    func testDuplicateMakesANumberedFileInItsOwnFolder() async throws {
        let library = try await openLibrary()
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        try await catalog.setRating(4, forImageID: a.id!)
        try await library.refresh()
        let report = await library.fileOperations.duplicate([try XCTUnwrap(record(library, "A.NEF"))])
        XCTAssertEqual(report.completed.first?.destination.lastPathComponent, "A 2.NEF", report.failureDescription)
        XCTAssertEqual(record(library, "A 2.NEF")?.rating, 4)
        XCTAssertEqual(library.undoManager?.undoActionName, "Duplicate “A.NEF”")
        library.undoManager?.undo()
        await library.waitForPendingWork()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(exists(folder.appendingPathComponent("A 2.NEF")))
    }

    // MARK: Persistence

    /// A copy and everything it holds come back after the catalog is closed
    /// and opened again, and after the database is lost and rebuilt from
    /// the sidecars.
    func testCopiesSurviveReopeningAndARebuiltDatabase() async throws {
        var library: Library? = try await openLibrary()
        var catalog = try XCTUnwrap(library?.catalog)
        let a = try XCTUnwrap(library.flatMap { record($0, "A.NEF") })
        let archive = try await catalog.createVirtualCopy(of: a.id!)
        try await catalog.setEditStack(Self.edit, forImageID: archive.id)
        try await catalog.setRating(4, forImageID: archive.id)
        try await catalog.setKeywords(["copy"], forImageID: archive.id)
        try await catalog.setHistory([(Self.edit, 7)], forImageID: archive.id)
        let saved = try await catalog.virtualCopyArchive(id: archive.id)
        library = nil

        library = try await openLibrary()
        catalog = try XCTUnwrap(library?.catalog)
        let value8 = try await catalog.virtualCopyArchive(id: archive.id)
        XCTAssertEqual(value8, saved)

        // Lose the database: the copy is read back from its sidecar.
        library = nil
        let container = folder.appendingPathComponent(Catalog.containerName)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("catalog.sqlite" + suffix))
        }
        library = try await openLibrary()
        catalog = try XCTUnwrap(library?.catalog)
        let copies = try XCTUnwrap(library?.images.filter(\.isVirtualCopy))
        XCTAssertEqual(copies.count, 1)
        let restored = try XCTUnwrap(copies.first)
        XCTAssertEqual(restored.fileName, "A (Copy 1).NEF")
        XCTAssertEqual(restored.rating, 4)
        XCTAssertEqual(VirtualCopy.parse(restored.relPath)?.key, archive.key)
        let value9 = try await catalog.editStack(forImageID: restored.id!)
        XCTAssertEqual(value9, Self.edit)
        let value10 = try await catalog.keywords(forImageID: restored.id!)
        XCTAssertEqual(value10, ["copy"])
        let value11 = try await catalog.history(forImageID: restored.id!).map(\.stackJSON)
        XCTAssertEqual(value11, [Self.edit])
        let master = try XCTUnwrap(library.flatMap { record($0, "A.NEF") })
        let value12 = try await catalog.masterID(ofImageID: restored.id!)
        XCTAssertEqual(value12, master.id)
    }

    // MARK: Undo

    func testCreateAndRemoveUndoAndRedo() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        let made = try await library.createVirtualCopies(of: [a])
        let id = try XCTUnwrap(made.first)
        XCTAssertEqual(manager.undoActionName, "Create Virtual Copy")
        // Edited after it was made (as in Develop, off the Library's undo).
        try await catalog.setEditStack(Self.edit, forImageID: id)
        try await catalog.setSnapshots([("Mine", Self.edit)], forImageID: id)

        manager.undo()
        await library.waitForPendingWork()
        XCTAssertNil(library.images.first { $0.id == id })
        XCTAssertEqual(library.images.filter(\.isVirtualCopy).count, 0)

        manager.redo()
        await library.waitForPendingWork()
        XCTAssertNotNil(library.images.first { $0.id == id }, "back under its own id")
        let value13 = try await catalog.editStack(forImageID: id)
        XCTAssertEqual(value13, Self.edit, "with what it had when undone")
        let value14 = try await catalog.snapshots(forImageID: id).map(\.name)
        XCTAssertEqual(value14, ["Mine"])

        // Remove, then undo the removal.
        let copy = try XCTUnwrap(library.images.first { $0.id == id })
        var closed: Set<Int64> = []
        library.willRemoveImages = { closed.formUnion($0) }
        try await library.removeVirtualCopies([copy, a])
        XCTAssertEqual(closed, [id])
        XCTAssertEqual(manager.undoActionName, "Remove Virtual Copy")
        XCTAssertNil(library.images.first { $0.id == id })
        XCTAssertNotNil(record(library, "A.NEF"), "a master is never removed")
        XCTAssertEqual(library.selectedImageID, a.id, "its master is selected")
        let sidecar = await catalog.sidecarURL(forRelPath: copy.relPath)
        XCTAssertFalse(exists(sidecar), "its sidecar goes, or reconcile would bring it back")
        try await library.refresh()
        XCTAssertNil(library.images.first { $0.id == id })

        manager.undo()
        await library.waitForPendingWork()
        XCTAssertNotNil(library.images.first { $0.id == id })
        let value15 = try await catalog.editStack(forImageID: id)
        XCTAssertEqual(value15, Self.edit)
        XCTAssertTrue(exists(sidecar))
    }

    func testSetCopyAsMasterSwapsAndUndoSwapsBack() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(record(library, "A.NEF"))
        try await catalog.setRating(1, forImageID: a.id!)
        try await catalog.setKeywords(["master"], forImageID: a.id!)
        let copyID = try await catalog.createVirtualCopy(of: a.id!).id
        try await catalog.setEditStack(Self.edit, forImageID: copyID)
        try await catalog.setRating(5, forImageID: copyID)
        try await catalog.setKeywords(["copy"], forImageID: copyID)
        try await library.refresh()

        var followed: Set<Int64> = []
        library.didRestoreImages = { ids, _ in followed.formUnion(ids) }
        try await library.setCopyAsMaster(try XCTUnwrap(library.images.first { $0.id == copyID }))
        XCTAssertEqual(followed, [a.id!, copyID], "an editor showing either catches up")
        XCTAssertEqual(record(library, "A.NEF")?.rating, 5)
        let value16 = try await catalog.editStack(forImageID: a.id!)
        XCTAssertEqual(value16, Self.edit)
        let value17 = try await catalog.keywords(forImageID: a.id!)
        XCTAssertEqual(value17, ["copy"])
        XCTAssertEqual(library.images.first { $0.id == copyID }?.rating, 1)
        let value18 = try await catalog.editStack(forImageID: copyID)
        XCTAssertNil(value18)
        let value19 = try XMPSidecar.read(from: await catalog.sidecarURL(forRelPath: "A.NEF")).rating
        XCTAssertEqual(value19, 5)

        manager.undo()
        await library.waitForPendingWork()
        XCTAssertEqual(record(library, "A.NEF")?.rating, 1)
        let value20 = try await catalog.editStack(forImageID: a.id!)
        XCTAssertNil(value20)
        let value21 = try await catalog.keywords(forImageID: copyID)
        XCTAssertEqual(value21, ["copy"])
    }
}
