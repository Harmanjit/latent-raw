import XCTest
import UniformTypeIdentifiers
@testable import Catalog

/// Stacks: the editing rules, how they shape the grid's list, the catalog
/// tables, the Library's commands with undo, and exported files added to
/// the catalog and stacked with their originals.
@MainActor
final class StackTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-stacks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func record(_ id: Int64, time: Int64? = nil, path: String? = nil) -> ImageRecord {
        var record = ImageRecord(relPath: path ?? "IMG_\(id).JPG", size: 1, mtime: 0, xxhash: Data([UInt8(id & 255)]),
                                 rating: 0, flag: 0)
        record.id = id
        record.captureTime = time
        return record
    }

    // MARK: Rules

    func testGroupPutsTheLeadOnTopAndMergesStacks() {
        let first = StackEditing.group([1, 2, 3], top: 2, in: [])
        XCTAssertEqual(first, [ImageStack(id: 1, memberIDs: [2, 1, 3], isCollapsed: true)])
        // A photo of an existing stack brings the whole stack.
        let merged = StackEditing.group([4, 3], top: 4, in: first)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].memberIDs, [4, 2, 1, 3])
        XCTAssertEqual(merged[0].id, 2)
        // One photo alone is no stack.
        XCTAssertEqual(StackEditing.group([9], top: 9, in: first), first)
    }

    func testUnstackRemoveAndMoveToTop() {
        let stacks = [ImageStack(id: 1, memberIDs: [1, 2, 3], isCollapsed: true),
                      ImageStack(id: 2, memberIDs: [4, 5], isCollapsed: false)]
        XCTAssertEqual(StackEditing.unstack([2], in: stacks).map(\.id), [2])
        XCTAssertEqual(StackEditing.remove([2], from: stacks)[0].memberIDs, [1, 3])
        // Down to one photo: no longer a stack.
        XCTAssertEqual(StackEditing.remove([5], from: stacks).map(\.id), [1])
        XCTAssertEqual(StackEditing.moveToTop(3, in: stacks)[0].memberIDs, [3, 1, 2])
        let toggled = StackEditing.setCollapsed(nil, stackIDs: [1], in: stacks)
        XCTAssertEqual(toggled.map(\.isCollapsed), [false, false])
        XCTAssertEqual(StackEditing.setCollapsed(true, stackIDs: nil, in: stacks).map(\.isCollapsed), [true, true])
    }

    func testAddBesideTheOriginal() {
        let below = StackEditing.add(10, besides: 1, above: false, in: [])
        XCTAssertEqual(below, [ImageStack(id: 1, memberIDs: [1, 10], isCollapsed: false)])
        let stacks = [ImageStack(id: 4, memberIDs: [1, 2, 3], isCollapsed: true)]
        let above = StackEditing.add(10, besides: 2, above: true, in: stacks)
        XCTAssertEqual(above, [ImageStack(id: 4, memberIDs: [1, 10, 2, 3], isCollapsed: false)])
    }

    func testAutoStackByCaptureTime() {
        let records = [record(1, time: 100), record(2, time: 130), record(3, time: 200), record(4, time: 1000),
                       record(5, time: 1010), record(6), record(7, time: 1015), record(8, time: 105)]
        let result = StackEditing.autoStack(records, gap: 60, in: [])
        // 100, 105, 130 (and not 200, 70 s after 130); 1000, 1010, 1015.
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.stacks.map(\.memberIDs), [[1, 8, 2], [4, 5, 7]])
        XCTAssertTrue(result.stacks.allSatisfy(\.isCollapsed))
        // Photos already stacked stay where they are.
        let again = StackEditing.autoStack(records, gap: 60, in: [ImageStack(id: 9, memberIDs: [1, 8], isCollapsed: true)])
        XCTAssertEqual(again.stacks.map(\.memberIDs), [[1, 8], [4, 5, 7]])
        XCTAssertEqual(StackEditing.autoStack(records, gap: 0, in: []).added, 0)
    }

    // MARK: Layout

    func testCollapsedStacksShowOnePhotoAndFiltersFindMembers() {
        let sorted = (1...5).map { record(Int64($0)) }
        let collapsed = StackLayout.memberships([ImageStack(id: 1, memberIDs: [4, 2], isCollapsed: true)])
        // The stack sits where the first of its photos falls in the sort (2).
        XCTAssertEqual(StackLayout.arrange(sorted, memberships: collapsed).compactMap(\.id), [1, 4, 3, 5])
        let expanded = StackLayout.memberships([ImageStack(id: 1, memberIDs: [4, 2], isCollapsed: false)])
        // Together, in stack order, where the first of them falls.
        XCTAssertEqual(StackLayout.arrange(sorted, memberships: expanded).compactMap(\.id), [1, 4, 2, 3, 5])
        // A filter that hides the top shows the stack by a photo that passed.
        let filtered = sorted.filter { $0.id != 4 }
        XCTAssertEqual(StackLayout.arrange(filtered, memberships: collapsed).compactMap(\.id), [1, 2, 3, 5])
        XCTAssertEqual(collapsed[2], StackMembership(stackID: 1, position: 1, count: 2, isCollapsed: true))
    }

    // MARK: Catalog and Library

    private func writePictures(_ names: [String]) throws {
        for (seed, name) in names.enumerated() {
            try RenderedImageCatalogTests.writePicture(to: folder.appendingPathComponent(name), type: .jpeg, seed: seed)
        }
    }

    private func openLibrary() async throws -> Library {
        let library = Library()
        library.undoManager = UndoManager()
        _ = try await library.open(folder: folder)
        return library
    }

    private func ids(_ library: Library, _ names: [String]) -> [Int64] {
        names.compactMap { name in library.images.first { $0.fileName == name }?.id }
    }

    func testGroupCollapseUndoAndReopen() async throws {
        try writePictures(["A.jpg", "B.jpg", "C.jpg", "D.jpg"])
        let library = try await openLibrary()
        let abc = ids(library, ["A.jpg", "B.jpg", "C.jpg"])
        XCTAssertEqual(abc.count, 3)
        library.setSelection(Set(abc), primary: abc[1])
        try await library.groupIntoStack(library.selectedImages)
        XCTAssertEqual(library.stacks.count, 1)
        XCTAssertEqual(library.stacks[0].memberIDs.first, abc[1])
        XCTAssertEqual(library.visibleImages.count, 2, "collapsed: the top and D")
        XCTAssertEqual(library.selectedImageIDs, [abc[1]])

        try await library.setStacksCollapsed(nil, of: library.selectedImages)
        XCTAssertEqual(library.visibleImages.count, 4)
        XCTAssertFalse(library.stacks[0].isCollapsed)

        // Stacks outlive the session.
        let reopened = try await openLibrary()
        XCTAssertEqual(reopened.stacks, library.stacks)

        library.undoManager?.undo()
        await library.waitForPendingWork()
        XCTAssertTrue(library.stacks.isEmpty)
        library.undoManager?.redo()
        await library.waitForPendingWork()
        XCTAssertEqual(library.stacks.count, 1)

        try await library.unstack(library.images.filter { $0.id == abc[0] })
        XCTAssertTrue(library.stacks.isEmpty)
        XCTAssertEqual(library.visibleImages.count, 4)
    }

    func testExportedFilesAreAddedAndStackedBelowTheOriginal() async throws {
        try writePictures(["A.jpg", "B.jpg"])
        let library = try await openLibrary()
        let source = try XCTUnwrap(ids(library, ["A.jpg"]).first)
        let exported = folder.appendingPathComponent("A-edit.jpg")
        try RenderedImageCatalogTests.writePicture(to: exported, type: .jpeg, seed: 40)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("latent-outside-\(UUID().uuidString).jpg")
        try RenderedImageCatalogTests.writePicture(to: outside, type: .jpeg, seed: 41)
        defer { try? FileManager.default.removeItem(at: outside) }

        let report = try await library.addExportedFiles([
            Library.ExportedFile(url: exported, sourceID: source, placement: .below),
            Library.ExportedFile(url: outside, sourceID: source, placement: .below),
        ])
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.outside, 1)
        let added = try XCTUnwrap(ids(library, ["A-edit.jpg"]).first)
        XCTAssertEqual(library.stacks.map(\.memberIDs), [[source, added]])
        XCTAssertEqual(library.selectedImageIDs, [added])
    }
}
