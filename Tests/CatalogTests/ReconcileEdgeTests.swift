import XCTest
@testable import Catalog

/// Reconcile's edge branches: what happens to rows, sidecars and
/// thumbnails when files change outside Latent in awkward ways. Runs on
/// CI with the golden D750 raw; `copyD750(variant:)` makes distinct
/// images from it.
final class ReconcileEdgeTests: XCTestCase {
    var folder: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        _ = try TestAssets.d750URL()
        folder = fm.temporaryDirectory
            .appendingPathComponent("latent-reconcile-edge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Catalog.datalessOverrideForTesting = nil
        if let folder { try? fm.removeItem(at: folder) }
    }

    // MARK: - Helpers

    private func url(_ relPath: String) -> URL { folder.appendingPathComponent(relPath) }

    private func add(_ relPath: String, variant: Int = 0) throws {
        try fm.createDirectory(at: url(relPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestAssets.copyD750(to: url(relPath), variant: variant)
    }

    private func move(_ from: String, _ to: String) throws {
        try fm.moveItem(at: url(from), to: url(to))
    }

    private func row(_ catalog: Catalog, _ relPath: String) async throws -> ImageRecord {
        let row = try await catalog.image(forRelPath: relPath)
        return try XCTUnwrap(row, "no row for \(relPath)")
    }

    /// Writes a sidecar for the row at `relPath` with its real source hash.
    private func writeSidecar(_ catalog: Catalog, _ relPath: String, rating: Int, label: String? = nil,
                              flag: Int = 0, rotation: Int = 0, keywords: [String] = [],
                              edit: String = "") async throws {
        let record = try await row(catalog, relPath)
        let sidecar = await catalog.sidecarURL(forRelPath: relPath)
        try XMPSidecar.write(.init(rating: rating, label: label, flag: flag, rotation: rotation,
                                   keywords: keywords, sourceHash: record.hashString,
                                   editStackJSON: edit), to: sidecar)
    }

    private func sidecarRating(_ catalog: Catalog, _ relPath: String) async throws -> Int {
        try XMPSidecar.read(from: await catalog.sidecarURL(forRelPath: relPath)).rating
    }

    /// Sidecars in `_latent/xmp/` set aside as orphans.
    private func orphans(_ catalog: Catalog) async throws -> [URL] {
        let dir = await catalog.xmpDirectory
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".orphaned-") }
    }

    private func hiddenLeftovers(_ catalog: Catalog) async throws -> [String] {
        let container = await catalog.containerPath
        let all = fm.enumerator(atPath: container.path)?.allObjects as? [String] ?? []
        return all.filter { ($0 as NSString).lastPathComponent.hasPrefix(".latent-rename-") }
    }

    // MARK: - Finding 31: case-only rename

