import XCTest
@testable import Catalog

/// Undo and redo of Library actions on the Library's undo manager: every
/// image goes back to its own previous value, in the row and the sidecar,
/// and nothing is ever undone in a catalog other than the one it was done in.
@MainActor
final class LibraryUndoTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!
    nonisolated(unsafe) var other: URL!

    override func setUpWithError() throws {
        let sample = try TestAssets.d750Path()
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-undo-\(UUID().uuidString)", isDirectory: true)
        other = fm.temporaryDirectory.appendingPathComponent("latent-undo-other-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        for name in ["A.NEF", "B.NEF"] {
            try fm.copyItem(atPath: sample, toPath: folder.appendingPathComponent(name).path)
        }
        try fm.copyItem(atPath: sample, toPath: other.appendingPathComponent("Z.NEF").path)
    }

    override func tearDownWithError() throws {
        for url in [folder, other].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }

    /// A library on a real (event-grouping) undo manager, with A and B listed.
    private func openLibrary(_ manager: UndoManager) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 2)
        return library
    }

    private func id(_ library: Library, _ name: String) -> Int64 {
        library.images.first { $0.fileName == name }!.id!
    }

    private func record(_ library: Library, _ name: String) -> ImageRecord {
        library.images.first { $0.fileName == name }!
    }

    private func sidecar(_ library: Library, _ name: String) async throws -> XMPSidecar.Fields {
        try XMPSidecar.read(from: await library.catalog!.sidecarURL(forRelPath: name))
    }

    /// Undo or redo, then wait for the catalog writes it started.
    private func undo(_ manager: UndoManager, _ library: Library) async {
        manager.undo()
        await library.waitForPendingWork()
    }

    private func redo(_ manager: UndoManager, _ library: Library) async {
        manager.redo()
        await library.waitForPendingWork()
    }

    /// Each action is its own undo step as soon as it has been filed. It
    /// finishes outside any event, so nothing would close a group left
    /// open, and the next action would join it (seen in the app, where no
    /// event came between two actions).
    private func endEvent(_ manager: UndoManager, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(manager.groupingLevel, 0, "no group left open", file: file, line: line)
    }

    func testRatingUndoRestoresEachImagesOwnValue() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))

        library.setSelection([b], primary: b)
        try await library.setRating(2)
        endEvent(manager)
        XCTAssertEqual(manager.undoActionName, "Rating")

        library.setSelection([a, b], primary: a)
        try await library.setRating(4)
        endEvent(manager)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Rating (2 Images)")
        XCTAssertEqual(record(library, "A.NEF").rating, 4)

        await undo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").rating, 0)
        XCTAssertEqual(record(library, "B.NEF").rating, 2, "its own previous value, not A's")
        let rowA = try await library.catalog!.image(forRelPath: "A.NEF")
        XCTAssertEqual(rowA?.rating, 0)
        let sidecarB = try await sidecar(library, "B.NEF")
        XCTAssertEqual(sidecarB.rating, 2, "the sidecar follows")
        XCTAssertEqual(manager.redoMenuItemTitle, "Redo Rating (2 Images)")
        XCTAssertEqual(manager.undoActionName, "Rating", "B's own rating is next")

        await redo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").rating, 4)
        XCTAssertEqual(record(library, "B.NEF").rating, 4)
        let sidecarA = try await sidecar(library, "A.NEF")
        XCTAssertEqual(sidecarA.rating, 4)

        await undo(manager, library)
        await undo(manager, library)
        XCTAssertEqual(record(library, "B.NEF").rating, 0)
        XCTAssertFalse(manager.canUndo)
        XCTAssertTrue(manager.canRedo)
    }

    /// A key that changes nothing (0 stars on unrated images) leaves
    /// nothing to undo.
    func testNoChangeRegistersNothing() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        library.selectAllVisible()
        try await library.setRating(0)
        try await library.setFlag(.none)
        try await library.rotateSelected(by: 4)
        try await library.setKeywords([])
        _ = try await library.transformSelectedEdits(schemaVersion: 1, processVersion: "1.0") { $0 }
        XCTAssertFalse(manager.canUndo)
    }

    func testFlagRotationAndKeywordsUndo() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))

        // A turned once on its own first, so the batch turn starts from different angles.
        library.setSelection([a], primary: a)
        try await library.rotateSelected(by: 1)
        endEvent(manager)
        library.setSelection([a, b], primary: a)
        try await library.setFlag(.picked)
        endEvent(manager)
        try await library.rotateSelected(by: -1)
        endEvent(manager)
        try await library.setKeywords(["tree", " sky "])
        endEvent(manager)
        XCTAssertEqual(manager.undoActionName, "Keywords")
        XCTAssertEqual(library.selectedKeywords, ["sky", "tree"])

        library.filter.keyword = "tree"
        await undo(manager, library)
        XCTAssertEqual(library.selectedKeywords, [])
        XCTAssertEqual(library.visibleImages.count, 0, "the keyword filter follows")
        let keywordsSidecar = try await sidecar(library, "A.NEF")
        XCTAssertEqual(keywordsSidecar.keywords, [])
        library.filter = LibraryFilter()

        var restored: [(Set<Int64>, Library.RestoredAspect)] = []
        library.didRestoreImages = { restored.append(($0, $1)) }
        XCTAssertEqual(manager.undoActionName, "Rotation (2 Images)")
        await undo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").userRotation, 1)
        XCTAssertEqual(record(library, "B.NEF").userRotation, 0)
        XCTAssertEqual(restored.first?.0, [a, b])
        XCTAssertEqual(restored.first?.1, .rotation)

        XCTAssertEqual(manager.undoActionName, "Flag (2 Images)")
        await undo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").flag, ImageFlag.none.rawValue)
        XCTAssertEqual(record(library, "B.NEF").flag, ImageFlag.none.rawValue)

        await redo(manager, library)
        await redo(manager, library)
        await redo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").flag, ImageFlag.picked.rawValue)
        XCTAssertEqual(record(library, "A.NEF").userRotation, 0)
        XCTAssertEqual(record(library, "B.NEF").userRotation, 3)
        XCTAssertEqual(library.selectedKeywords, ["sky", "tree"])
        XCTAssertEqual(library.availableKeywords, ["sky", "tree"], "the filter's index, trimmed as the field's save is")
        let sidecarB = try await sidecar(library, "B.NEF")
        XCTAssertEqual(sidecarB.rotation, 3)
    }

    /// Pasting onto a selection rewrites each image's stack; undo puts back
    /// each one's own, with the versions it was stored under, and the edit
    /// badges and the editor hook follow.
    func testPasteSettingsUndoRestoresEachStack() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        let original = "{\"schema\":1,\"exposure\":0.5}"
        try await library.saveEditStack(original, schemaVersion: 1, processVersion: "0.9", forImageID: a)
        XCTAssertFalse(manager.canUndo, "the editor's saves are Develop's history, not the Library's")

        library.setSelection([a, b], primary: a)
        let pasted = "{\"schema\":1,\"pasted\":true}"
        let outcome = try await library.transformSelectedEdits(schemaVersion: 2, processVersion: "1.0",
                                                               undoName: "Paste Settings") { _ in pasted }
        endEvent(manager)
        XCTAssertEqual(outcome.changed, 2)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Paste Settings (2 Images)")
        XCTAssertEqual(library.editedImageIDs, [a, b])

        var restored: [(Set<Int64>, Library.RestoredAspect)] = []
        library.didRestoreImages = { restored.append(($0, $1)) }
        await undo(manager, library)
        let editA = try await library.catalog!.storedEdit(forImageID: a)
        let editB = try await library.catalog!.storedEdit(forImageID: b)
        XCTAssertEqual(editA, StoredEdit(json: original, schemaVersion: 1, processVersion: "0.9"))
        XCTAssertNil(editB)
        XCTAssertEqual(library.editedImageIDs, [a])
        XCTAssertEqual(restored.map(\.0), [[a, b]])
        XCTAssertEqual(restored.map(\.1), [.edits])
        let sidecarA = try await sidecar(library, "A.NEF")
        XCTAssertEqual(sidecarA.processVersion, "0.9")
        let sidecarB = try await sidecar(library, "B.NEF")
        XCTAssertEqual(sidecarB.editStackJSON, "")

        await redo(manager, library)
        let redoneB = try await library.catalog!.storedEdit(forImageID: b)
        XCTAssertEqual(redoneB, StoredEdit(json: pasted, schemaVersion: 2, processVersion: "1.0"))
        XCTAssertEqual(library.editedImageIDs, [a, b])
    }

    /// A batch job's commit (`setEdits`): the images it names are written
    /// in one undo group, and undo puts back each one's own stored edit.
    func testSetEditsFilesOneGroupForTheImagesWritten() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        let original = "{\"schema\":1,\"exposure\":0.5}"
        try await library.saveEditStack(original, schemaVersion: 1, processVersion: "0.9", forImageID: a)

        let newA = "{\"schema\":1,\"dust\":true}", newB = "{\"schema\":1,\"dust\":2}"
        let expected: [Int64: String?] = [a: original, b: nil]
        let outcome = try await library.setEdits([a: newA, b: newB], expecting: expected,
                                                 schemaVersion: 1, processVersion: "1.0", undoName: "Remove Dust")
        endEvent(manager)
        XCTAssertEqual(outcome.changed, 2)
        XCTAssertEqual(outcome.skipped, [])
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust (2 Images)")
        XCTAssertEqual(library.editedImageIDs, [a, b])
        let writtenA = try await library.catalog!.storedEdit(forImageID: a)
        XCTAssertEqual(writtenA, StoredEdit(json: newA, schemaVersion: 1, processVersion: "1.0"))

        var restored: [(Set<Int64>, Library.RestoredAspect)] = []
        library.didRestoreImages = { restored.append(($0, $1)) }
        await undo(manager, library)
        let editA = try await library.catalog!.storedEdit(forImageID: a)
        let editB = try await library.catalog!.storedEdit(forImageID: b)
        XCTAssertEqual(editA, StoredEdit(json: original, schemaVersion: 1, processVersion: "0.9"))
        XCTAssertNil(editB)
        XCTAssertEqual(library.editedImageIDs, [a])
        XCTAssertEqual(restored.map(\.0), [[a, b]])
        XCTAssertEqual(restored.map(\.1), [.edits])
        XCTAssertFalse(manager.canUndo, "one group, not one per image")

        await redo(manager, library)
        let redoneB = try await library.catalog!.storedEdit(forImageID: b)
        XCTAssertEqual(redoneB, StoredEdit(json: newB, schemaVersion: 1, processVersion: "1.0"))
        XCTAssertEqual(library.editedImageIDs, [a, b])

        // Writing what is already there changes nothing and files nothing.
        let same = try await library.setEdits([a: newA], expecting: [a: newA],
                                              schemaVersion: 1, processVersion: "1.0", undoName: "Remove Dust")
        XCTAssertEqual(same.changed, 0)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust (2 Images)")
        // Clearing an edit is a write too.
        let clearB: [Int64: String?] = [b: nil]
        let cleared = try await library.setEdits(clearB, expecting: [b: newB],
                                                 schemaVersion: 1, processVersion: "1.0", undoName: "Remove Dust")
        endEvent(manager)
        XCTAssertEqual(cleared.changed, 1)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust")
        XCTAssertEqual(library.editedImageIDs, [a])
    }

    /// An image whose stored edit changed while the job ran is skipped and
    /// named, never overwritten; the others are still written.
    func testSetEditsSkipsAnImageWhoseEditChangedMeanwhile() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        let readByJob = "{\"schema\":1,\"exposure\":0.5}"
        try await library.saveEditStack(readByJob, schemaVersion: 1, processVersion: "1.0", forImageID: a)
        // The user edits A while the job runs.
        let meanwhile = "{\"schema\":1,\"exposure\":1}"
        try await library.saveEditStack(meanwhile, schemaVersion: 1, processVersion: "1.0", forImageID: a)

        let expected: [Int64: String?] = [a: readByJob, b: nil]
        let outcome = try await library.setEdits([a: "{\"a\":1}", b: "{\"b\":1}"], expecting: expected,
                                                 schemaVersion: 1, processVersion: "1.0", undoName: "Find Faces")
        endEvent(manager)
        XCTAssertEqual(outcome.changed, 1)
        XCTAssertEqual(outcome.skipped, ["A.NEF"])
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Find Faces")
        let editA = try await library.catalog!.storedEdit(forImageID: a)
        XCTAssertEqual(editA?.json, meanwhile, "the user's edit stands")
        let editB = try await library.catalog!.storedEdit(forImageID: b)
        XCTAssertEqual(editB?.json, "{\"b\":1}")

        // Expecting no edit where one now exists is a mismatch too.
        let expectNone: [Int64: String?] = [b: nil]
        let second = try await library.setEdits([b: "{\"b\":2}"], expecting: expectNone,
                                                schemaVersion: 1, processVersion: "1.0", undoName: "Find Faces")
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(second.skipped, ["B.NEF"])
        await undo(manager, library)
        let undoneB = try await library.catalog!.storedEdit(forImageID: b)
        XCTAssertNil(undoneB)
        XCTAssertEqual(editA?.json, meanwhile)
    }

    /// An image no longer in the library (removed while the job ran) is
    /// skipped and named by its id, and nothing is filed for it.
    func testSetEditsSkipsAnImageNoLongerListed() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let a = id(library, "A.NEF")
        let gone: Int64 = 424_242
        XCTAssertFalse(library.images.contains { $0.id == gone })
        let expected: [Int64: String?] = [gone: nil, a: nil]
        let outcome = try await library.setEdits([gone: "{\"x\":1}", a: "{\"a\":1}"], expecting: expected,
                                                 schemaVersion: 1, processVersion: "1.0", undoName: "Remove Dust")
        endEvent(manager)
        XCTAssertEqual(outcome.changed, 1)
        XCTAssertEqual(outcome.skipped, ["image 424242"])
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust")
        let stored = try await library.catalog!.storedEdit(forImageID: gone)
        XCTAssertNil(stored)
        // Nothing at all to write files nothing.
        let none = try await library.setEdits([gone: "{\"x\":1}"], expecting: [:],
                                              schemaVersion: 1, processVersion: "1.0", undoName: "Remove Dust")
        XCTAssertEqual(none.changed, 0)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Dust")
        XCTAssertEqual(library.batchTargets(onlyPrimary: false).count, 0, "nothing selected")
        library.selectAllVisible()
        XCTAssertEqual(library.batchTargets(onlyPrimary: false).count, 2)
        XCTAssertEqual(library.batchTargets(onlyPrimary: true).count, 1)
    }

    /// Two undos in quick succession, the second asked for before the
    /// first has written, still end at the oldest value on every image,
    /// whatever order the images were changed in.
    func testQuickUndosApplyInOrder() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))

        // B alone first, then both: undoing both writes A then B for the
        // newer, and B for the older, which must come last.
        library.setSelection([b], primary: b)
        try await library.setRating(5)
        endEvent(manager)
        library.setSelection([a, b], primary: a)
        try await library.setRating(3)
        endEvent(manager)

        manager.undo()
        manager.undo()
        await library.waitForPendingWork()
        XCTAssertEqual(record(library, "A.NEF").rating, 0)
        XCTAssertEqual(record(library, "B.NEF").rating, 0)
        let rowB = try await library.catalog!.image(forRelPath: "B.NEF")
        XCTAssertEqual(rowB?.rating, 0)
    }

    /// Opening another folder drops the undo of the one left, since its ids
    /// are other photos in the next; an undo already asked for but not yet
    /// started is dropped too, rather than written onto the new catalog.
    func testSwitchingFolderDropsItsUndo() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let oldCatalog = try XCTUnwrap(library.catalog)
        let a = id(library, "A.NEF")
        library.setSelection([a], primary: a)
        try await library.setRating(3)
        endEvent(manager)
        try await library.setRating(4)
        endEvent(manager)

        // Hold the restore queue so the undo is waiting when the switch lands.
        let gate = Gate()
        library.undoRestores = Task { await gate.wait() }
        manager.undo()
        XCTAssertTrue(manager.canRedo)
        try await library.open(folder: other)
        XCTAssertFalse(manager.canUndo, "the old catalog's actions are gone")
        XCTAssertFalse(manager.canRedo)
        await gate.open()
        await library.waitForPendingWork()

        let z = try XCTUnwrap(library.images.first)
        XCTAssertEqual(z.id, a, "the hazard: the same id in both catalogs")
        let zRow = try await library.catalog!.image(forRelPath: "Z.NEF")
        XCTAssertEqual(zRow?.rating, 0, "never undone onto the other catalog's photo")
        let oldRow = try await oldCatalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(oldRow?.rating, 4, "dropped, not applied later")
    }

    /// A Custom order rearrangement goes with its catalog too, rather than
    /// leaving an Undo Rearrange in the next folder that does nothing.
    func testSwitchingFolderDropsARearrangement() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let library = try await openLibrary(manager)
        library.chooseSortKey(.custom)
        manager.beginUndoGrouping()
        library.moveInCustomOrder(["B.NEF"], before: "A.NEF")
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "Rearrange")
        await library.waitForPendingWork()

        try await library.open(folder: other)
        XCTAssertFalse(manager.canUndo, "the rearrangement went with its catalog")
    }

    /// The Library files on an undo manager of its own, not the window's,
    /// where text fields file their typing.
    func testTheLibraryHasItsOwnUndoManager() async throws {
        let library = Library()
        let manager = try XCTUnwrap(library.undoManager)
        try await library.open(folder: folder)
        library.selectAllVisible()
        try await library.setRating(5)
        XCTAssertEqual(manager.undoActionName, "Rating (2 Images)")
    }

    /// Without an undo manager the actions still work and nothing is filed.
    func testWorksWithoutAnUndoManager() async throws {
        let library = Library()
        library.undoManager = nil
        try await library.open(folder: folder)
        library.selectAllVisible()
        try await library.setRating(5)
        XCTAssertTrue(library.images.allSatisfy { $0.rating == 5 })
    }
}
