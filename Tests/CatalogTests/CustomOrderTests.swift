import XCTest
@testable import Catalog

/// The Custom sort: arranging, moving under filters and either direction,
/// renames, the file in _latent, and the Library's drag entry point.
@MainActor
final class CustomOrderTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-customorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func record(_ path: String, id: Int64 = 0) -> ImageRecord {
        ImageRecord(id: id, relPath: path, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    func testArrangementThenNewFilesByName() {
        let records = ["img10.NEF", "img2.NEF", "c.NEF", "b.NEF", "Day/a.NEF"].map { record($0) }
        let order = ["c.NEF", "gone.NEF", "img10.NEF", "c.NEF"]
        let positions = CustomOrder.positions(order)
        XCTAssertEqual(CustomOrder.arranged(records, positions: positions, ascending: true).map(\.relPath),
                       ["c.NEF", "img10.NEF", "Day/a.NEF", "b.NEF", "img2.NEF"],
                       "placed first; the rest by file name, img2 after b; a missing path is skipped")
        XCTAssertEqual(CustomOrder.arranged(records, positions: positions, ascending: false).map(\.relPath),
                       ["img2.NEF", "b.NEF", "Day/a.NEF", "img10.NEF", "c.NEF"], "descending is back to front")
        XCTAssertEqual(records.sorted(by: LibrarySort(key: .custom, ascending: true), customPositions: positions)
                        .map(\.relPath).first, "c.NEF")
        XCTAssertEqual(records.sorted(by: LibrarySort(key: .custom, ascending: true)).map(\.relPath),
                       ["Day/a.NEF", "b.NEF", "c.NEF", "img2.NEF", "img10.NEF"], "no order yet: name order")
    }

    func testReordered() {
        let paths = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(CustomOrder.reordered(paths, moving: ["d", "b"], before: "a"), ["b", "d", "a", "c", "e"],
                       "moved images keep their relative order")
        XCTAssertEqual(CustomOrder.reordered(paths, moving: ["b"], before: nil), ["a", "c", "d", "e", "b"])
        XCTAssertEqual(CustomOrder.reordered(paths, moving: ["b", "c"], before: "c"), paths,
                       "dropped on its own gap: nothing moves")
        XCTAssertEqual(CustomOrder.reordered(paths, moving: ["a"], before: "missing"), ["b", "c", "d", "e", "a"])
    }

    /// Images a filter hides keep their places relative to the rest, and a
    /// descending grid moves images where the user sees them go.
    func testMoveUnderFilterAndDescending() {
        let all = ["a", "b", "c", "d", "e"].map { record($0) }
        // Shown: a, c, e (b and d hidden). Drag e before c.
        XCTAssertEqual(CustomOrder.afterMove(all: all, order: [], ascending: true, moving: ["e"], before: "c"),
                       ["a", "b", "e", "c", "d"])
        // Descending shows e d c b a. Drag a before d: on screen e a d c b.
        let moved = CustomOrder.afterMove(all: all, order: [], ascending: false, moving: ["a"], before: "d")
        XCTAssertEqual(moved, ["b", "c", "d", "a", "e"])
        XCTAssertEqual(CustomOrder.arranged(all, positions: CustomOrder.positions(moved), ascending: false)
                        .map(\.relPath), ["e", "a", "d", "c", "b"])
        // Descending, dropped after the last image shown: the front of the arrangement.
        XCTAssertEqual(CustomOrder.afterMove(all: all, order: [], ascending: false, moving: ["c"], before: nil),
                       ["c", "a", "b", "d", "e"])
    }

    func testRenamed() {
        XCTAssertEqual(CustomOrder.renamed(["a", "b", "c"], [("b", "z")]), ["a", "z", "c"])
        XCTAssertNil(CustomOrder.renamed(["a", "b"], [("x", "y")]), "unlisted file: nothing to write")
        XCTAssertNil(CustomOrder.renamed(["a", "b"], [("a", "a")]))
        XCTAssertEqual(CustomOrder.renamed(["a", "b", "c"], [("a", "c")]), ["c", "b"],
                       "a file replaced by the renamed one gives up its place")
    }

    func testFileRoundTripAndBadFile() async throws {
        let catalog = try Catalog.open(at: folder)
        let empty = await catalog.customOrder()
        XCTAssertEqual(empty, [])
        try await catalog.setCustomOrder(["b.NEF", "Day 2/a.NEF"])
        let url = await catalog.customOrderURL
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "_latent")
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Day 2/a.NEF"),
                      "readable by a person: slashes unescaped")
        let read = await catalog.customOrder()
        XCTAssertEqual(read, ["b.NEF", "Day 2/a.NEF"])
        try await catalog.renameInCustomOrder([("b.NEF", "c.NEF")])
        let renamed = await catalog.customOrder()
        XCTAssertEqual(renamed, ["c.NEF", "Day 2/a.NEF"])

