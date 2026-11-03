import XCTest
@testable import Catalog

/// Recently Added, a photo that leaves the folder and comes back, and
/// Auto Import, against real raws. Skips without one (TestAssets/README.md).
final class RecentlyAddedTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testTheLatestBatchIsKeptUntilAnotherAddsSomething() async throws {
        let catalog = try Catalog.open(at: folder)
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.addedIDs.count, 1)
        var recent = try await catalog.recentlyAdded()
        XCTAssertEqual(recent?.ids, report.addedIDs, "a first open adds everything")

        report = try await catalog.reconcile()
        XCTAssertTrue(report.addedIDs.isEmpty)
        let again = try await catalog.recentlyAdded()
        XCTAssertEqual(again, recent, "a scan that found nothing leaves the batch")

        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        try TestAssets.copyD750(to: folder.appendingPathComponent("C.NEF"), variant: 2)
        report = try await catalog.reconcile()
        recent = try await catalog.recentlyAdded()
        XCTAssertEqual(Set(recent?.ids ?? []), Set(report.addedIDs))
        XCTAssertEqual(recent?.ids.count, 2)

        // A renamed photo stays in the batch; a deleted one leaves it.
        try FileManager.default.moveItem(at: folder.appendingPathComponent("B.NEF"),
                                         to: folder.appendingPathComponent("B2.NEF"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("C.NEF"))
        report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1)
        let b = try await catalog.image(forRelPath: "B2.NEF")
        let left = try await catalog.recentlyAdded()
        XCTAssertEqual(left?.ids, [b!.id!])
    }

    func testTheBatchSurvivesReopeningTheCatalog() async throws {
        var catalog: Catalog? = try Catalog.open(at: folder)
        _ = try await catalog!.reconcile()
        let before = try await catalog!.recentlyAdded()
        catalog = nil
        let reopened = try Catalog.open(at: folder)
        let after = try await reopened.recentlyAdded()
        XCTAssertNotNil(before)
        XCTAssertEqual(after?.ids, before?.ids)
    }

    @MainActor
    func testTheRecentlyAddedViewShowsTheBatchAndFollowsTheNextOne() async throws {
        let library = Library()
        try await library.open(folder: folder)
        XCTAssertEqual(library.recentlyAdded?.ids.count, 1)

        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        try await library.refresh()
        XCTAssertEqual(library.images.count, 2)
        library.showRecentlyAdded(true)
        XCTAssertTrue(library.isShowingRecentlyAdded)
        XCTAssertTrue(library.filter.isActive)
        XCTAssertEqual(library.visibleImages.map(\.relPath), ["B.NEF"])

        try TestAssets.copyD750(to: folder.appendingPathComponent("C.NEF"), variant: 2)
        try await library.refresh()
        XCTAssertEqual(library.visibleImages.map(\.relPath), ["C.NEF"], "the view follows the newest batch")

        // The other filters still apply.
        library.filter.text = "nothing like it"
        XCTAssertTrue(library.visibleImages.isEmpty)
        library.filter = LibraryFilter()
        XCTAssertFalse(library.isShowingRecentlyAdded, "Clear Filters turns it off")
        XCTAssertEqual(library.visibleImages.count, 3)
    }

    @MainActor
    func testOpeningAnotherFolderDropsTheView() async throws {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-recent-other-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let library = Library()
        try await library.open(folder: folder)
        library.showRecentlyAdded(true)
        XCTAssertTrue(library.isShowingRecentlyAdded)
        // A folder with a catalog but nothing added: an empty one.
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await library.open(folder: other)
        XCTAssertNil(library.recentlyAdded)
        XCTAssertFalse(library.isShowingRecentlyAdded, "ids belong to the other catalog")
    }

    /// Why Latent has no Locate Missing Photo: a photo that leaves the
    /// folder takes only its row; its sidecar stays, and putting the file
    /// back brings its rating and edit back with it.
    func testAPhotoPutBackGetsItsRatingAndEditBack() async throws {
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let id = try await catalog.image(forRelPath: "A.NEF")!.id!
        _ = try await catalog.exchangeRating(4, forImageID: id)
        try await catalog.setEditStack(#"{"exposure":1}"#, forImageID: id)

        let away = FileManager.default.temporaryDirectory.appendingPathComponent("latent-away-\(UUID().uuidString).NEF")
        defer { try? FileManager.default.removeItem(at: away) }
        try FileManager.default.moveItem(at: folder.appendingPathComponent("A.NEF"), to: away)
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 1)
        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "the sidecar stays behind")

        try FileManager.default.moveItem(at: away, to: folder.appendingPathComponent("A.NEF"))
        report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        let back = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(back.rating, 4)
        let edit = try await catalog.editStack(forImageID: back.id!)
        XCTAssertEqual(edit, #"{"exposure":1}"#)
    }
}

