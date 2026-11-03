import XCTest
@testable import Catalog

/// Keywording over a selection and keyword maintenance in a real catalog:
/// every change reaches the row and the sidecar, undo gives each photo its
/// own keywords back, and a database rebuilt from the sidecars keeps the
/// hierarchy.
@MainActor
final class HierarchicalKeywordTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-keywords-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["A.NEF", "B.NEF"].enumerated() {
            try TestAssets.copyD750(to: folder.appendingPathComponent(name), variant: index + 1)
        }
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func open(_ manager: UndoManager = UndoManager()) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        return library
    }

    private func id(_ library: Library, _ name: String) -> Int64 {
        library.images.first { $0.fileName == name }!.id!
    }

    private func sidecarKeywords(_ library: Library, _ name: String) async throws -> [String] {
        try XMPSidecar.read(from: await library.catalog!.sidecarURL(forRelPath: name)).keywords.sorted()
    }

    func testAddingToTheSelectionKeepsEachPhotosOwnKeywordsAndUndoes() async throws {
        let manager = UndoManager()
        let library = try await open(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        library.setSelection([a], primary: a)
        try await library.addKeywords(["sky"])
        library.setSelection([a, b], primary: a)
        try await library.addKeywords(KeywordPath.parse("Places > France > Paris, sky"))
        XCTAssertEqual(manager.undoActionName, "Add Keyword (2 Images)")

        let value1 = try await library.catalog!.keywords(forImageID: a)
        XCTAssertEqual(value1, ["Places|France|Paris", "sky"])
        let value2 = try await library.catalog!.keywords(forImageID: b)
        XCTAssertEqual(value2, ["Places|France|Paris", "sky"])
        let value3 = try await sidecarKeywords(library, "B.NEF")
        XCTAssertEqual(value3, ["Places|France|Paris", "sky"])
        let usage = library.selectionKeywords()
        XCTAssertEqual(usage.photos, 2)
        XCTAssertEqual(usage.counts, ["Places|France|Paris": 2, "sky": 2])

        manager.undo()
        await library.waitForPendingWork()
        let value4 = try await library.catalog!.keywords(forImageID: a)
        XCTAssertEqual(value4, ["sky"], "A keeps the keyword it had")
        let value5 = try await library.catalog!.keywords(forImageID: b)
        XCTAssertEqual(value5, [])
        XCTAssertEqual(library.selectionKeywords().counts, ["sky": 1])
        manager.redo()
        await library.waitForPendingWork()
        let value6 = try await library.catalog!.keywords(forImageID: b)
        XCTAssertEqual(value6, ["Places|France|Paris", "sky"])
    }

    func testRemovingTogglingAndTheKeywordFilter() async throws {
        let library = try await open()
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        library.setSelection([a, b], primary: a)
        try await library.addKeywords(["Places|France|Paris"])
        library.setSelection([b], primary: b)
        try await library.addKeywords(["Places|Spain"])

        library.filter.keyword = "Places"
        XCTAssertEqual(library.visibleImages.count, 2, "a keyword shows the photos tagged inside it")
        library.filter.keyword = "Places|Spain"
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
        library.filter = LibraryFilter()

        let tree = library.keywordTree
        XCTAssertEqual(tree.map(\.name), ["Places"])
        XCTAssertEqual(tree[0].count, 2)
        XCTAssertEqual(tree[0].children.map { "\($0.name) \($0.count)" }, ["France 2", "Spain 1"])

        // The checkbox: on some of the selection, so it goes on all.
        library.setSelection([a, b], primary: a)
        try await library.toggleKeyword("Places|Spain")
        XCTAssertEqual(library.selectionKeywords().counts["Places|Spain"], 2)
        try await library.toggleKeyword("Places|Spain")
        XCTAssertNil(library.selectionKeywords().counts["Places|Spain"])
        try await library.removeKeywords(["Places|France|Paris"])
        XCTAssertTrue(library.keywordTree.isEmpty)
    }

    func testRenameMovesAKeywordAndEverythingInsideItAcrossTheCatalog() async throws {
        let manager = UndoManager()
        let library = try await open(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        library.setSelection([a], primary: a)
        try await library.addKeywords(["Paris|Louvre", "sky"])
        library.setSelection([b], primary: b)
        try await library.addKeywords(["Paris"])
        library.setSelection([], primary: nil)

        try await library.renameKeyword("Paris", to: "Places > France > Paris")
        let value7 = try await library.catalog!.keywords(forImageID: a)
        XCTAssertEqual(value7, ["Places|France|Paris|Louvre", "sky"])
        let value8 = try await library.catalog!.keywords(forImageID: b)
        XCTAssertEqual(value8, ["Places|France|Paris"])
        XCTAssertEqual(manager.undoActionName, "Rename Keyword (2 Images)")

        try await library.deleteKeyword("Places|France")
        let value9 = try await library.catalog!.keywords(forImageID: a)
        XCTAssertEqual(value9, ["sky"])
        let value10 = try await library.catalog!.keywords(forImageID: b)
        XCTAssertEqual(value10, [])
        manager.undo()
        await library.waitForPendingWork()
        let value11 = try await library.catalog!.keywords(forImageID: a)
        XCTAssertEqual(value11, ["Places|France|Paris|Louvre", "sky"])
    }

    /// The database is a cache of the sidecars: rebuilt from them, the
    /// hierarchy is all there.
    func testHierarchySurvivesARebuiltDatabase() async throws {
        let library = try await open()
        let a = id(library, "A.NEF")
        library.setSelection([a], primary: a)
        try await library.addKeywords(["Animals|Dog", "beach"])
        await library.waitForPendingWork()

        let container = folder.appendingPathComponent(Catalog.containerName)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("catalog.sqlite" + suffix))
        }
        let rebuilt = try await open()
        let newA = id(rebuilt, "A.NEF")
        let value12 = try await rebuilt.catalog!.keywords(forImageID: newA)
        XCTAssertEqual(value12, ["Animals|Dog", "beach"])
        XCTAssertEqual(rebuilt.keywordTree.map(\.name), ["Animals", "beach"])
    }
}
