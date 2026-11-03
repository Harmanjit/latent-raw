import XCTest
@testable import Catalog

/// Photo › Reset to Camera Orientation: every selected image loses the
/// turns the user gave it, and one Undo gives each its own turns back.
@MainActor
final class ResetOrientationTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        let sample = try TestAssets.d750Path()
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-orient-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["A.NEF", "B.NEF", "C.NEF"] {
            try fm.copyItem(atPath: sample, toPath: folder.appendingPathComponent(name).path)
        }
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func rotation(_ library: Library, _ name: String) -> Int {
        library.images.first { $0.fileName == name }!.userRotation
    }

    private func id(_ library: Library, _ name: String) -> Int64 {
        library.images.first { $0.fileName == name }!.id!
    }

    func testResetTakesEveryTurnAwayAndOneUndoGivesThemBack() async throws {
        let manager = UndoManager()
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        let (a, b, c) = (id(library, "A.NEF"), id(library, "B.NEF"), id(library, "C.NEF"))
        library.setSelection([a], primary: a)
        try await library.rotateSelected(by: 1)
        library.setSelection([b], primary: b)
        try await library.rotateSelected(by: 2)
        XCTAssertEqual([rotation(library, "A.NEF"), rotation(library, "B.NEF"), rotation(library, "C.NEF")], [1, 2, 0])

        library.setSelection([a, b, c], primary: a)
        try await library.resetRotationOfSelected()
        XCTAssertEqual(manager.groupingLevel, 0, "no group left open")
        XCTAssertEqual([rotation(library, "A.NEF"), rotation(library, "B.NEF"), rotation(library, "C.NEF")], [0, 0, 0])
        let sidecar = try XMPSidecar.read(from: await library.catalog!.sidecarURL(forRelPath: "B.NEF"))
        XCTAssertEqual(sidecar.rotation, 0, "the sidecar follows")
        XCTAssertEqual(manager.undoActionName, "Reset Orientation (2 Images)")

        manager.undo()
        await library.waitForPendingWork()
        XCTAssertEqual([rotation(library, "A.NEF"), rotation(library, "B.NEF"), rotation(library, "C.NEF")], [1, 2, 0],
                       "one undo, each image its own turns")
        manager.redo()
        await library.waitForPendingWork()
        XCTAssertEqual([rotation(library, "A.NEF"), rotation(library, "B.NEF")], [0, 0])
    }

    func testNothingToResetFilesNoUndo() async throws {
        let manager = UndoManager()
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        library.selectAllVisible()
        try await library.resetRotationOfSelected()
        XCTAssertFalse(manager.canUndo)
    }
}