    func testCaseOnlyRenameKeepsSidecarAndThumbnail() async throws {
        let caseSensitive = try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try XCTSkipIf(caseSensitive, "needs a case-insensitive volume")

        try add("Sunset.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "Sunset.NEF", rating: 4, keywords: ["dusk"], edit: #"{"exposure":1}"#)
        _ = try await catalog.reconcile()
        let thumbnail = await catalog.thumbnailURL(forRelPath: "Sunset.NEF")
        try fm.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("thumb".utf8).write(to: thumbnail)

        try FileOperations.renameAllowingCaseChange(url("Sunset.NEF"), to: url("sunset.NEF"))
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1, "\(report)")
        XCTAssertEqual(report.added + report.removed, 0, "\(report)")

        let moved = try await row(catalog, "sunset.NEF")
        XCTAssertEqual(moved.rating, 4)
        let edit = try await catalog.editStack(forImageID: moved.id!)
        XCTAssertEqual(edit, #"{"exposure":1}"#)
        let keywords = try await catalog.keywords(forImageID: moved.id!)
        XCTAssertEqual(keywords, ["dusk"])
        let sidecar = await catalog.sidecarURL(forRelPath: "sunset.NEF")
        XCTAssertEqual(try XMPSidecar.read(from: sidecar).rating, 4)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: sidecar.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".xmp") }, ["sunset.NEF.xmp"], "the new spelling is on disk")
        let newThumbnail = await catalog.thumbnailURL(forRelPath: "sunset.NEF")
        XCTAssertEqual(try Data(contentsOf: newThumbnail), Data("thumb".utf8))
        let leftovers = try await hiddenLeftovers(catalog)
        XCTAssertEqual(leftovers, [])

        // And the next pass leaves it all alone.
        let again = try await catalog.reconcile()
        XCTAssertEqual(again.unchanged, 1)
        XCTAssertEqual(again.sidecarsRead, 0)
        let ratingAfter = try await row(catalog, "sunset.NEF").rating
        XCTAssertEqual(ratingAfter, 4)
    }

    // MARK: - Finding 32: rename onto a leftover sidecar

    func testRenameOntoALeftoverSidecarSetsItAside() async throws {
        try add("A.NEF")
        try add("B.NEF", variant: 1)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "A.NEF", rating: 4)
        try await writeSidecar(catalog, "B.NEF", rating: 2, keywords: ["keep"])
        _ = try await catalog.reconcile()

        try fm.removeItem(at: url("B.NEF"))
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 1)
        let bSidecar = await catalog.sidecarURL(forRelPath: "B.NEF")
        XCTAssertTrue(fm.fileExists(atPath: bSidecar.path), "a deleted file's sidecar stays")

        try move("A.NEF", "B.NEF")
        report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 1, "\(report)")
        let renamedRating = try await row(catalog, "B.NEF").rating
        XCTAssertEqual(renamedRating, 4, "the renamed file keeps its own metadata")
        XCTAssertEqual(try XMPSidecar.read(from: bSidecar).rating, 4)

        let aside = try await orphans(catalog)
        XCTAssertEqual(aside.count, 1, "B's sidecar is set aside, not deleted")
        let kept = try XMPSidecar.read(from: try XCTUnwrap(aside.first))
        XCTAssertEqual(kept.rating, 2)
        XCTAssertEqual(kept.keywords, ["keep"])
    }

    // MARK: - Finding 33: a leftover sidecar meets a different file

    func testLeftoverSidecarIsNotAppliedToADifferentFile() async throws {
        try add("A.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "A.NEF", rating: 5, edit: #"{"crop":1}"#)
        _ = try await catalog.reconcile()

        try fm.removeItem(at: url("A.NEF"))
        _ = try await catalog.reconcile()
        try add("A.NEF", variant: 1)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.sidecarsRead, 0, "\(report)")

        let fresh = try await row(catalog, "A.NEF")
        XCTAssertEqual(fresh.rating, 0)
        let edit = try await catalog.editStack(forImageID: fresh.id!)
        XCTAssertNil(edit)
        let aside = try await orphans(catalog)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try XMPSidecar.read(from: try XCTUnwrap(aside.first)).rating, 5)
    }

    /// The reason a deleted file's sidecar is kept: the same file put back
    /// (from the Trash) gets everything back.
    func testSameFilePutBackGetsItsSidecar() async throws {
        try add("A.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "A.NEF", rating: 5)
        _ = try await catalog.reconcile()
        try fm.removeItem(at: url("A.NEF"))
        _ = try await catalog.reconcile()

        try add("A.NEF")
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.sidecarsRead, 1)
        let restoredRating = try await row(catalog, "A.NEF").rating
        XCTAssertEqual(restoredRating, 5)
        let aside = try await orphans(catalog)
        XCTAssertEqual(aside, [])
    }

    // MARK: - Finding 35: legacy container in a subfolder

    func testSubfolderWithLegacyContainerIsItsOwnCatalog() async throws {
        try add("A.NEF")
        try add("Day 2/X.NEF", variant: 1)
        try fm.createDirectory(at: url("Day 2/_rawhead/xmp"), withIntermediateDirectories: true)

        let catalog = try Catalog.open(at: folder)
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.undecidedSubfolders, [], "not asked about: it's a catalog")

        try await catalog.setDefaultSubfolderMode(.included)
        report = try await catalog.reconcile()
        let paths = try await catalog.allImages().map(\.relPath)
        XCTAssertEqual(paths, ["A.NEF"])
        let mode = try await catalog.subfolderMode(forRelPath: "Day 2")
        XCTAssertNil(mode, "no row in this catalog's subfolders table")
    }

    // MARK: - Finding 37: removal cleans up keywords and thumbnail

    func testRemovalDropsKeywordsAndThumbnail() async throws {
        try add("A.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "A.NEF", rating: 1, keywords: ["solo"])
        _ = try await catalog.reconcile()
        var keywords = try await catalog.allImageKeywords()
        XCTAssertEqual(keywords.values.first, ["solo"])
        let thumbnail = await catalog.thumbnailURL(forRelPath: "A.NEF")
        try fm.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("thumb".utf8).write(to: thumbnail)

        try fm.removeItem(at: url("A.NEF"))
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 1)
        keywords = try await catalog.allImageKeywords()
        XCTAssertEqual(keywords, [:])
        let queue = await catalog.dbQueue
        let count = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image_keywords") }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(fm.fileExists(atPath: thumbnail.path))
        let sidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        XCTAssertTrue(fm.fileExists(atPath: sidecar.path), "the sidecar is truth and stays")
    }

    // MARK: - Finding 40: rename chains and swaps

    func testRenameChainFollowsContent() async throws {
        try add("A.NEF")
        try add("B.NEF", variant: 1)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let hashA = try await row(catalog, "A.NEF").xxhash
        let hashB = try await row(catalog, "B.NEF").xxhash
        try await writeSidecar(catalog, "A.NEF", rating: 5, edit: #"{"a":1}"#)
        try await writeSidecar(catalog, "B.NEF", rating: 1, edit: #"{"b":1}"#)
        _ = try await catalog.reconcile()

        try move("B.NEF", "C.NEF")
        try move("A.NEF", "B.NEF")
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 2, "\(report)")
        XCTAssertEqual(report.added + report.modified + report.removed, 0, "\(report)")

        let b = try await row(catalog, "B.NEF")
        XCTAssertEqual(b.xxhash, hashA)
        XCTAssertEqual(b.rating, 5)
        let bEdit = try await catalog.editStack(forImageID: b.id!)
        XCTAssertEqual(bEdit, #"{"a":1}"#)
        let c = try await row(catalog, "C.NEF")
        XCTAssertEqual(c.xxhash, hashB)
        XCTAssertEqual(c.rating, 1)
        let bSidecarRating = try await sidecarRating(catalog, "B.NEF")
        XCTAssertEqual(bSidecarRating, 5)
        let cSidecarRating = try await sidecarRating(catalog, "C.NEF")
        XCTAssertEqual(cSidecarRating, 1)
        let oldSidecar = await catalog.sidecarURL(forRelPath: "A.NEF")
        XCTAssertFalse(fm.fileExists(atPath: oldSidecar.path))
        let aside = try await orphans(catalog)
        XCTAssertEqual(aside, [])
    }

    func testSwapFollowsContent() async throws {
        try add("A.NEF")
        try add("B.NEF", variant: 1)
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let hashA = try await row(catalog, "A.NEF").xxhash
        try await writeSidecar(catalog, "A.NEF", rating: 5)
        try await writeSidecar(catalog, "B.NEF", rating: 1)
        _ = try await catalog.reconcile()

        try move("A.NEF", "tmp.NEF")
        try move("B.NEF", "A.NEF")
        try move("tmp.NEF", "B.NEF")
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 2, "\(report)")
        XCTAssertEqual(report.added + report.modified + report.removed, 0, "\(report)")
        let b = try await row(catalog, "B.NEF")
        XCTAssertEqual(b.xxhash, hashA)
        XCTAssertEqual(b.rating, 5)
        let aRating = try await row(catalog, "A.NEF").rating
        XCTAssertEqual(aRating, 1)
        let bSidecarRating = try await sidecarRating(catalog, "B.NEF")
        XCTAssertEqual(bSidecarRating, 5)
        let aSidecarRating = try await sidecarRating(catalog, "A.NEF")
        XCTAssertEqual(aSidecarRating, 1)
    }

    // MARK: - Finding 187: identical copies renamed together

    func testIdenticalCopiesRenamedTogetherBothFollow() async throws {
        try add("A.NEF")
        try add("B.NEF")
        let catalog = try Catalog.open(at: folder)
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 2)
        try await writeSidecar(catalog, "B.NEF", rating: 5, edit: #"{"b":1}"#)
        _ = try await catalog.reconcile()

        try move("A.NEF", "Trip-1.NEF")
        try move("B.NEF", "Trip-2.NEF")
        report = try await catalog.reconcile()
        XCTAssertEqual(report.renamed, 2, "\(report)")
        XCTAssertEqual(report.added + report.removed, 0, "\(report)")
        let images = try await catalog.allImages()
        XCTAssertEqual(images.map(\.relPath).sorted(), ["Trip-1.NEF", "Trip-2.NEF"])
        XCTAssertEqual(images.filter { $0.rating == 5 }.count, 1)
        let xmp = try fm.contentsOfDirectory(atPath: await catalog.xmpDirectory.path).sorted()
        XCTAssertEqual(xmp.count, 1)
        XCTAssertTrue(xmp[0].hasPrefix("Trip-"), "\(xmp)")
    }

    func testIdenticalCopiesDeletedTogetherAreBothRemoved() async throws {
        try add("A.NEF")
        try add("B.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try fm.removeItem(at: url("A.NEF"))
        try fm.removeItem(at: url("B.NEF"))
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.removed, 2)
        let count = try await catalog.imageCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Finding 190: packages

    func testPackagesAreNotEntered() async throws {
        try add("A.NEF")
        try add("Shots.photoslibrary/originals/B.NEF", variant: 1)
        let isPackage = try url("Shots.photoslibrary").resourceValues(forKeys: [.isPackageKey]).isPackage ?? false
        try XCTSkipUnless(isPackage, "this Mac doesn't know .photoslibrary as a package")

        let catalog = try Catalog.open(at: folder)
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.undecidedSubfolders, [])
        try await catalog.setDefaultSubfolderMode(.included)
        report = try await catalog.reconcile()
        let paths = try await catalog.allImages().map(\.relPath)
        XCTAssertEqual(paths, ["A.NEF"])
    }

    // MARK: - Finding 197: special files

    func testNamedPipeWithARawNameIsSkipped() async throws {
        try add("A.NEF")
        let pipe = url("x.nef").path
        XCTAssertEqual(mkfifo(pipe, 0o644), 0)

        // Should reconcile block on the pipe, a writer that comes and goes
        // lets it finish, so the suite can't hang; the flag says so.
        let unblocked = UnblockFlag()
        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let fd = open(pipe, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { unblocked.set(); close(fd) }
        }
        defer { watchdog.cancel() }

        let catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        XCTAssertFalse(unblocked.value, "reconcile waited on the pipe")
        let paths = try await catalog.allImages().map(\.relPath)
        XCTAssertEqual(paths, ["A.NEF"])
        XCTAssertEqual(report.failures.count, 0, "\(report.failures)")
    }

    // MARK: - Finding 194: files whose contents are in iCloud

    func testDatalessFilesAreNotOpened() async throws {
        try add("A.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()

        try add("B.NEF", variant: 1)
        Catalog.datalessOverrideForTesting = { $0.lastPathComponent != "C.NEF" }
        var report = try await catalog.reconcile()
        XCTAssertEqual(report.notDownloaded, ["B.NEF"])
        XCTAssertEqual(report.unchanged, 1, "an evicted file already catalogued stays as it is")
        XCTAssertEqual(report.added + report.removed + report.failures.count, 0, "\(report)")

        Catalog.datalessOverrideForTesting = nil
        report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 1, "downloaded, it is catalogued")
        XCTAssertEqual(report.notDownloaded, [])
    }

    // MARK: - Finding 44: other branches

    func testSidecarDeletedOutsideLatentResetsTheRow() async throws {
        try add("A.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "A.NEF", rating: 3, label: "Red", flag: 1, rotation: 1,
                               keywords: ["k"], edit: #"{"e":1}"#)
        _ = try await catalog.reconcile()
        var a = try await row(catalog, "A.NEF")
        XCTAssertEqual(a.rating, 3)

        try fm.removeItem(at: await catalog.sidecarURL(forRelPath: "A.NEF"))
        _ = try await catalog.reconcile()
        a = try await row(catalog, "A.NEF")
        XCTAssertEqual(a.rating, 0)
        XCTAssertNil(a.label)
        XCTAssertEqual(a.flag, 0)
        XCTAssertEqual(a.userRotation, 0)
        XCTAssertNil(a.sidecarMtime)
        let keywords = try await catalog.keywords(forImageID: a.id!)
        XCTAssertEqual(keywords, [])
        let edit = try await catalog.editStack(forImageID: a.id!)
        XCTAssertNil(edit)
    }

    func testModifiedFileKeepsMetadataAndDropsThumbnail() async throws {
        try add("A.NEF")
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        try await writeSidecar(catalog, "A.NEF", rating: 3, label: "Blue", flag: -1, rotation: 2)
        _ = try await catalog.reconcile()
        let before = try await row(catalog, "A.NEF")
        let queue = await catalog.dbQueue
        try await queue.write { db in
            try db.execute(sql: "UPDATE images SET thumb_key = 'k' WHERE id = ?", arguments: [before.id])
        }

        // Rewritten in place by another app: new bytes, same name.
        let handle = try FileHandle(forWritingTo: url("A.NEF"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("rewritten".utf8))
        try handle.close()
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.modified, 1, "\(report)")
        XCTAssertEqual(report.sidecarsRead, 0)
        let after = try await row(catalog, "A.NEF")
        XCTAssertEqual(after.id, before.id)
        XCTAssertNotEqual(after.xxhash, before.xxhash)
        XCTAssertEqual(after.rating, 3)
        XCTAssertEqual(after.label, "Blue")
        XCTAssertEqual(after.flag, -1)
        XCTAssertEqual(after.userRotation, 2)
        XCTAssertNil(after.thumbKey)
    }
}

private final class UnblockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
