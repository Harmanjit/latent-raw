import XCTest
@testable import Catalog

/// The Library behaviour the grid relies on: selection leads, in-place
/// record changes, and thumbnails through the bounded loader.
@MainActor
final class LibraryGridTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-librarygrid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["A.NEF", "B.NEF", "C.NEF"] {
            try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                             toPath: folder.appendingPathComponent(name).path)
        }
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func id(_ library: Library, _ name: String) -> Int64 {
        library.images.first { $0.fileName == name }!.id!
    }

    func testOpeningClearsTheWholeSelection() async throws {
        let library = Library()
        try await library.open(folder: folder)
        library.setSelection(Set(library.images.compactMap(\.id)), primary: id(library, "B.NEF"))
        XCTAssertEqual(library.selectedImageIDs.count, 3)

        try await library.open(folder: folder)
        XCTAssertNil(library.selectedImageID)
        XCTAssertEqual(library.selectedImageIDs, [], "no ids left over from the previous catalog")
    }

    /// Selected images a filter hides leave the selection, so rating keys
    /// in the grid never change what it doesn't show. Loupe and Develop
    /// still change the image on screen.
    func testFilteredOutImagesAreNotChangedByGridKeys() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let (a, b, c) = (id(library, "A.NEF"), id(library, "B.NEF"), id(library, "C.NEF"))
        func record(_ name: String) -> ImageRecord { library.images.first { $0.fileName == name }! }

        library.setSelection([a, b, c], primary: a)
        try await library.setRating(2)
        library.filter.minRating = 1
        library.setSelection([a, b], primary: b)
        try await library.setRating(0)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["C.NEF"])
        XCTAssertEqual(library.selectedImageIDs, [], "hidden images leave the selection")
        try await library.setRating(3)
        XCTAssertEqual([record("A.NEF").rating, record("B.NEF").rating], [0, 0], "nothing shown selected, nothing changed")
        XCTAssertEqual(record("C.NEF").rating, 2)

        // Narrowing the filter after selecting: only what stays shown changes,
        // even when the lead is among the hidden.
        library.filter = LibraryFilter()
        library.setSelection([a, b, c], primary: a)
        library.filter.minRating = 1
        XCTAssertEqual(library.selectedImageIDs, [c])
        XCTAssertEqual(library.selectedImageID, a, "the lead stays: in Develop it's the image on screen")
        try await library.setFlag(.picked)
        XCTAssertEqual(record("A.NEF").flag, ImageFlag.none.rawValue)
        XCTAssertEqual(record("B.NEF").flag, ImageFlag.none.rawValue)
        XCTAssertEqual(record("C.NEF").flag, ImageFlag.picked.rawValue)

        try await library.setFlag(.rejected, onlyPrimary: true)
        XCTAssertEqual(record("A.NEF").flag, ImageFlag.rejected.rawValue, "Develop's image, filtered out or not")
        XCTAssertEqual(record("C.NEF").flag, ImageFlag.picked.rawValue)
    }

    /// Rotate pressed twice before the first press has finished writing:
    /// both turns count.
    func testOverlappingRotationsBothCount() async throws {
        let library = Library()
        try await library.open(folder: folder)
        library.selectAllVisible()
        library.setSelection(Set(library.images.compactMap(\.id)), primary: id(library, "A.NEF"))
        let first = Task { try await library.rotateSelected(by: 1) }
        let second = Task { try await library.rotateSelected(by: 1) }
        try await first.value
        try await second.value

        let catalog = try XCTUnwrap(library.catalog)
        for name in ["A.NEF", "B.NEF", "C.NEF"] {
            let stored = try await catalog.image(forRelPath: name)
            XCTAssertEqual(stored?.userRotation, 2, name)
        }
        try await library.rotateSelected(by: -3)
        let turned = try await catalog.image(forRelPath: "B.NEF")
        XCTAssertEqual(turned?.userRotation, 3, "2 - 3 wraps to 3")
    }

    func testSelectionLeadRules() async throws {
        let library = Library()
        try await library.open(folder: folder)
        library.sort = LibrarySort(key: .fileName, ascending: true)
        let (a, b, c) = (id(library, "A.NEF"), id(library, "B.NEF"), id(library, "C.NEF"))

        library.setSelection([c, b], primary: nil)
        XCTAssertEqual(library.selectedImageID, b, "no lead given: the first in grid order, not a set's whim")
        library.setSelection([a, b, c], primary: c)
        XCTAssertEqual(library.selectedImageID, c)
        library.setSelection([a, c], primary: nil)
        XCTAssertEqual(library.selectedImageID, c, "the lead stays while it's selected")
        library.setSelection([a], primary: c)
        XCTAssertEqual(library.selectedImageID, a, "a lead outside the selection isn't taken")

        library.setSelection([b], primary: b)
        library.selectAllVisible()
        XCTAssertEqual(library.selectedImageIDs, [a, b, c])
        XCTAssertEqual(library.selectedImageID, b, "select all keeps the lead")
    }

    /// A rating under the default sort patches the record in place; the
    /// visible list only rebuilds when the filter or sort depends on it.
    func testRatingRebuildsTheListOnlyWhenTheViewDependsOnIt() async throws {
        let library = Library()
        try await library.open(folder: folder)
        library.sort = LibrarySort(key: .fileName, ascending: true)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        let version = library.visibleListVersion

        library.setSelection([a], primary: a)
        try await library.setRating(4)
        XCTAssertEqual(library.visibleListVersion, version, "same images in the same order")
        XCTAssertEqual(library.visibleImages.first { $0.id == a }?.rating, 4, "but the record is fresh")
        XCTAssertEqual(library.images.first { $0.id == a }?.rating, 4)

        // Under a rating sort, rating B above A reorders.
        library.sort = LibrarySort(key: .rating, ascending: false)
        let sorted = library.visibleListVersion
        library.setSelection([b], primary: b)
        try await library.setRating(5)
        XCTAssertGreaterThan(library.visibleListVersion, sorted)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF", "A.NEF", "C.NEF"])

        // A flag under a rating filter changes nothing about who passes.
        library.filter.minRating = 4
        let filtered = library.visibleListVersion
        try await library.setFlag(.picked)
        XCTAssertEqual(library.visibleListVersion, filtered)
        XCTAssertEqual(library.visibleImages.first { $0.id == b }?.flag, 1)
        // Unrating B under that filter hides it.
        try await library.setRating(0)
        XCTAssertGreaterThan(library.visibleListVersion, filtered)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"])
    }

    func testRevealInFinderTargets() async throws {
        let library = Library()
        XCTAssertEqual(library.revealInFinderURLs, [])
        try await library.open(folder: folder)
        XCTAssertEqual(library.revealInFinderURLs.map(\.lastPathComponent), [folder.lastPathComponent],
                       "nothing selected: the folder")
        library.setSelection([id(library, "C.NEF"), id(library, "A.NEF")], primary: nil)
        XCTAssertEqual(Set(library.revealInFinderURLs.map(\.lastPathComponent)), ["A.NEF", "C.NEF"])
    }

    /// The grid's thumbnails come turned by the image's own rotation, and the
    /// camera-oriented API other views use is unchanged.
    func testDisplayThumbnailsFollowRotation() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let deadline = Date().addingTimeInterval(20)
        while library.thumbnailsDone < 3 || library.thumbnailsTotal != 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let a = id(library, "A.NEF")
        library.setSelection([a], primary: a)
        try await library.rotateSelected(by: 1)
        let record = try XCTUnwrap(library.selectedImage)

        let boxed: ThumbnailImage? = await withCheckedContinuation { continuation in
            let request = library.requestDisplayThumbnail(for: record, pixelSize: 512) { image in
                continuation.resume(returning: image.map(ThumbnailImage.init))
            }
            XCTAssertNotNil(request)
        }
        let turned = try XCTUnwrap(boxed?.cgImage)
        XCTAssertGreaterThan(turned.height, turned.width, "the landscape sample, turned a quarter")
        XCTAssertTrue(library.displayThumbnail(for: record, pixelSize: 512) === turned)
        XCTAssertNil(library.cachedThumbnail(for: record), "camera-oriented isn't cached yet")
        let upright = await library.loadThumbnail(for: record)
        XCTAssertEqual(upright?.width, 512)
    }

    /// Saving an edit regenerates the thumbnail; the old pixels leave the
    /// memory cache, so the grid's next request shows the edit.
    func testRegeneratedThumbnailReplacesTheCachedOne() async throws {
        let library = Library()
        library.thumbnailRenderer = SolidRenderer()
        try await library.open(folder: folder)
        let deadline = Date().addingTimeInterval(20)
        while library.thumbnailsDone < 3 || library.thumbnailsTotal != 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let a = id(library, "A.NEF")
        let record = try XCTUnwrap(library.images.first { $0.id == a })
        let before = await library.loadThumbnail(for: record)
        XCTAssertEqual(before?.width, 512)

        let version = library.thumbnailVersion
        try await library.saveEditStack(#"{"schema":1,"modules":{"exposure":{"ev":1}}}"#, schemaVersion: 1,
                                        processVersion: "test", forImageID: a)
        while library.thumbnailVersion == version || library.cachedThumbnail(for: record) != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(library.cachedThumbnail(for: record), "the old thumbnail was dropped")
        let after = await library.loadThumbnail(for: record)
        XCTAssertEqual(after?.width, 64, "the renderer's thumbnail, not the cached embedded one")
    }

    /// What the loader's worker costs per thumbnail on this machine: a 512 px
    /// HEIC decoded and drawn display-ready. Printed, not asserted.
    func testMeasureDisplayReadyDecode() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let catalog = try XCTUnwrap(library.catalog)
        _ = try await catalog.generateMissingThumbnails()
        let url = await catalog.thumbnailURL(forRelPath: "A.NEF")
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let rounds = 40
        let start = Date()
        for _ in 0..<rounds {
            let decoded = try XCTUnwrap(ThumbnailLoader.decodeFile(url, 512))
            _ = ThumbnailLoader.displayReady(decoded, quarterTurns: 0, in: space)
        }
        let perThumbnail = Date().timeIntervalSince(start) / Double(rounds) * 1000
        print(String(format: "thumbnail decode + display-ready draw: %.2f ms each", perThumbnail))
    }
}