final class AutoImportTests: XCTestCase {
    var root: URL!
    var source: URL!
    var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-autoimport-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Incoming", isDirectory: true)
        destination = root.appendingPathComponent("Shoot", isDirectory: true)
        for folder in [source!, destination!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFoldersThatWouldImportIntoThemselvesAreRefused() {
        XCTAssertNil(AutoImport.problem(source: source, destination: destination))
        XCTAssertNotNil(AutoImport.problem(source: source, destination: source))
        XCTAssertNotNil(AutoImport.problem(source: source, destination: source.appendingPathComponent("Sub")))
        XCTAssertNotNil(AutoImport.problem(source: destination.appendingPathComponent("In"), destination: destination))
        XCTAssertNotNil(AutoImport.problem(source: destination.appendingPathComponent("_latent/x"), destination: source))
    }

    func testOnlyFilesThatStoppedChangingAreTaken() {
        let a = source.appendingPathComponent("A.NEF"), b = source.appendingPathComponent("B.NEF")
        let t = Date(timeIntervalSince1970: 1_000)
        let before = [a: AutoImportSignature(size: 10, modified: t, changed: t),
                      b: AutoImportSignature(size: 5, modified: t, changed: t)]
        var after = before
        after[b] = AutoImportSignature(size: 8, modified: t, changed: t.addingTimeInterval(1))
        let c = source.appendingPathComponent("C.NEF")
        after[c] = AutoImportSignature(size: 3, modified: t, changed: t)
        XCTAssertEqual(AutoImport.settled(before: before, after: after), [a],
                       "B is still growing; C was only just seen")
        let empty = [a: AutoImportSignature(size: 0, modified: t, changed: t)]
        XCTAssertTrue(AutoImport.settled(before: empty, after: empty).isEmpty, "an empty file is still being made")
    }

    func testLookListsOnlyRawFilesDirectlyInTheFolder() throws {
        try Data("x".utf8).write(to: source.appendingPathComponent("A.NEF"))
        try Data("x".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: source.appendingPathComponent(".hidden.NEF"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("Sub/B.NEF"))
        XCTAssertEqual(AutoImport.look(in: source).keys.map(\.lastPathComponent), ["A.NEF"])
    }

    func testTheLedgerRemembersCopiesAndForgetsTheOldest() {
        var ledger = AutoImportLedger()
        let signature = AutoImportSignature(size: 1, modified: Date(timeIntervalSince1970: 5), changed: .distantPast)
        let key = AutoImportLedger.key(name: "A.NEF", signature: signature)
        ledger.insert(key)
        ledger.insert(key)
        XCTAssertEqual(ledger.keys.count, 1)
        XCTAssertTrue(ledger.contains(key))
        var other = signature
        other.size = 2
        XCTAssertFalse(ledger.contains(AutoImportLedger.key(name: "A.NEF", signature: other)),
                       "another photo under a reused name is still imported")
        for i in 0..<AutoImportLedger.capacity { ledger.insert("k\(i)") }
        XCTAssertFalse(ledger.contains(key))
        XCTAssertEqual(ledger.keys.count, AutoImportLedger.capacity)
    }

    func testMovedPhotosArriveWithThePresetAndKeepTakenNames() async throws {
        try TestAssets.copyD750(to: source.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: destination.appendingPathComponent("A.NEF"), variant: 1)
        let edit = AutoImportEdit(json: #"{"exposure":0.5}"#, schemaVersion: 1, processVersion: "1.0")
        let report = await AutoImport.run([source.appendingPathComponent("A.NEF")], to: destination,
                                          mode: .move, edit: edit, openCatalog: nil)
        XCTAssertTrue(report.failures.isEmpty, report.summary)
        XCTAssertTrue(report.presetsNotApplied.isEmpty, report.summary)
        XCTAssertEqual(report.imported.map(\.lastPathComponent), ["A 2.NEF"], "nothing is overwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("A.NEF").path))

        let catalog = try Catalog.open(at: destination)
        let scan = try await catalog.reconcile()
        XCTAssertEqual(scan.added, 2)
        let imported = try await catalog.image(forRelPath: "A 2.NEF")!
        let stored = try await catalog.editStack(forImageID: imported.id!)
        XCTAssertEqual(stored, #"{"exposure":0.5}"#)
        let other = try await catalog.image(forRelPath: "A.NEF")!
        let none = try await catalog.editStack(forImageID: other.id!)
        XCTAssertNil(none, "the photo already there is untouched")
        let recent = try await catalog.recentlyAdded()
        XCTAssertEqual(recent?.ids.count, 2)
    }

    func testCopyingLeavesTheOriginalAndIntoTheOpenCatalog() async throws {
        try TestAssets.copyD750(to: source.appendingPathComponent("A.NEF"))
        let catalog = try Catalog.open(at: destination)
        _ = try await catalog.reconcile()
        let report = await AutoImport.run([source.appendingPathComponent("A.NEF")], to: destination,
                                          mode: .copy, edit: nil, openCatalog: catalog)
        XCTAssertEqual(report.imported.count, 1, report.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("A.NEF").path))
        let scan = try await catalog.reconcile()
        XCTAssertEqual(scan.added, 1)
    }

    func testAPhotoThatBringsItsOwnSidecarKeepsIt() async throws {
        // The watched folder is a catalog of its own: its photo's sidecar
        // travels with it and the preset doesn't replace it.
        try TestAssets.copyD750(to: source.appendingPathComponent("A.NEF"))
        let sourceCatalog = try Catalog.open(at: source)
        _ = try await sourceCatalog.reconcile()
        let id = try await sourceCatalog.image(forRelPath: "A.NEF")!.id!
        _ = try await sourceCatalog.exchangeRating(3, forImageID: id)
        let edit = AutoImportEdit(json: #"{"exposure":0.5}"#, schemaVersion: 1, processVersion: "1.0")
        let report = await AutoImport.run([source.appendingPathComponent("A.NEF")], to: destination,
                                          mode: .move, edit: edit, openCatalog: nil)
        XCTAssertEqual(report.imported.count, 1, report.summary)
        XCTAssertEqual(report.presetsNotApplied.count, 1)
        let catalog = try Catalog.open(at: destination)
        _ = try await catalog.reconcile()
        let arrived = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(arrived.rating, 3)
    }
}

final class VolumeSpaceTests: XCTestCase {
    func testFoldersOnOneDiskShareOneMeter() {
        let tmp = FileManager.default.temporaryDirectory
        let volumes = VolumeSpace.volumes(for: [tmp, tmp.appendingPathComponent("does-not-matter"), tmp])
        XCTAssertEqual(volumes.count, 1)
        let volume = volumes[0]
        XCTAssertGreaterThan(volume.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(volume.usedFraction, 0)
        XCTAssertLessThanOrEqual(volume.usedFraction, 1)
        XCTAssertTrue(volume.summary.contains("free of"))
    }

    func testAFolderThatIsGoneIsLeftOut() {
        XCTAssertTrue(VolumeSpace.volumes(for: [URL(fileURLWithPath: "/Volumes/latent-no-such-disk-\(UUID())")]).isEmpty)
    }

    func testLowSpaceWarns() {
        let disk = { (free: Int64) in VolumeSpace(url: URL(fileURLWithPath: "/"), name: "Disk", totalBytes: 1_000_000_000_000, availableBytes: free) }
        XCTAssertFalse(disk(400_000_000_000).isLow)
        XCTAssertTrue(disk(50_000_000_000).isLow, "under 10%")
        XCTAssertEqual(disk(250_000_000_000).usedFraction, 0.75, accuracy: 1e-9)
        let small = VolumeSpace(url: URL(fileURLWithPath: "/"), name: "Card", totalBytes: 32_000_000_000, availableBytes: 4_000_000_000)
        XCTAssertTrue(small.isLow, "under 5 GB")
    }
}
