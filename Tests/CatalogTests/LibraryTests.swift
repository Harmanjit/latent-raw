import XCTest
@testable import Catalog

@MainActor
final class LibraryTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Day 2"),
                                                withIntermediateDirectories: true)
        for name in ["A.NEF", "B.NEF", "Day 2/C.NEF"] {
            try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                             toPath: folder.appendingPathComponent(name).path)
        }
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Waits until `condition` holds, or fails after `timeout`.
    private func eventually(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s")
    }

    func testOpenListsImagesAndGeneratesThumbnails() async throws {
        let library = Library()
        XCTAssertNil(library.selectedImage)

        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 2, "Day 2 is undecided, so only the root's two")
        XCTAssertEqual(library.undecidedSubfolders, ["Day 2"])
        XCTAssertFalse(library.isBusy)

        await eventually { library.thumbnailsTotal == 2 && library.thumbnailsDone == 2 }
        XCTAssertGreaterThan(library.thumbnailVersion, 0)

        let first = library.images[0]
        XCTAssertNil(library.cachedThumbnail(for: first), "nothing decoded yet")
        let image = await library.loadThumbnail(for: first)
        XCTAssertEqual(image?.width, 512)
        XCTAssertNotNil(library.cachedThumbnail(for: first), "now cached")
        XCTAssertEqual(library.fileURL(for: first)?.lastPathComponent, first.fileName)
    }

    func testSubfolderDecisionAndRefresh() async throws {
        let library = Library()
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 2)

        try await library.decideUndecidedSubfolders(include: true)
        XCTAssertEqual(library.images.count, 3)
        XCTAssertEqual(library.undecidedSubfolders, [])
        XCTAssertTrue(library.images.contains { $0.relPath == "Day 2/C.NEF" })

        // A file removed on disk disappears on refresh, and a selection
        // pointing at it is cleared rather than left dangling.
        library.selectedImageID = library.images.first { $0.relPath == "B.NEF" }?.id
        try FileManager.default.removeItem(at: folder.appendingPathComponent("B.NEF"))
        try await library.refresh()
        XCTAssertEqual(library.images.count, 2)
        XCTAssertNil(library.selectedImageID)
    }

    func testSelectionNavigationClampsAtEnds() async throws {
        let library = Library()
        XCTAssertNil(library.selectNext(), "nothing to select in an empty library")

        try await library.open(folder: folder)
        let ids = library.images.map(\.id)

        XCTAssertEqual(library.selectNext()?.id, ids[0], "first next selects the first image")
        XCTAssertEqual(library.selectNext()?.id, ids[1])
        XCTAssertNil(library.selectNext(), "already at the end")
        XCTAssertEqual(library.selectedImageID, ids[1])
        XCTAssertEqual(library.selectPrevious()?.id, ids[0])
        XCTAssertNil(library.selectPrevious(), "already at the start")

        library.selectedImageID = nil
        XCTAssertEqual(library.selectPrevious()?.id, ids[1], "previous from nothing selects the last")
    }

    /// The grid walks `visibleImages`; filters narrow it, sort orders it,
    /// and arrow-key navigation never lands on a hidden image.
    func testFilterAndSortDriveVisibleImagesAndNavigation() async throws {
        let library = Library()
        try await library.open(folder: folder)
        XCTAssertEqual(library.visibleImages.count, 2)
        XCTAssertEqual(library.visibleImages, library.images, "no filter: same list")

        // Both copies share a capture time, so name order is the tie-break.
        library.sort = LibrarySort(key: .fileName, ascending: false)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF", "A.NEF"])

        // Pick A, then show picks only.
        library.selectedImageID = library.images.first { $0.fileName == "A.NEF" }?.id
        try await library.setFlag(.picked)
        library.filter.flags = [.picked]
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"])
        XCTAssertNil(library.moveSelection(by: 1), "nothing after A in the filtered view")

        // Keywords: the index updates on edit, without a reload.
        library.filter = LibraryFilter()
        library.filter.keyword = "tree"
        XCTAssertEqual(library.visibleImages.count, 0)
        try await library.setKeywords(["tree", " sky "])
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"])
        XCTAssertEqual(library.availableKeywords, ["sky", "tree"])

        // Selection may point at a hidden image; the next step lands on a visible one.
        library.filter = LibraryFilter()
        library.filter.text = "B"
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
        XCTAssertNil(library.selectedIndex, "A is selected but hidden")
        XCTAssertEqual(library.moveSelection(by: 1)?.fileName, "B.NEF")

        // Refresh keeps the filter and the keyword index.
        try await library.refresh()
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
        library.filter = LibraryFilter()
        library.filter.keyword = "sky"
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"])
    }

    /// A batch transform skips an image whose stored edit can't be parsed
    /// and names it, rather than writing over it.
    func testTransformSkipsUnreadableEdits() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let a = library.images.first { $0.fileName == "A.NEF" }!
        let b = library.images.first { $0.fileName == "B.NEF" }!
        try await library.saveEditStack("{not json", schemaVersion: 1, processVersion: "1.0", forImageID: a.id!)
        try await library.saveEditStack("{\"schema\":1}", schemaVersion: 1, processVersion: "1.0", forImageID: b.id!)
        library.setSelection([a.id!, b.id!], primary: a.id)

        struct Unreadable: Error {}
        let outcome = try await library.transformSelectedEdits(schemaVersion: 1, processVersion: "1.0") { existing in
            guard let existing, existing.hasPrefix("{\"") else { throw Unreadable() }
            return "{\"schema\":1,\"pasted\":true}"
        }
        XCTAssertEqual(outcome.changed, 1)
        XCTAssertEqual(outcome.skipped, ["A.NEF"])
        let storedA = try await library.editStack(for: a)
        let storedB = try await library.editStack(for: b)
        XCTAssertEqual(storedA, "{not json", "untouched")
        XCTAssertEqual(storedB, "{\"schema\":1,\"pasted\":true}")
    }

    /// Paste and presets in Loupe, Compare and Develop change the image
    /// shown only, as ratings there do, never the rest of the selection.
    func testTransformCanActOnPrimaryOnly() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let a = library.images.first { $0.fileName == "A.NEF" }!
        let b = library.images.first { $0.fileName == "B.NEF" }!
        library.setSelection([a.id!, b.id!], primary: a.id)

        let outcome = try await library.transformSelectedEdits(onlyPrimary: true, schemaVersion: 1,
                                                               processVersion: "1.0") { _ in "{\"schema\":1,\"pasted\":true}" }
        XCTAssertEqual(outcome.changed, 1)
        let storedA = try await library.editStack(for: a)
        let storedB = try await library.editStack(for: b)
        XCTAssertEqual(storedA, "{\"schema\":1,\"pasted\":true}")
        XCTAssertNil(storedB, "the other selected image keeps its edit")
    }

    /// Rating, flag and rotation apply to every selected image, each
    /// rotated from its own angle, with a sidecar per image; keywords
    /// stay with the primary.
    /// Loupe, Compare and Develop show one image, so their keys change
    /// only the primary even when the grid selection behind them is larger.
    func testMetadataShortcutsCanActOnPrimaryOnly() async throws {
        let library = Library()
        try await library.open(folder: folder)
        try await library.decideUndecidedSubfolders(include: true)
        func record(_ name: String) -> ImageRecord { library.images.first { $0.fileName == name }! }
        let (a, b) = (record("A.NEF").id!, record("B.NEF").id!)

        library.setSelection([a, b], primary: a)
        try await library.setRating(3, onlyPrimary: true)
        try await library.setFlag(.rejected, onlyPrimary: true)
        try await library.rotateSelected(by: 1, onlyPrimary: true)

        XCTAssertEqual(record("A.NEF").rating, 3)
        XCTAssertEqual(record("A.NEF").flag, ImageFlag.rejected.rawValue)
        XCTAssertEqual(record("A.NEF").userRotation, 1)
        XCTAssertEqual(record("B.NEF").rating, 0)
        XCTAssertEqual(record("B.NEF").flag, ImageFlag.none.rawValue)
        XCTAssertEqual(record("B.NEF").userRotation, 0)
    }

    func testMetadataShortcutsApplyToWholeSelection() async throws {
        let library = Library()
        try await library.open(folder: folder)
        try await library.decideUndecidedSubfolders(include: true)
        func record(_ name: String) -> ImageRecord { library.images.first { $0.fileName == name }! }
        let (a, b, c) = (record("A.NEF").id!, record("B.NEF").id!, record("C.NEF").id!)

        // Turn A once on its own, so the batch turn starts from different angles.
        library.setSelection([a], primary: a)
        try await library.rotateSelected(by: 1)

        library.setSelection([a, b], primary: a)
        try await library.setRating(4)
        try await library.setFlag(.picked)
        try await library.rotateSelected(by: 1)
        try await library.setKeywords(["tree"])

        XCTAssertEqual(record("A.NEF").rating, 4)
        XCTAssertEqual(record("B.NEF").rating, 4)
        XCTAssertEqual(record("C.NEF").rating, 0, "not selected")
        XCTAssertEqual(record("A.NEF").userRotation, 2, "its own 1, plus 1")
        XCTAssertEqual(record("B.NEF").userRotation, 1, "its own 0, plus 1")
        XCTAssertEqual(record("C.NEF").userRotation, 0)

        // The in-memory rows drive the filters.
        library.filter.flags = [.picked]
        XCTAssertEqual(Set(library.visibleImages.map(\.fileName)), ["A.NEF", "B.NEF"])
        library.filter = LibraryFilter()
        library.filter.keyword = "tree"
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"], "keywords are primary-only")

        // Each changed image has its own sidecar saying so.
        let catalog = try XCTUnwrap(library.catalog)
        for (relPath, rotation) in [("A.NEF", 2), ("B.NEF", 1)] {
            let fields = try XMPSidecar.read(from: await catalog.sidecarURL(forRelPath: relPath))
            XCTAssertEqual(fields.rating, 4, relPath)
            XCTAssertEqual(fields.flag, ImageFlag.picked.rawValue, relPath)
            XCTAssertEqual(fields.rotation, rotation, relPath)
        }
        let bKeywords = try await catalog.keywords(forImageID: b)
        XCTAssertEqual(bKeywords, [])

        // The editor can make an image primary without touching the grid
        // selection; then only that image changes, not the stale set.
        library.selectedImageID = c
        try await library.setRating(1)
        XCTAssertEqual(record("C.NEF").rating, 1)
        XCTAssertEqual(record("A.NEF").rating, 4)
        XCTAssertEqual(record("B.NEF").rating, 4)
    }

    /// One image whose sidecar can't be written doesn't stop the others,
    /// and the failure is reported by name rather than dropped.
    func testSelectionChangeReportsFailuresAndFinishesTheRest() async throws {
        try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                         toPath: folder.appendingPathComponent("E.NEF").path)
        let library = Library()
        try await library.open(folder: folder)
        try await library.decideUndecidedSubfolders(include: true)
        XCTAssertEqual(library.images.map(\.fileName), ["A.NEF", "B.NEF", "C.NEF", "E.NEF"],
                       "C comes before E, so a failure on C has work after it")

        // A read-only sidecar folder for Day 2 makes C's sidecar write fail.
        let catalog = try XCTUnwrap(library.catalog)
        let day2 = await catalog.sidecarURL(forRelPath: "Day 2/C.NEF").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: day2.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: day2.path) }

        library.setSelection(Set(library.images.compactMap(\.id)), primary: library.images[0].id)
        do {
            try await library.setRating(5)
            XCTFail("C's sidecar can't be written")
        } catch let error as Library.SelectionChangeError {
            XCTAssertEqual(error.total, 4)
            XCTAssertEqual(error.failures.map(\.fileName), ["C.NEF"])
            XCTAssertTrue(String(describing: error).hasPrefix("1 of 4 images: C.NEF"))
        }
        for name in ["A.NEF", "B.NEF", "E.NEF"] {
            XCTAssertEqual(library.images.first { $0.fileName == name }?.rating, 5, name)
        }
        let eFields = try XMPSidecar.read(from: await catalog.sidecarURL(forRelPath: "E.NEF"))
        XCTAssertEqual(eFields.rating, 5, "the image after the failure got its sidecar")
        // C's row committed before its sidecar failed; the grid shows the row.
        XCTAssertEqual(library.images.first { $0.fileName == "C.NEF" }?.rating, 5)

        // Through perform, as the app calls it, the failure lands in lastError.
        library.perform("Rating") { try await library.setRating(2) }
        await eventually { library.lastError?.contains("C.NEF") == true }
    }
}
