import XCTest
@testable import Catalog

/// Export locations beyond one chosen folder: beside each original, in a
/// subfolder, and originals keeping their own extension.
final class ExportPlannerLocationTests: XCTestCase {
    private func record(_ relPath: String) -> ImageRecord {
        ImageRecord(id: 1, relPath: relPath, preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                    xxhash: Data(count: 8), captureTime: 1_789_321_260, camera: nil, lens: nil, lensId: nil,
                    iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                    orientation: nil, rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    private let root = URL(fileURLWithPath: "/catalog", isDirectory: true)

    private func options(_ configure: (inout ExportBatchPlanner.Options) -> Void) -> ExportBatchPlanner.Options {
        var o = ExportBatchPlanner.Options(template: "{name}", fileExtension: "jpg", catalogName: "Shoot",
                                           timeZone: TimeZone(identifier: "UTC")!)
        configure(&o)
        return o
    }

    func testSameFolderAsOriginalPutsEachFileBesideItsPhoto() {
        let records = [record("DSC_1.NEF"), record("Day 2/DSC_2.NEF"), record("Day 2/Sub/DSC_3.NEF")]
        let plan = ExportBatchPlanner.plan(records, into: root, options: options { $0.originalFolders = true },
                                           probe: .nothingOnDisk)
        XCTAssertEqual(plan.outputs.map { $0.relativePath(to: root) },
                       ["DSC_1.jpg", "Day 2/DSC_2.jpg", "Day 2/Sub/DSC_3.jpg"])
    }

    /// Two photos of one name in different folders only clash when they
    /// share a folder, so beside their originals neither is numbered.
    func testSameNameInDifferentFoldersIsNotNumbered() {
        let records = [record("A/DSC_1.NEF"), record("B/DSC_1.NEF")]
        let beside = ExportBatchPlanner.plan(records, into: root, options: options { $0.originalFolders = true },
                                             probe: .nothingOnDisk)
        XCTAssertEqual(beside.sharedNameCount, 0)
        let together = ExportBatchPlanner.plan(records, into: root, options: options { _ in }, probe: .nothingOnDisk)
        XCTAssertEqual(together.sharedNameCount, 1)
    }

    func testSubfolderIsCleanedAndCombinesWithDates() {
        XCTAssertEqual(ExportBatchPlanner.Options.cleanSubfolder("  ../web/2048: "), "-web-2048-")
        let plan = ExportBatchPlanner.plan([record("Day 2/DSC_2.NEF")], into: root, options: options {
            $0.originalFolders = true
            $0.subfolder = "Web"
            $0.dateSubfolders = true
        }, probe: .nothingOnDisk)
        XCTAssertEqual(plan.outputs.first?.relativePath(to: root), "Day 2/Web/2026-09-13/DSC_2.jpg")
        XCTAssertTrue(options { $0.subfolder = "Web" }.makesFolders)
        XCTAssertFalse(options { $0.subfolder = "  " }.makesFolders)
    }

    func testOriginalsKeepTheirOwnExtension() {
        let plan = ExportBatchPlanner.plan([record("DSC_1.NEF"), record("IMG_2.cr3")], into: root,
                                           options: options { $0.keepsOriginalExtension = true }, probe: .nothingOnDisk)
        XCTAssertEqual(plan.outputs.map { $0.url.lastPathComponent }, ["DSC_1.NEF", "IMG_2.cr3"])
    }
}
