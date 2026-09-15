import XCTest
@testable import Catalog

/// Move to Folder, Copy to Folder and Rename against real raw files: the
/// file, its sidecar, thumbnail and row go together, names never overwrite,
/// other catalogs pick images up from their sidecars, undo puts things back
/// and an interrupted image is left where it was.
@MainActor
final class FileTransferTests: XCTestCase {
    nonisolated(unsafe) var base: URL!
    nonisolated(unsafe) var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("latent-transfer-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Shoot", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Day 2"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: ReconcileTests.sampleNEF, toPath: root.appendingPathComponent("A.NEF").path)
        try fm.copyItem(atPath: Self.otherNEF, toPath: root.appendingPathComponent("B.NEF").path)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    /// A second, different raw file, so two images never share a hash.
    static var otherNEF: String {
        let golden = URL(fileURLWithPath: ReconcileTests.sampleNEF).deletingLastPathComponent()
            .appendingPathComponent("golden_nikon_d750_cc0.nef").path
        return FileManager.default.fileExists(atPath: golden) ? golden : ReconcileTests.sampleNEF
    }

    private let fm = FileManager.default

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    private func sidecar(_ relPath: String) -> URL { root.appendingPathComponent("_latent/xmp/\(relPath).xmp") }
    private func thumbnail(_ relPath: String) -> URL { root.appendingPathComponent("_latent/thumbnails/\(relPath).heic") }

    /// The catalog with "Day 2" included, A rated, keyworded and edited, and
    /// thumbnails made.
    private func preparedCatalog() async throws -> Catalog {
        let catalog = try Catalog.open(at: root)
        try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
        _ = try await catalog.reconcile()
        // Before the edit: without a renderer, edited images get none.
        _ = try await catalog.generateMissingThumbnails()
        let a = try await XCTUnwrapAsync(await catalog.image(forRelPath: "A.NEF"))
        try await catalog.setRating(4, forImageID: a.id!)
        try await catalog.setKeywords(["sea", "dusk"], forImageID: a.id!)
        try await catalog.setEditStack(#"{"exposure":1}"#, forImageID: a.id!)
        return catalog
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func request(_ name: String, to folder: URL, as newName: String? = nil) -> TransferRequest {
        TransferRequest(source: root.appendingPathComponent(name), folder: folder, name: newName)
    }

    // MARK: - Within one catalog

    func testMoveIntoAnIncludedSubfolderCarriesSidecarThumbnailAndRow() async throws {
        let catalog = try await preparedCatalog()
        let before = try await XCTUnwrapAsync(await catalog.image(forRelPath: "A.NEF"))
        let day2 = root.appendingPathComponent("Day 2")

        let report = await ImageTransfer.run([request("A.NEF", to: day2)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)

        XCTAssertFalse(exists(root.appendingPathComponent("A.NEF")))
        XCTAssertTrue(exists(day2.appendingPathComponent("A.NEF")))
        XCTAssertTrue(exists(sidecar("Day 2/A.NEF")))
        XCTAssertFalse(exists(sidecar("A.NEF")))
        XCTAssertTrue(exists(thumbnail("Day 2/A.NEF")))
        XCTAssertFalse(exists(thumbnail("A.NEF")))

        let after = try await XCTUnwrapAsync(await catalog.image(forRelPath: "Day 2/A.NEF"))
        XCTAssertEqual(after.id, before.id, "the same row, only its path changed")
        XCTAssertEqual(after.rating, 4)
        XCTAssertEqual(after.thumbKey, before.thumbKey)
        XCTAssertNil(after.preservedName, "the name didn't change")

        // Nothing for reconcile to hash or mend.
        let reconcile = try await catalog.reconcile()
        XCTAssertEqual(reconcile.renamed + reconcile.added + reconcile.removed + reconcile.sidecarsRead, 0, "\(reconcile)")
    }

    func testMovingIntoItsOwnFolderIsSkipped() async throws {
        let catalog = try await preparedCatalog()
        let report = await ImageTransfer.run([request("A.NEF", to: root)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(report.completed.isEmpty)
        XCTAssertTrue(exists(root.appendingPathComponent("A.NEF")))
    }

    func testCollisionGetsANumberAndNeverOverwrites() async throws {
        let catalog = try await preparedCatalog()
        let day2 = root.appendingPathComponent("Day 2")
        // A different file already called A.NEF in Day 2.
        try fm.copyItem(atPath: Self.otherNEF, toPath: day2.appendingPathComponent("A.NEF").path)
        _ = try await catalog.reconcile()
        let occupant = try FileOperations.identity(XCTUnwrap(day2.appendingPathComponent("A.NEF")))

        let report = await ImageTransfer.run([request("A.NEF", to: day2)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.first?.destination.lastPathComponent, "A 2.NEF", report.failureDescription)
        XCTAssertEqual(FileOperations.identity(day2.appendingPathComponent("A.NEF")), occupant, "left untouched")

        let moved = try await XCTUnwrapAsync(await catalog.image(forRelPath: "Day 2/A 2.NEF"))
        XCTAssertEqual(moved.preservedName, "A.NEF", "the name it had is kept")
        let fields = try XMPSidecar.read(from: sidecar("Day 2/A 2.NEF"))
        XCTAssertEqual(fields.preservedFileName, "A.NEF")
        XCTAssertEqual(fields.rating, 4)

        // An exact name that is taken fails, and the image stays.
        let exact = await ImageTransfer.run([TransferRequest(source: root.appendingPathComponent("B.NEF"), folder: day2,
                                                             name: "A.NEF")], mode: .move, openCatalog: catalog)
        XCTAssertEqual(exact.failures.count, 1)
        XCTAssertTrue(exists(root.appendingPathComponent("B.NEF")))
    }

    /// A sidecar whose file has gone would be applied to anything given its
    /// name, so it takes the name as surely as a file does.
    func testALeftoverSidecarTakesItsName() async throws {
        let catalog = try await preparedCatalog()
        let day2 = root.appendingPathComponent("Day 2")
        let orphan = sidecar("Day 2/B.NEF")
        try XMPSidecar.write(.init(rating: 1, sourceHash: "xxh64:0"), to: orphan)

        let report = await ImageTransfer.run([request("B.NEF", to: day2)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.first?.destination.lastPathComponent, "B 2.NEF", report.failureDescription)
        XCTAssertEqual(try XMPSidecar.read(from: orphan).rating, 1, "the leftover is untouched")
    }

    func testCopyInTheSameFolderMakesANumberedCopyWithEverything() async throws {
        let catalog = try await preparedCatalog()
        let report = await ImageTransfer.run([request("A.NEF", to: root)], mode: .copy, openCatalog: catalog)
        XCTAssertEqual(report.completed.first?.destination.lastPathComponent, "A 2.NEF", report.failureDescription)

        let original = try await XCTUnwrapAsync(await catalog.image(forRelPath: "A.NEF"))
        let copy = try await XCTUnwrapAsync(await catalog.image(forRelPath: "A 2.NEF"))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.rating, 4)
        XCTAssertEqual(copy.preservedName, "A.NEF")
        let keywords = try await catalog.keywords(forImageID: copy.id!)
        XCTAssertEqual(keywords, ["dusk", "sea"])
        let edit = try await catalog.editStack(forImageID: copy.id!)
        XCTAssertEqual(edit, #"{"exposure":1}"#)
        XCTAssertTrue(exists(sidecar("A 2.NEF")))
        XCTAssertTrue(exists(thumbnail("A 2.NEF")))
        XCTAssertNil(original.preservedName)

        let reconcile = try await catalog.reconcile()
        XCTAssertEqual(reconcile.added + reconcile.removed + reconcile.renamed + reconcile.sidecarsRead, 0, "\(reconcile)")
        XCTAssertEqual(copy.thumbKey, original.thumbKey, "the copied thumbnail counts")
    }

    // MARK: - Between catalogs

    func testMoveIntoAnotherCatalogLeavesTheSidecarThereForItsReconcile() async throws {
        let catalog = try await preparedCatalog()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await Catalog.open(at: other).reconcile()

        let report = await ImageTransfer.run([request("A.NEF", to: other)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertFalse(exists(root.appendingPathComponent("A.NEF")))
        XCTAssertFalse(exists(sidecar("A.NEF")), "its content is in the new sidecar")
        let gone = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertNil(gone)
        XCTAssertTrue(exists(other.appendingPathComponent("_latent/xmp/A.NEF.xmp")))
        XCTAssertTrue(exists(other.appendingPathComponent("_latent/thumbnails/A.NEF.heic")))

        let archive = try Catalog.open(at: other)
        let reconcile = try await archive.reconcile()
        XCTAssertEqual(reconcile.added, 1)
        let arrived = try await XCTUnwrapAsync(await archive.image(forRelPath: "A.NEF"))
        XCTAssertEqual(arrived.rating, 4)
        let keywords = try await archive.keywords(forImageID: arrived.id!)
        XCTAssertEqual(keywords, ["dusk", "sea"])
        let edit = try await archive.editStack(forImageID: arrived.id!)
        XCTAssertEqual(edit, #"{"exposure":1}"#)

        let sourceReconcile = try await catalog.reconcile()
        XCTAssertEqual(sourceReconcile.removed, 0, "the row went with the file")
    }

    /// A folder inside another catalog that includes it: the sidecar goes to
    /// that catalog's _latent, under the folder's path there.
    func testMoveIntoAnIncludedSubfolderOfAnotherCatalog() async throws {
        let catalog = try await preparedCatalog()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        let inner = other.appendingPathComponent("2026", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let archive = try Catalog.open(at: other)
        try await archive.setSubfolderMode(.included, forRelPath: "2026")

        let report = await ImageTransfer.run([request("A.NEF", to: inner)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertTrue(exists(other.appendingPathComponent("_latent/xmp/2026/A.NEF.xmp")))
        XCTAssertFalse(exists(inner.appendingPathComponent("_latent")), "no catalog of its own")
        _ = try await archive.reconcile()
        let arrived = try await archive.image(forRelPath: "2026/A.NEF")
        XCTAssertEqual(arrived?.rating, 4)
    }

    func testAPlainFolderGetsACatalogOnlyForAnImageWithASidecar() async throws {
        let catalog = try await preparedCatalog()
        let plain = base.appendingPathComponent("Plain", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)

        var report = await ImageTransfer.run([request("B.NEF", to: plain)], mode: .copy, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertFalse(exists(plain.appendingPathComponent("_latent")), "B has nothing to carry")

        report = await ImageTransfer.run([request("A.NEF", to: plain)], mode: .copy, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertTrue(exists(plain.appendingPathComponent("_latent/xmp/A.NEF.xmp")))
        XCTAssertTrue(exists(plain.appendingPathComponent("_latent/.metadata_never_index")))
        XCTAssertTrue(exists(root.appendingPathComponent("A.NEF")), "a copy leaves the original")
        let original = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(original?.rating, 4)

        let opened = try Catalog.open(at: plain)
        _ = try await opened.reconcile()
        let copy = try await opened.image(forRelPath: "A.NEF")
        XCTAssertEqual(copy?.rating, 4)
    }

    /// Moving back from a catalog that isn't open (an undo after switching
    /// folders): files only, and the open catalog adds the row from the
    /// sidecar that came back.
    func testMoveFromACatalogThatIsNotOpen() async throws {
        let catalog = try await preparedCatalog()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        _ = await ImageTransfer.run([request("A.NEF", to: other)], mode: .move, openCatalog: catalog)

        let back = TransferRequest(source: other.appendingPathComponent("A.NEF"), folder: root, name: "A.NEF")
        let report = await ImageTransfer.run([back], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertFalse(exists(other.appendingPathComponent("_latent/xmp/A.NEF.xmp")))
        XCTAssertTrue(exists(sidecar("A.NEF")))
        let reconcile = try await catalog.reconcile()
        XCTAssertEqual(reconcile.added, 1)
        let returned = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(returned?.rating, 4)
    }

    /// A sidecar changed by another app since the catalog last read it is
    /// what goes with the image, not the row.
    func testASidecarChangedOutsideLatentIsCarriedAsItIs() async throws {
        let catalog = try await preparedCatalog()
        var fields = try XMPSidecar.read(from: sidecar("A.NEF"))
        fields.rating = 2
        try await Task.sleep(for: .milliseconds(20))   // a new mtime
        try XMPSidecar.write(fields, to: sidecar("A.NEF"))
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let day2 = root.appendingPathComponent("Day 2")

        var report = await ImageTransfer.run([request("A.NEF", to: other)], mode: .copy, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertEqual(try XMPSidecar.read(from: other.appendingPathComponent("_latent/xmp/A.NEF.xmp")).rating, 2)

        report = await ImageTransfer.run([request("A.NEF", to: day2)], mode: .move, openCatalog: catalog)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        _ = try await catalog.reconcile()
        let moved = try await catalog.image(forRelPath: "Day 2/A.NEF")
        XCTAssertEqual(moved?.rating, 2, "reconcile reads the moved sidecar")
    }

    // MARK: - Interruption and cancelling

    struct Interrupted: Error {}

    func testAFailureMidwayThroughAMoveLeavesTheImageWhereItWas() async throws {
        let catalog = try await preparedCatalog()
        let before = try await catalog.image(forRelPath: "A.NEF")
        let day2 = root.appendingPathComponent("Day 2")

        let report = await ImageTransfer.run([request("A.NEF", to: day2)], mode: .move, openCatalog: catalog,
                                             faults: TransferFaults(midway: { _ in throw Interrupted() }))
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(exists(root.appendingPathComponent("A.NEF")))
        XCTAssertFalse(exists(day2.appendingPathComponent("A.NEF")))
        XCTAssertTrue(exists(sidecar("A.NEF")))
        XCTAssertTrue(exists(thumbnail("A.NEF")))
        let after = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(after, before)
    }

    func testAFailureMidwayBetweenCatalogsRemovesTheSidecarItWrote() async throws {
        let catalog = try await preparedCatalog()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        let report = await ImageTransfer.run([request("A.NEF", to: other)], mode: .move, openCatalog: catalog,
                                             faults: TransferFaults(midway: { _ in throw Interrupted() }))
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(exists(root.appendingPathComponent("A.NEF")))
        XCTAssertFalse(exists(other.appendingPathComponent("A.NEF")))
        XCTAssertFalse(exists(other.appendingPathComponent("_latent/xmp/A.NEF.xmp")))
        XCTAssertFalse(exists(other.appendingPathComponent("_latent/thumbnails/A.NEF.heic")))
        XCTAssertTrue(exists(sidecar("A.NEF")))
        let row = try await catalog.image(forRelPath: "A.NEF")
        XCTAssertEqual(row?.rating, 4)
    }

    func testAFailedCopyLeavesNoHiddenFileAndTheRestCarryOn() async throws {
        let catalog = try await preparedCatalog()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        let report = await ImageTransfer.run([request("A.NEF", to: other), request("B.NEF", to: other)],
                                             mode: .copy, openCatalog: catalog,
                                             faults: TransferFaults(beforePlacing: { url in
                                                 if url.lastPathComponent == "A.NEF" { throw Interrupted() }
                                             }))
        XCTAssertEqual(report.failures.map(\.url.lastPathComponent), ["A.NEF"])
        XCTAssertEqual(report.completed.map(\.destination.lastPathComponent), ["B.NEF"])
        let leftovers = try fm.contentsOfDirectory(atPath: other.path).filter { $0.hasPrefix(".latent-") }
        XCTAssertEqual(leftovers, [])
        XCTAssertFalse(exists(other.appendingPathComponent("A.NEF")))
    }

    func testCancellingStopsBetweenImages() async throws {
        let catalog = try await preparedCatalog()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let cancellation = TransferCancellation()

        let report = await ImageTransfer.run([request("A.NEF", to: other), request("B.NEF", to: other)],
                                             mode: .move, openCatalog: catalog, cancellation: cancellation,
                                             faults: TransferFaults(beforePlacing: { _ in cancellation.cancel() }))
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.completed.count, 1, "the image under way finishes")
        XCTAssertTrue(exists(other.appendingPathComponent("A.NEF")))
        XCTAssertTrue(exists(root.appendingPathComponent("B.NEF")), "the rest stay")
    }

    // MARK: - Through the Library, with undo

    private func openLibrary() async throws -> (Library, UndoManager, URL) {
        _ = try await preparedCatalog()
        let library = Library()
        let undo = UndoManager()
        library.undoManager = undo
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        library.fileOperations.recycle = { urls in
            for url in urls {
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            }
        }
        try await library.open(folder: root)
        return (library, undo, trash)
    }

    private func undoing(_ undo: UndoManager, _ library: Library, redo: Bool = false) async {
        if redo { undo.redo() } else { undo.undo() }
        await library.waitForPendingWork()
        // The revert starts its operation a turn later.
        while library.fileOperations.isBusy || library.hasPendingWork {
            await library.waitForPendingWork()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func record(_ library: Library, _ relPath: String) -> ImageRecord? {
        library.images.first { $0.relPath == relPath }
    }

    func testMoveOutUndoAndRedo() async throws {
        let (library, undo, _) = try await openLibrary()
        let other = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let a = try XCTUnwrap(record(library, "A.NEF"))

        let report = await library.fileOperations.transfer([a], to: other, mode: .move)
        XCTAssertEqual(report.completed.count, 1, report.failureDescription)
        XCTAssertNil(record(library, "A.NEF"), "the grid no longer lists it")
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undoActionName, "Move “A.NEF”")

        await undoing(undo, library)
        XCTAssertTrue(exists(root.appendingPathComponent("A.NEF")))
        XCTAssertFalse(exists(other.appendingPathComponent("A.NEF")))
        XCTAssertFalse(exists(other.appendingPathComponent("_latent/xmp/A.NEF.xmp")))
        let back = try XCTUnwrap(record(library, "A.NEF"))
        XCTAssertEqual(back.rating, 4, "its sidecar came back with it")
        XCTAssertEqual(library.selectedImageIDs, [back.id!], "and it is selected")
        XCTAssertTrue(undo.canRedo)

        await undoing(undo, library, redo: true)
        XCTAssertTrue(exists(other.appendingPathComponent("A.NEF")))
        XCTAssertNil(record(library, "A.NEF"))
        XCTAssertTrue(undo.canUndo)

        await undoing(undo, library)
        XCTAssertNotNil(record(library, "A.NEF"))
    }

    func testUndoingACopyPutsTheCopyInTheTrash() async throws {
        let (library, undo, trash) = try await openLibrary()
        let a = try XCTUnwrap(record(library, "A.NEF"))
        let report = await library.fileOperations.transfer([a], to: root, mode: .copy)
        XCTAssertEqual(report.completed.first?.destination.lastPathComponent, "A 2.NEF", report.failureDescription)
        XCTAssertNotNil(record(library, "A 2.NEF"))

        await undoing(undo, library)
        XCTAssertFalse(exists(root.appendingPathComponent("A 2.NEF")))
        XCTAssertTrue(exists(trash.appendingPathComponent("A 2.NEF")))
        XCTAssertTrue(exists(trash.appendingPathComponent("A 2.NEF.xmp")), "its sidecar goes to the Trash too")
        XCTAssertNil(record(library, "A 2.NEF"))
        XCTAssertEqual(record(library, "A.NEF")?.rating, 4, "the original is untouched")

        await undoing(undo, library, redo: true)
        XCTAssertTrue(exists(root.appendingPathComponent("A 2.NEF")))
        XCTAssertEqual(record(library, "A 2.NEF")?.rating, 4)
    }

    func testRenameKeepsTheRowAndRecordsThePreservedName() async throws {
        let (library, undo, _) = try await openLibrary()
        let a = try XCTUnwrap(record(library, "A.NEF"))
        try await library.fileOperations.rename(a, to: "Sunset.NEF")
        let renamed = try XCTUnwrap(record(library, "Sunset.NEF"))
        XCTAssertEqual(renamed.id, a.id)
        XCTAssertEqual(renamed.preservedName, "A.NEF")
        XCTAssertTrue(exists(root.appendingPathComponent("Sunset.NEF")))
        XCTAssertTrue(exists(sidecar("Sunset.NEF")))
        XCTAssertEqual(try XMPSidecar.read(from: sidecar("Sunset.NEF")).preservedFileName, "A.NEF")
        XCTAssertTrue(exists(thumbnail("Sunset.NEF")))
        XCTAssertEqual(undo.undoActionName, "Rename")

        // Taken names are refused, the image staying as it is.
        do {
            try await library.fileOperations.rename(renamed, to: "B.NEF")
            XCTFail("B.NEF is taken")
        } catch {
            XCTAssertTrue("\(error)".contains("already taken"), "\(error)")
        }
        XCTAssertNotNil(record(library, "Sunset.NEF"))

        await undoing(undo, library)
        let restored = try XCTUnwrap(record(library, "A.NEF"))
        XCTAssertEqual(restored.id, a.id)
        XCTAssertNil(restored.preservedName, "it had none before the rename")
        XCTAssertNil(try XMPSidecar.read(from: sidecar("A.NEF")).preservedFileName)
    }

    /// On a case-insensitive volume (the default on a Mac) "a.NEF" is the
    /// same name as "A.NEF", yet renaming to it must work.
    func testRenameThatOnlyChangesCase() async throws {
        let (library, _, _) = try await openLibrary()
        let a = try XCTUnwrap(record(library, "A.NEF"))
        try await library.fileOperations.rename(a, to: "a.NEF")
        let renamed = try XCTUnwrap(record(library, "a.NEF"))
        XCTAssertEqual(renamed.id, a.id)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { $0.lowercased() == "a.nef" }, ["a.NEF"])
        XCTAssertEqual(renamed.rating, 4)
    }

    // MARK: - Names

    func testRenamedFileNameKeepsTheExtension() {
        XCTAssertEqual(try FileOperations.renamedFileName(base: "Sunset", original: "DSC_1.NEF").get(), "Sunset.NEF")
        XCTAssertEqual(try FileOperations.renamedFileName(base: " Sunset.nef ", original: "DSC_1.NEF").get(), "Sunset.NEF")
        XCTAssertEqual(try FileOperations.renamedFileName(base: "Sunset.jpg", original: "DSC_1.NEF").get(), "Sunset.jpg.NEF")
        XCTAssertThrowsError(try FileOperations.renamedFileName(base: "  ", original: "A.NEF").get())
        XCTAssertThrowsError(try FileOperations.renamedFileName(base: "a/b", original: "A.NEF").get())
        XCTAssertThrowsError(try FileOperations.renamedFileName(base: "a:b", original: "A.NEF").get())
        XCTAssertThrowsError(try FileOperations.renamedFileName(base: ".hidden", original: "A.NEF").get())
        XCTAssertThrowsError(try FileOperations.renamedFileName(base: String(repeating: "é", count: 200), original: "A.NEF").get())
    }

    func testUniqueNamesCountOn() {
        let taken: Set<String> = ["A.NEF", "A 2.NEF", "IMG 0042.NEF", "Trip 9.NEF"]
        XCTAssertEqual(FileOperations.uniqueName(for: "B.NEF") { taken.contains($0) }, "B.NEF")
        XCTAssertEqual(FileOperations.uniqueName(for: "A.NEF") { taken.contains($0) }, "A 3.NEF")
        XCTAssertEqual(FileOperations.uniqueName(for: "A 2.NEF") { taken.contains($0) }, "A 3.NEF")
        XCTAssertEqual(FileOperations.uniqueName(for: "IMG 0042.NEF") { taken.contains($0) }, "IMG 0042 2.NEF")
        XCTAssertEqual(FileOperations.uniqueName(for: "Trip 9.NEF") { taken.contains($0) }, "Trip 10.NEF")
        XCTAssertNil(FileOperations.uniqueName(for: "A.NEF", limit: 3) { _ in true })
    }
}

final class FolderHistoryTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/Photos/A", isDirectory: true)
    private let b = URL(fileURLWithPath: "/Photos/B", isDirectory: true)
    private let c = URL(fileURLWithPath: "/Photos/C", isDirectory: true)

    func testBackAndForwardWalkTheVisits() {
        var history = FolderHistory()
        XCTAssertFalse(history.canGoBack)
        history.visit(a)
        history.visit(b)
        history.visit(URL(fileURLWithPath: "/Photos/B/"))
        XCTAssertEqual(history.entries.count, 2, "reopening the same folder adds nothing")
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.step(-1)?.folder, a)
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
        XCTAssertNil(history.step(-1))
        XCTAssertEqual(history.step(1)?.folder, b)
        XCTAssertNil(history.step(1))
    }

    func testVisitingAfterGoingBackDropsWhatWasAhead() {
        var history = FolderHistory()
        history.visit(a)
        history.visit(b)
        _ = history.step(-1)
        history.visit(c)
        XCTAssertEqual(history.entries.map(\.folder), [a, c])
        XCTAssertFalse(history.canGoForward)
    }

    func testSelectionIsRememberedForTheFolderLeft() {
        var history = FolderHistory()
        history.visit(a)
        history.remember(selection: ["X.NEF", "Y.NEF"], lead: "Y.NEF", in: a)
        history.visit(b)
        let back = history.step(-1)
        XCTAssertEqual(back?.selection, ["X.NEF", "Y.NEF"])
        XCTAssertEqual(back?.lead, "Y.NEF")
        XCTAssertEqual(history.forwardEntry?.selection, [])
    }

    func testHistoryIsBounded() {
        var history = FolderHistory()
        for i in 0..<(FolderHistory.limit + 10) {
            history.visit(URL(fileURLWithPath: "/Photos/\(i)", isDirectory: true))
        }
        XCTAssertEqual(history.entries.count, FolderHistory.limit)
        XCTAssertEqual(history.index, FolderHistory.limit - 1)
        XCTAssertEqual(history.current?.folder.lastPathComponent, "\(FolderHistory.limit + 9)")
    }
}