        try Data("not json".utf8).write(to: url)
        let unreadable = await catalog.customOrder()
        XCTAssertEqual(unreadable, [], "an unreadable file falls back to name order instead of failing the open")
        try await catalog.setCustomOrder([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func copyNEFs(_ names: [String]) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReconcileTests.sampleNEF),
                          "Drop a D750 NEF in TestAssets/")
        for name in names {
            try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                             toPath: folder.appendingPathComponent(name).path)
        }
    }

    /// Dragging in the grid: the order shows at once, is written to
    /// _latent, undoes and redoes, and survives the database being rebuilt.
    func testLibraryMoveUndoAndRebuild() async throws {
        try copyNEFs(["A.NEF", "B.NEF", "C.NEF", "D.NEF"])
        let library = Library()
        let undo = UndoManager()
        undo.groupsByEvent = false
        library.undoManager = undo
        try await library.open(folder: folder)
        library.moveInCustomOrder(["D.NEF"], before: "A.NEF")
        XCTAssertEqual(library.customOrder, [], "only under the Custom sort")

        library.chooseSortKey(.custom)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF", "B.NEF", "C.NEF", "D.NEF"])
        undo.beginUndoGrouping()
        library.moveInCustomOrder(["D.NEF", "C.NEF"], before: "A.NEF")
        undo.endUndoGrouping()
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["C.NEF", "D.NEF", "A.NEF", "B.NEF"])
        await library.waitForPendingWork()
        let catalog = try XCTUnwrap(library.catalog)
        let saved = await catalog.customOrder()
        XCTAssertEqual(saved, ["C.NEF", "D.NEF", "A.NEF", "B.NEF"])
        XCTAssertEqual(undo.undoActionName, "Rearrange")

        undo.undo()
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF", "B.NEF", "C.NEF", "D.NEF"])
        await library.waitForPendingWork()
        let undone = await catalog.customOrder()
        XCTAssertEqual(undone, [], "back to no arrangement at all")
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["C.NEF", "D.NEF", "A.NEF", "B.NEF"])
        await library.waitForPendingWork()

        // Renamed outside Latent: same content, new name, same place. (The
        // copies share their content, so one change per refresh.)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("A.NEF"),
                                         to: folder.appendingPathComponent("Z.NEF"))
        try await library.refresh()
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["C.NEF", "D.NEF", "Z.NEF", "B.NEF"])
        // A new file comes after the arrangement, even named to sort first.
        try FileManager.default.copyItem(atPath: ReconcileTests.sampleNEF,
                                         toPath: folder.appendingPathComponent("0.NEF").path)
        try await library.refresh()
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["C.NEF", "D.NEF", "Z.NEF", "B.NEF", "0.NEF"])

        // The database is thrown away: the order is in _latent, not in it.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("_latent/catalog.sqlite"))
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("_latent/catalog.sqlite" + suffix))
        }
        let rebuilt = Library()
        rebuilt.chooseSortKey(.custom)
        try await rebuilt.open(folder: folder)
        XCTAssertEqual(rebuilt.visibleImages.map(\.fileName), library.visibleImages.map(\.fileName))
    }
}
