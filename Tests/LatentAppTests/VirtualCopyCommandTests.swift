import XCTest
@testable import Catalog
@testable import latent_app

/// The virtual-copy commands in the menus and on ⌘', and the output paths
/// (export, print) that must read a copy's master file with its own edit.
@MainActor
final class VirtualCopyCommandTests: XCTestCase {
    private func library(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 1
        state.editorReady = true
        change(&state)
        return state
    }

    private func record(_ relPath: String) -> ImageRecord {
        ImageRecord(id: 9, relPath: relPath, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: 6000, height: 4000, orientation: nil, rating: 2, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil, userRotation: 1)
    }

    func testCommandKeyApostropheCreatesAVirtualCopy() {
        let shortcut = Shortcuts.shortcut(for: .createVirtualCopy)
        XCTAssertEqual(shortcut?.glyphs, "⌘'")
        XCTAssertFalse(shortcut?.isBare ?? true, "a menu key equivalent, never a bare key")
    }

    func testWhenTheCommandsAreAvailable() {
        XCTAssertTrue(library().isEnabled(.createVirtualCopy))
        XCTAssertFalse(library { $0.hasSelection = false; $0.selectionCount = 0 }.isEnabled(.createVirtualCopy))
        XCTAssertFalse(library { $0.fileOperationRunning = true }.isEnabled(.createVirtualCopy))
        XCTAssertTrue(library { $0.mode = .develop; $0.hasImage = true }.isEnabled(.createVirtualCopy))
        XCTAssertFalse(library { $0.mode = .survey }.isEnabled(.createVirtualCopy))

        XCTAssertFalse(library().isEnabled(.setCopyAsMaster), "only on a copy")
        XCTAssertTrue(library { $0.primaryIsVirtualCopy = true }.isEnabled(.setCopyAsMaster))
        XCTAssertFalse(library { $0.primaryIsVirtualCopy = true; $0.exportQueueRunning = true }.isEnabled(.setCopyAsMaster))

        XCTAssertFalse(library().isEnabled(.removeVirtualCopy))
        XCTAssertTrue(library { $0.selectionHasVirtualCopy = true }.isEnabled(.removeVirtualCopy))
        XCTAssertTrue(library { $0.mode = .develop; $0.primaryIsVirtualCopy = true }.isEnabled(.removeVirtualCopy))

        XCTAssertTrue(library().isEnabled(.rename))
        XCTAssertFalse(library { $0.primaryIsVirtualCopy = true }.isEnabled(.rename), "a copy has no file to rename")

        XCTAssertTrue(library().isEnabled(.duplicatePhoto))
        XCTAssertFalse(library { $0.mode = .develop }.isEnabled(.duplicatePhoto), "files change under the grid only")
        XCTAssertFalse(library { $0.outputJobRunning = true }.isEnabled(.duplicatePhoto))
    }

    /// An export of a copy reads the master's raw file with the copy's own
    /// rotation and rating, and is named after the copy.
    func testAnExportOfACopyReadsItsMastersFile() {
        let copy = record(VirtualCopy.relPath(master: "A/DSC_1.NEF", key: VirtualCopy.Key(number: 2, token: "0badf00d")))
        let request = ExportPreset().workerRequest(for: copy, root: URL(fileURLWithPath: "/cat"),
                                                   destination: URL(fileURLWithPath: "/out/x.jpg"),
                                                   editStackJSON: "{}", keywords: [])
        XCTAssertEqual(request.sourceURL.path, "/cat/A/DSC_1.NEF")
        XCTAssertEqual(request.userRotation, 1)
        XCTAssertEqual(copy.fileName, "DSC_1 (Copy 2).NEF")
        let stem = ExportNaming.fileName(template: "{name}", record: copy, context: .init(index: 0))
        XCTAssertEqual(stem, "DSC_1 (Copy 2)", "an export of the copy doesn't take its master's name")

        let item = SheetItem(record: copy, folder: URL(fileURLWithPath: "/cat"), editStackJSON: "{}")
        XCTAssertEqual(item.sourceURL.path, "/cat/A/DSC_1.NEF", "print and contact sheets read the master's file")
        XCTAssertEqual(item.name, "DSC_1 (Copy 2).NEF")
    }
}
