import XCTest
import GRDB
@testable import Catalog

/// The latent:Merge block of Photo Merge results (docs/PhotoMerge.md §5).
///
/// Every sidecar write renders the whole file from the database, so a block
/// the database forgot would silently vanish on the next rating. Each test
/// here takes one way a sidecar is rewritten, moved or rebuilt and checks
/// the block is still there, byte for byte.
@MainActor
final class MergeRecipeTests: XCTestCase {
    nonisolated(unsafe) var base: URL!
    nonisolated(unsafe) var root: URL!

    /// A recipe in the shape of the shared contract. One source's name holds
    /// `]]>`, which a CDATA section can't hold as it is, so every path here
    /// also proves the sidecar's escaping survives it.
    let recipe = #"{"algorithmVersion":"1","baselineShift":7,"clipLevel":128,"kind":"hdr","lensApplied":false,"#
        + #""options":{"deghost":"low"},"reference":1,"sources":["#
        + #"{"captureTime":1757925600,"hash":"xxh64:0123456789abcdef","path":"DSC_0106.NEF"},"#
        + #"{"captureTime":1757925601,"hash":"xxh64:fedcba9876543210","path":"odd ]]> name.NEF"}],"version":1}"#

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("latent-merge-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Shoot", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Day 2"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: ReconcileTests.sampleNEF, toPath: root.appendingPathComponent("A.NEF").path)
        try fm.copyItem(atPath: FileTransferTests.otherNEF, toPath: root.appendingPathComponent("B.NEF").path)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private let fm = FileManager.default

    private func sidecar(_ relPath: String, in folder: URL? = nil) -> URL {
        (folder ?? root).appendingPathComponent("_latent/xmp/\(relPath).xmp")
    }

    /// The block exactly as `XMPSidecar` renders it.
    private var block: String { "<latent:Merge>" + XMPSidecar.cdata(recipe) + "</latent:Merge>" }

    /// The sidecar holds the block once, unchanged, and reads back as the recipe.
    private func assertBlock(_ url: URL, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: block).count, 2, "block missing or repeated: \(message)\n\(text)",
                       file: file, line: line)
        XCTAssertEqual(try XMPSidecar.read(from: url).mergeJSON, recipe, message, file: file, line: line)
    }

    private func row(_ catalog: Catalog, _ relPath: String) async throws -> ImageRecord {
        let record = try await catalog.image(forRelPath: relPath)
        return try XCTUnwrap(record, "no row for \(relPath)")
    }

    /// The catalog with "Day 2" included and A a merge result.
    private func mergedCatalog() async throws -> (Catalog, Int64) {
        let catalog = try Catalog.open(at: root)
        try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
        _ = try await catalog.reconcile()
        let id = try await row(catalog, "A.NEF").id!
        try await catalog.setMergeRecipe(recipe, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "written")
        return (catalog, id)
    }

    /// A later write gets a later modification time, so reconcile tells
    /// one sidecar from the next.
    private func tick() async throws { try await Task.sleep(for: .milliseconds(20)) }

    // MARK: - The catalog

    func testTheRecipeIsStoredOnTheRowAndCanBeRemoved() async throws {
        let (catalog, id) = try await mergedCatalog()
        let stored = try await catalog.mergeRecipe(forImageID: id)
        XCTAssertEqual(stored, recipe)
        let a = try await row(catalog, "A.NEF")
        XCTAssertEqual(a.mergeJSON, recipe)
        let b = try await row(catalog, "B.NEF")
        XCTAssertNil(b.mergeJSON, "other images aren't merges")

        try await catalog.setMergeRecipe("  ", forImageID: id)
        let cleared = try await catalog.mergeRecipe(forImageID: id)
        XCTAssertNil(cleared)
        XCTAssertFalse(try String(contentsOf: sidecar("A.NEF"), encoding: .utf8).contains("Merge"))
    }

    /// A catalog made before the column existed gains it empty, and its rows
    /// are otherwise untouched.
    func testMigrationAddsAnEmptyColumnToAnOlderCatalog() async throws {
        let container = root.appendingPathComponent("_latent", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            let queue = try DatabaseQueue(path: container.appendingPathComponent("catalog.sqlite").path)
            try Schema.migrator().migrate(queue, upTo: "v3_finder_tags")
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO images (rel_path, size, mtime, xxhash, rating) VALUES ('Old.NEF', 1, 1, x'00', 3)
                    """)
            }
        }
        let catalog = try Catalog.open(at: root)
        let old = try await row(catalog, "Old.NEF")
        XCTAssertEqual(old.rating, 3)
        XCTAssertNil(old.mergeJSON)
        try await catalog.setMergeRecipe(recipe, forImageID: old.id!)
        let stored = try await catalog.mergeRecipe(forImageID: old.id!)
        XCTAssertEqual(stored, recipe, "the column is there to write to")
    }

    /// Rating, flag, label, rotation and keywords each rewrite the sidecar.
    func testMetadataChangesKeepTheBlock() async throws {
        let (catalog, id) = try await mergedCatalog()
        try await catalog.setRating(4, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "rating")
        try await catalog.setFlag(.picked, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "flag")
        try await catalog.setLabel("Green", forImageID: id)
        try assertBlock(sidecar("A.NEF"), "label")
        try await catalog.setUserRotation(1, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "rotation")
        try await catalog.rotate(by: 1, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "rotate")
        try await catalog.setKeywords(["sea"], forImageID: id)
        try assertBlock(sidecar("A.NEF"), "keywords")
        _ = try await catalog.exchangeRating(2, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "exchanged rating")

        let fields = try XMPSidecar.read(from: sidecar("A.NEF"))
        XCTAssertEqual(fields.rating, 2)
        XCTAssertEqual(fields.keywords, ["sea"])
    }

    func testEditHistoryAndSnapshotSavesKeepTheBlock() async throws {
        let (catalog, id) = try await mergedCatalog()
        let stack = #"{"schema":1,"modules":{"exposure":{"ev":0.5}}}"#
        try await catalog.setEditStack(stack, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "edit")
        try await catalog.setSnapshots([("Bright", stack)], forImageID: id)
        try assertBlock(sidecar("A.NEF"), "snapshots")
        try await catalog.setHistory([(stack, 100)], forImageID: id)
        try assertBlock(sidecar("A.NEF"), "history")
        try await catalog.setStoredEdit(StoredEdit(json: stack, schemaVersion: 1, processVersion: "1.0"), forImageID: id)
        try assertBlock(sidecar("A.NEF"), "stored edit")
        try await catalog.setEditStack(nil, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "edit removed")
    }

    // MARK: - Reconcile

    /// Finder tags change the row only; the sidecar is not touched at all.
    func testAFinderTagChangeLeavesTheSidecarAlone() async throws {
        let (catalog, id) = try await mergedCatalog()
        let before = try Data(contentsOf: sidecar("A.NEF"))
        try FinderTagTests.setFinderTags(["Red\n6"], on: root.appendingPathComponent("A.NEF"))
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.tagsChanged, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar("A.NEF")), before)
        let tagged = try await row(catalog, "A.NEF")
        XCTAssertEqual(tagged.mergeJSON, recipe)
        try await catalog.setRating(1, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "written after the tag change")
    }

    /// A sidecar changed outside Latent is read back onto the row, recipe
    /// and all, and a sidecar that has gone takes the recipe with it: the
    /// sidecar is the truth (DESIGN.md §5.3).
    func testASidecarChangedOrRemovedOutsideLatentIsTheTruth() async throws {
        let (catalog, id) = try await mergedCatalog()
        var fields = try XMPSidecar.read(from: sidecar("A.NEF"))
        fields.rating = 2
        try await tick()
        try XMPSidecar.write(fields, to: sidecar("A.NEF"))
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 1)
        let reread = try await row(catalog, "A.NEF")
        XCTAssertEqual(reread.rating, 2)
        XCTAssertEqual(reread.mergeJSON, recipe)
        try await catalog.setFlag(.rejected, forImageID: id)
        try assertBlock(sidecar("A.NEF"), "written after the outside change")

        // Changed outside to hold no recipe: the image is no longer a merge.
        fields.mergeJSON = ""
        try await tick()
        try XMPSidecar.write(fields, to: sidecar("A.NEF"))
        report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 1)
        var cleared = try await catalog.mergeRecipe(forImageID: id)
        XCTAssertNil(cleared)

        try await catalog.setMergeRecipe(recipe, forImageID: id)
        try fm.removeItem(at: sidecar("A.NEF"))
        _ = try await catalog.reconcile()
        cleared = try await catalog.mergeRecipe(forImageID: id)
        XCTAssertNil(cleared, "no sidecar, no recipe")
    }

    /// A file renamed in Finder: reconcile finds it by hash and moves the
    /// sidecar as it is. Then its content changes: the row keeps the recipe.
    func testRenamedAndModifiedOutsideLatentKeepTheBlock() async throws {
        let (catalog, _) = try await mergedCatalog()
        let before = try Data(contentsOf: sidecar("A.NEF"))
        try fm.moveItem(at: root.appendingPathComponent("A.NEF"), to: root.appendingPathComponent("C.NEF"))
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar("C.NEF")), before)
        let renamed = try await row(catalog, "C.NEF")
        XCTAssertEqual(renamed.mergeJSON, recipe)

        try await tick()
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("C.NEF"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        report = try await catalog.reconcile()
        XCTAssertEqual(report.modified, 1, "\(report)")
        let modified = try await row(catalog, "C.NEF")
        XCTAssertEqual(modified.mergeJSON, recipe)
        try await catalog.setRating(5, forImageID: modified.id!)
        try assertBlock(sidecar("C.NEF"), "written after the content changed")
    }

    /// Delete the database: the recipe comes back from the sidecar, and the
    /// next write from the rebuilt row still carries it.
    func testRebuildingTheDatabaseFromSidecarsKeepsTheRecipe() async throws {
        var (catalog, _) = try await mergedCatalog()
        let db = await catalog.containerPath.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog.open(at: base)   // release the old queue
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: db.path + suffix))
        }
        catalog = try Catalog.open(at: root)
        try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 1)
        let rebuilt = try await row(catalog, "A.NEF")
        XCTAssertEqual(rebuilt.mergeJSON, recipe)
        try await catalog.setKeywords(["rebuilt"], forImageID: rebuilt.id!)
        try assertBlock(sidecar("A.NEF"), "written from the rebuilt row")
    }

    // MARK: - Moves, copies and renames

    private func run(_ name: String, to folder: URL, as newName: String? = nil, _ mode: TransferMode,
                     _ catalog: Catalog, file: StaticString = #filePath, line: UInt = #line) async -> CompletedTransfer? {
        let request = TransferRequest(source: root.appendingPathComponent(name), folder: folder, name: newName)
        let report = await ImageTransfer.run([request], mode: mode, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription, file: file, line: line)
        return report.completed.first
    }

    /// Within the open catalog: a rename (the sidecar written from the row
    /// for its preserved name), a move into a subfolder (the sidecar renamed)
    /// and a copy (a new row copied from the old, its sidecar written).
    func testRenameMoveAndCopyWithinTheCatalogCarryTheBlock() async throws {
        let (catalog, _) = try await mergedCatalog()

        _ = await run("A.NEF", to: root, as: "Hero.NEF", .move, catalog)
        try assertBlock(sidecar("Hero.NEF"), "renamed")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("Hero.NEF")).preservedFileName, "A.NEF")
        let renamed = try await row(catalog, "Hero.NEF")
        XCTAssertEqual(renamed.mergeJSON, recipe)

        let day2 = root.appendingPathComponent("Day 2")
        _ = await run("Hero.NEF", to: day2, .move, catalog)
        try assertBlock(sidecar("Day 2/Hero.NEF"), "moved into a subfolder")

        let copy = await run("Day 2/Hero.NEF", to: day2, .copy, catalog)
        XCTAssertEqual(copy?.destination.lastPathComponent, "Hero 2.NEF")
        try assertBlock(sidecar("Day 2/Hero 2.NEF"), "copied")
        let copied = try await row(catalog, "Day 2/Hero 2.NEF")
        XCTAssertEqual(copied.mergeJSON, recipe)
        let reconcile = try await catalog.reconcile()
        XCTAssertEqual(reconcile.sidecarsRead + reconcile.added + reconcile.removed, 0, "\(reconcile)")
    }

    /// Into another catalog the sidecar is written from the row, and that
    /// catalog's reconcile puts the recipe on its own new row.
    func testMoveAndCopyIntoAnotherCatalogCarryTheBlock() async throws {
        let (catalog, _) = try await mergedCatalog()
        let archive = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        _ = try await Catalog.open(at: archive).reconcile()

        _ = await run("A.NEF", to: archive, .copy, catalog)
        try assertBlock(sidecar("A.NEF", in: archive), "copied to another catalog")
        _ = await run("A.NEF", to: archive, .move, catalog)
        try assertBlock(sidecar("A 2.NEF", in: archive), "moved to another catalog")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("A 2.NEF", in: archive)).preservedFileName, "A.NEF")

        let other = try Catalog.open(at: archive)
        _ = try await other.reconcile()
        let first = try await row(other, "A.NEF")
        let second = try await row(other, "A 2.NEF")
        XCTAssertEqual(first.mergeJSON, recipe)
        XCTAssertEqual(second.mergeJSON, recipe)
    }

    /// A sidecar changed outside Latent travels as the file it is, and gets
    /// its preserved name by being read and written back: that rewrite must
    /// keep the block too, within the catalog and into another.
    func testASidecarCarriedAsItIsKeepsTheBlockThroughItsNameRewrite() async throws {
        let (catalog, _) = try await mergedCatalog()
        var fields = try XMPSidecar.read(from: sidecar("A.NEF"))
        fields.rating = 3
        try await tick()
        try XMPSidecar.write(fields, to: sidecar("A.NEF"))

        let archive = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try fm.copyItem(at: root.appendingPathComponent("B.NEF"), to: archive.appendingPathComponent("A.NEF"))
        let copy = await run("A.NEF", to: archive, .copy, catalog)
        XCTAssertEqual(copy?.destination.lastPathComponent, "A 2.NEF")
        try assertBlock(sidecar("A 2.NEF", in: archive), "copied as it is, then renamed inside")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("A 2.NEF", in: archive)).preservedFileName, "A.NEF")

        _ = await run("A.NEF", to: root, as: "Renamed.NEF", .move, catalog)
        try assertBlock(sidecar("Renamed.NEF"), "renamed with a sidecar changed outside")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("Renamed.NEF")).rating, 3)
        _ = try await catalog.reconcile()
        let renamed = try await row(catalog, "Renamed.NEF")
        XCTAssertEqual(renamed.mergeJSON, recipe)
    }

    // MARK: - Through the Library

    private func openLibrary() async throws -> (Library, UndoManager) {
        _ = try await mergedCatalog()
        let library = Library()
        let undo = UndoManager()
        library.undoManager = undo
        try await library.open(folder: root)
        return (library, undo)
    }

    private func record(_ library: Library, _ relPath: String) -> ImageRecord? {
        library.images.first { $0.relPath == relPath }
    }

    private func settle(_ library: Library) async {
        await library.waitForPendingWork()
        // A file operation's revert starts its work a turn later.
        while library.fileOperations.isBusy || library.hasPendingWork {
            await library.waitForPendingWork()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Undo and redo of ratings, rotation, pasted settings and a move all
    /// rewrite the sidecar from the row.
    func testLibraryUndoAndRedoKeepTheBlock() async throws {
        let (library, undo) = try await openLibrary()
        let a = try XCTUnwrap(record(library, "A.NEF"))
        XCTAssertEqual(a.mergeJSON, recipe, "the grid's row carries it")
        library.setSelection([a.id!], primary: a.id!)

        try await library.setRating(3)
        try await library.rotateSelected(by: 1)
        try await library.transformSelectedEdits(schemaVersion: 1, processVersion: "1.0") { _ in #"{"schema":1}"# }
        for step in 1...3 {
            undo.undo()
            await settle(library)
            try assertBlock(sidecar("A.NEF"), "undo \(step)")
        }
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("A.NEF")).rating, 0)
        undo.redo()
        await settle(library)
        try assertBlock(sidecar("A.NEF"), "redo")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("A.NEF")).rating, 3)

        let archive = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let current = try XCTUnwrap(record(library, "A.NEF"))
        let report = await library.fileOperations.transfer([current], to: archive, mode: .move)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        try assertBlock(sidecar("A.NEF", in: archive), "moved out")
        undo.undo()
        await settle(library)
        try assertBlock(sidecar("A.NEF"), "move undone")
        XCTAssertEqual(record(library, "A.NEF")?.mergeJSON, recipe)
    }

    /// The merge job's commit: recipe sidecar, then the file, then refresh.
    func testCreatingAMergeResultThroughTheLibrary() async throws {
        let library = Library()
        try await library.open(folder: root)

        try await library.writeMergeRecipe(recipe, forNewImageAt: "A-HDR.NEF")
        try assertBlock(sidecar("A-HDR.NEF"), "written before the file")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("A-HDR.NEF")).sourceHash, "", "the file isn't written yet")

        // The name is now taken, by the sidecar as much as by a file or row.
        for taken in ["A-HDR.NEF", "A.NEF"] {
            do {
                try await library.writeMergeRecipe(recipe, forNewImageAt: taken)
                XCTFail("\(taken) is taken")
            } catch let problem as FileOperations.NameProblem {
                XCTAssertEqual(problem, .taken((taken as NSString).lastPathComponent))
            }
        }
        try assertBlock(sidecar("A-HDR.NEF"), "a refused write overwrites nothing")

        try fm.copyItem(at: root.appendingPathComponent("A.NEF"), to: root.appendingPathComponent("A-HDR.NEF"))
        try await library.refresh()
        let merged = try XCTUnwrap(record(library, "A-HDR.NEF"))
        XCTAssertEqual(merged.mergeJSON, recipe)
        let read = try await library.mergeRecipe(for: merged)
        XCTAssertEqual(read, recipe)
        XCTAssertNil(record(library, "A.NEF")?.mergeJSON)

        library.setSelection([merged.id!], primary: merged.id!)
        try await library.setRating(2)
        try assertBlock(sidecar("A-HDR.NEF"), "first write from the row")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("A-HDR.NEF")).sourceHash, merged.hashString)
    }

    /// A DNG that never arrived gives its name back; a file that did keeps
    /// its sidecar.
    func testDiscardingARecipeWhoseFileNeverArrived() async throws {
        let library = Library()
        try await library.open(folder: root)

        try await library.writeMergeRecipe(recipe, forNewImageAt: "Day 2/Pano.NEF")
        XCTAssertTrue(fm.fileExists(atPath: sidecar("Day 2/Pano.NEF").path))
        try await library.discardMergeRecipe(forNewImageAt: "Day 2/Pano.NEF")
        XCTAssertFalse(fm.fileExists(atPath: sidecar("Day 2/Pano.NEF").path))
        try await library.writeMergeRecipe(recipe, forNewImageAt: "Day 2/Pano.NEF")

        try fm.copyItem(at: root.appendingPathComponent("B.NEF"), to: root.appendingPathComponent("Day 2/Pano.NEF"))
        try await library.discardMergeRecipe(forNewImageAt: "Day 2/Pano.NEF")
        try assertBlock(sidecar("Day 2/Pano.NEF"), "kept once the file is there")
    }

    func testSettingARecipeOnACataloguedImageUpdatesTheGrid() async throws {
        let library = Library()
        try await library.open(folder: root)
        let b = try XCTUnwrap(record(library, "B.NEF"))

        try await library.setMergeRecipe(recipe, forImageID: b.id!)
        XCTAssertEqual(record(library, "B.NEF")?.mergeJSON, recipe)
        try assertBlock(sidecar("B.NEF"), "set on a catalogued image")

        try await library.setMergeRecipe(nil, forImageID: b.id!)
        XCTAssertNil(record(library, "B.NEF")?.mergeJSON)
        XCTAssertFalse(try String(contentsOf: sidecar("B.NEF"), encoding: .utf8).contains("Merge"))
    }

    /// Quitting waits for pending work; a recipe on its way to disk is some.
    func testQuittingWaitsForARecipeWrite() async throws {
        let library = Library()
        try await library.open(folder: root)

        let writing = Task { @MainActor in try await library.writeMergeRecipe(recipe, forNewImageAt: "Q.NEF") }
        // Let the write start: from then on it counts until it is on disk.
        while !library.hasPendingWork, !fm.fileExists(atPath: sidecar("Q.NEF").path) { await Task.yield() }
        await library.waitForPendingWork()
        try assertBlock(sidecar("Q.NEF"), "on disk once pending work is done")
        XCTAssertFalse(library.hasPendingWork)
        try await writing.value
    }

    func testWritingARecipeWithNoFolderOpenFails() async throws {
        do {
            try await Library().writeMergeRecipe(recipe, forNewImageAt: "X.NEF")
            XCTFail("nowhere to write it")
        } catch MergeRecipeError.noOpenCatalog {
        }
    }
}
