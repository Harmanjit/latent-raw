import XCTest
@testable import Catalog

@MainActor
final class LibraryTests: XCTestCase {
    var folder: URL!

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
}
