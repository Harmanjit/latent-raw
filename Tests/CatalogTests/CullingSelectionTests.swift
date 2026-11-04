import XCTest
@testable import Catalog

/// Edit's Select commands and Refine Photos on records alone.
final class CullingSelectionTests: XCTestCase {
    private func record(_ id: Int64, rating: Int = 0, flag: ImageFlag = .none, label: String? = nil) -> ImageRecord {
        ImageRecord(id: id, relPath: "DSC_\(id).NEF", size: 1, mtime: 0, xxhash: Data(count: 8),
                    rating: rating, label: label, flag: flag.rawValue)
    }

    private var visible: [ImageRecord] {
        [record(1, rating: 3, flag: .picked, label: "Red"),
         record(2, rating: 0, flag: .none),
         record(3, rating: 3, flag: .rejected, label: "blue"),
         record(4, rating: 5, flag: .none, label: "Client OK"),
         record(5, rating: 1, flag: .picked)]
    }

    func testSelectCommands() {
        let current: Set<Int64> = [1, 2]
        XCTAssertEqual(CullingSelection.none.selection(in: visible, current: current), [])
        XCTAssertEqual(CullingSelection.invert.selection(in: visible, current: current), [3, 4, 5])
        XCTAssertEqual(CullingSelection.flag(.picked).selection(in: visible, current: current), [1, 5])
        XCTAssertEqual(CullingSelection.flag(.none).selection(in: visible, current: current), [2, 4])
        XCTAssertEqual(CullingSelection.flag(.rejected).selection(in: visible, current: current), [3])
        XCTAssertEqual(CullingSelection.rating(3).selection(in: visible, current: current), [1, 3])
        XCTAssertEqual(CullingSelection.rating(0).selection(in: visible, current: current), [2])
        XCTAssertEqual(CullingSelection.label(.blue).selection(in: visible, current: current), [3], "any letter case")
        XCTAssertEqual(CullingSelection.label(nil).selection(in: visible, current: current), [2, 5],
                       "a custom label is not no label")
        XCTAssertEqual(CullingSelection.deselectUnflagged.selection(in: visible, current: [1, 2, 3, 4]), [1, 3])
    }

    /// A selected photo the filter now hides doesn't survive Invert or
    /// Deselect Unflagged: the grid never acts on what it hides.
    func testHiddenPhotosAreNeverSelected() {
        let shown = Array(visible.prefix(2))
        XCTAssertEqual(CullingSelection.invert.selection(in: shown, current: [1, 5]), [2])
        XCTAssertEqual(CullingSelection.deselectUnflagged.selection(in: shown, current: [1, 5]), [1])
    }

    func testRefinePlanFollowsLightroom() {
        let plan = RefinePlan(visible: visible)
        XCTAssertEqual(plan.changes, [1: ImageFlag.none, 2: .rejected, 4: .rejected, 5: ImageFlag.none])
        XCTAssertEqual(plan.rejectedCount, 2)
        XCTAssertEqual(plan.unflaggedCount, 2)
        XCTAssertTrue(RefinePlan(visible: [record(1, flag: .rejected)]).isEmpty)
    }
}

/// Refine Photos and the culling hooks on a real catalog.
@MainActor
final class CullingLibraryTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let sample = try TestAssets.d750Path()
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-culling-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["A.NEF", "B.NEF", "C.NEF"] {
            try fm.copyItem(atPath: sample, toPath: folder.appendingPathComponent(name).path)
        }
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func id(_ library: Library, _ name: String) -> Int64 {
        library.images.first { $0.fileName == name }!.id!
    }

    private func flags(_ library: Library) -> [Int] {
        ["A.NEF", "B.NEF", "C.NEF"].map { name in library.images.first { $0.fileName == name }!.flag }
    }

    func testRefineIsOneUndoableStep() async throws {
        let manager = UndoManager()
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        let (a, c) = (id(library, "A.NEF"), id(library, "C.NEF"))
        library.setSelection([a], primary: a)
        try await library.setFlag(.picked)
        library.setSelection([c], primary: c)
        try await library.setFlag(.rejected)
        XCTAssertEqual(flags(library), [1, 0, -1])

        let plan = try await library.refinePhotos()
        XCTAssertEqual(plan.rejectedCount, 1)
        XCTAssertEqual(flags(library), [0, -1, -1])
        XCTAssertEqual(manager.undoActionName, "Refine Photos (2 Images)")
        let sidecar = try XMPSidecar.read(from: await library.catalog!.sidecarURL(forRelPath: "B.NEF"))
        XCTAssertEqual(sidecar.flag, -1, "the sidecar follows")

        manager.undo()
        await library.waitForPendingWork()
        XCTAssertEqual(flags(library), [1, 0, -1])
        manager.redo()
        await library.waitForPendingWork()
        XCTAssertEqual(flags(library), [0, -1, -1])
    }

    /// Auto Advance reads the targets, then moves on before the write runs:
    /// the photo the key was pressed on gets the stars, not the next one.
    func testTargetsReadBeforeMovingOnKeepTheirPhoto() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let first = try XCTUnwrap(library.visibleImages.first?.id)
        library.setSelection([first], primary: first)
        let targets = library.cullingTargets(onlyPrimary: false)
        library.moveSelection(by: 1)
        try await library.setRating(4, targets: targets)
        XCTAssertEqual(library.images.first { $0.id == first }?.rating, 4)
        XCTAssertEqual(library.selectedImage?.rating, 0)
    }

    func testApplySelectionKeepsTheLeadWhenItStaysSelected() async throws {
        let library = Library()
        try await library.open(folder: folder)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        library.setSelection([a, b], primary: b)
        try await library.setFlag(.picked)
        library.selectAllVisible()
        library.applySelection(.deselectUnflagged)
        XCTAssertEqual(library.selectedImageIDs, [a, b])
        XCTAssertEqual(library.selectedImageID, b)
        library.applySelection(.invert)
        XCTAssertEqual(library.selectedImageIDs, [id(library, "C.NEF")])
        XCTAssertEqual(library.selectedImageID, id(library, "C.NEF"))
    }
}
