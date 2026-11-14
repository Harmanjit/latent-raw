import XCTest
import GRDB
@testable import Catalog

/// The Versions panel's catalog side: blank copies, version names, and the
/// list of a photo's master and copies.
@MainActor
final class VersionsTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-versions-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private static let edit = #"{"exposure":0.5}"#

    private func openLibrary(_ manager: UndoManager = UndoManager()) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        return library
    }

    func testBlankCopyStartsFromTheDefaultEditButKeepsTheRest() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first { $0.fileName == "A.NEF" })
        try await catalog.setEditStack(Self.edit, forImageID: a.id!)
        try await catalog.setRating(4, forImageID: a.id!)
        try await library.refresh()
        let master = try XCTUnwrap(library.images.first { $0.id == a.id })

        let made = try await library.createVirtualCopies(of: [master], blank: true)
        let id = try XCTUnwrap(made.first)
        XCTAssertEqual(manager.undoActionName, "New Blank Copy")
        let edit = try await catalog.editStack(forImageID: id)
        XCTAssertNil(edit, "a blank copy has the default edit")
        let copy = try XCTUnwrap(library.images.first { $0.id == id })
        XCTAssertEqual(copy.rating, 4)
        XCTAssertEqual(library.versions(of: copy).map(\.id), [a.id, id], "master first, then its copies")
        XCTAssertEqual(library.versions(of: master).map(\.id), [a.id, id])

        // An ordinary copy still takes the edit.
        let second = try await library.createVirtualCopies(of: [master])
        let secondID = try XCTUnwrap(second.first)
        let value = try await catalog.editStack(forImageID: secondID)
        XCTAssertEqual(value, Self.edit)
        XCTAssertEqual(library.versions(of: master).compactMap(\.virtualCopyNumber), [1, 2])
    }

    func testVersionNamesAreKeptAndComeBackWithAnUndoneRemoval() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first)
        let made = try await library.createVirtualCopies(of: [a])
        let id = try XCTUnwrap(made.first)
        let copy = try XCTUnwrap(library.images.first { $0.id == id })

        try await library.setVersionName("  Moody B&W ", for: copy)
        var names = try await library.versionNames(for: [a, copy])
        XCTAssertEqual(names, [id: "Moody B&W"], "trimmed, and only rows with a name")

        try await library.removeVirtualCopies([copy])
        names = try await catalog.versionNames(forImageIDs: [id])
        XCTAssertEqual(names, [:], "the name goes with the row")
        manager.undo()
        await library.waitForPendingWork()
        names = try await catalog.versionNames(forImageIDs: [id])
        XCTAssertEqual(names, [id: "Moody B&W"], "and comes back with it")

        try await library.setVersionName("   ", for: copy)
        names = try await catalog.versionNames(forImageIDs: [id])
        XCTAssertEqual(names, [:], "a blank name takes it away")
    }
}
