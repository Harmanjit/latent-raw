import XCTest
@testable import Catalog

/// Rename with a filename template: the names a template gives, the
/// problems found before anything moves, the order renames run in, and a
/// batch rename on real files with undo.
@MainActor
final class RenamePlanTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func record(_ relPath: String, captured: Int64? = 1_717_245_296, title: String? = nil) -> ImageRecord {
        var record = ImageRecord(relPath: relPath, size: 1, mtime: 0, xxhash: Data(count: 8),
                                 captureTime: captured, camera: "NIKON D750", rating: 3, flag: 0)
        record.title = title
        return record
    }

    private func plan(_ records: [ImageRecord], _ template: String, text: String = "Trip",
                      taken: Set<String> = []) -> RenamePlan {
        RenamePlan.make(records, template: template, customText: text, timeZone: utc) { taken.contains($0) }
    }

    func testTokensCustomTextAndTitle() throws {
        let r = record("Day 2/DSC_0107.NEF", title: "Harbour / dusk")
        let context = ExportNaming.Context(index: 4, start: 1, padding: 3)
        func name(_ template: String, _ text: String = "Oslo") throws -> String {
            try RenameTemplate.fileName(template: template, customText: text, record: r, context: context, timeZone: utc).get()
        }
        XCTAssertEqual(try name("{text}-{seq}"), "Oslo-005.NEF")
        XCTAssertEqual(try name("{TEXT}_{name}"), "Oslo_DSC_0107.NEF", "tokens in any letter case")
        XCTAssertEqual(try name("{date:yyyyMMdd}-{title}"), "20240601-Harbour _ dusk.NEF", "a slash can't go in a name")
        XCTAssertEqual(try name("{text}", ""), "DSC_0107.NEF", "an empty result keeps the old name")
        XCTAssertEqual(try name("{text}", "a/b:c"), "a_b_c.NEF")
        XCTAssertEqual(RenameTemplate.unknownTokens(in: "{text}{title}{nmae}"), ["{nmae}"])
    }

    func testSequenceFollowsTheGivenOrderAndUnchangedNamesAreSkipped() {
        let records = [record("C.NEF"), record("A.NEF"), record("Trip-003.NEF")]
        let p = plan(records, "{text}-{seq}")
        XCTAssertEqual(p.items.map(\.newName), ["Trip-001.NEF", "Trip-002.NEF", "Trip-003.NEF"])
        XCTAssertTrue(p.items[2].isUnchanged)
        XCTAssertEqual(p.renames.map(\.record.fileName), ["C.NEF", "A.NEF"])
        XCTAssertEqual(p.problemCount, 0)
    }

    func testTwoPhotosGivenOneNameAreBothRefused() {
        let p = plan([record("A.NEF"), record("B.NEF"), record("Day 2/C.NEF")], "{text}")
        XCTAssertNotNil(p.items[0].problem)
        XCTAssertNotNil(p.items[1].problem)
        XCTAssertNil(p.items[2].problem, "another folder: its own name to take")
        XCTAssertEqual(p.renames.map(\.record.relPath), ["Day 2/C.NEF"])
    }

    func testANameTakenOutsideTheBatchIsRefused() {
        let p = plan([record("A.NEF"), record("B.NEF")], "{text}-{seq}", taken: ["trip-001.nef", "Trip-001.NEF"])
        XCTAssertEqual(p.items[0].problem, "“Trip-001.NEF” is already taken")
        XCTAssertNil(p.items[1].problem)
    }

    /// 1→2 while 2→3: 2 moves first, so its name is free for 1.
    func testAChainRunsInAnOrderThatFreesEachName() {
        let records = [record("P-1.NEF"), record("P-2.NEF")]
        // {seq} starting at 2 shifts every name up by one.
        let p = RenamePlan.make(records, template: "P-{seq}", customText: "", start: 2, padding: 1,
                                timeZone: utc) { _ in false }
        XCTAssertEqual(p.items.map(\.newName), ["P-2.NEF", "P-3.NEF"])
        XCTAssertEqual(p.renames.map(\.record.fileName), ["P-2.NEF", "P-1.NEF"])
    }

    func testASwapCantBeOrderedAndIsRefused() {
        // Given in reverse order, the sequence swaps the two names.
        let p = RenamePlan.make([record("P-2.NEF"), record("P-1.NEF")], template: "P-{seq}", customText: "",
                                padding: 1, timeZone: utc) { _ in false }
        XCTAssertEqual(p.renameCount, 0)
        XCTAssertEqual(p.problemCount, 2)
    }

    // MARK: - On real files

    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-rename-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        try TestAssets.copyD750(to: folder.appendingPathComponent("C.NEF"), variant: 2)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func settle(_ library: Library) async {
        await library.waitForPendingWork()
        while library.fileOperations.isBusy || library.hasPendingWork {
            await library.waitForPendingWork()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testBatchRenameIsOneUndoStepAndKeepsEachPhotosMetadata() async throws {
        let library = Library()
        let undo = UndoManager()
        library.undoManager = undo
        try await library.open(folder: folder)
        let names = ["A.NEF", "B.NEF", "C.NEF"]
        let records = names.map { name in library.images.first { $0.fileName == name }! }
        try await library.catalog!.setRating(5, forImageID: records[1].id!)
        try await library.catalog!.exchangeDescriptive(.title, "Second", forImageID: records[1].id!)
        try await library.refresh()
        let fresh = names.map { name in library.images.first { $0.fileName == name }! }

        let plan = library.renamePlan(for: fresh, template: "{text}-{seq}", customText: "Oslo")
        XCTAssertEqual(plan.renameCount, 3)
        let report = await library.fileOperations.rename(plan)
        XCTAssertEqual(report.completed.count, 3, report.failureDescription)
        await settle(library)
        XCTAssertEqual(Set(library.images.map(\.fileName)), ["Oslo-001.NEF", "Oslo-002.NEF", "Oslo-003.NEF"])
        let second = try XCTUnwrap(library.images.first { $0.fileName == "Oslo-002.NEF" })
        XCTAssertEqual(second.id, fresh[1].id)
        XCTAssertEqual(second.rating, 5)
        XCTAssertEqual(second.title, "Second")
        XCTAssertEqual(second.preservedName, "B.NEF")
        XCTAssertEqual(undo.undoActionName, "Rename 3 Images")

        undo.undo()
        await settle(library)
        XCTAssertEqual(Set(library.images.map(\.fileName)), Set(names))
        XCTAssertEqual(library.images.first { $0.fileName == "B.NEF" }?.title, "Second")

        // Planned again with the old names taken back, nothing is in the way.
        let again = library.renamePlan(for: library.images, template: "{name}", customText: "")
        XCTAssertEqual(again.renameCount, 0)
        XCTAssertEqual(again.problemCount, 0)
    }
}
