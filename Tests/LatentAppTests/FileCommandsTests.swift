import XCTest
import AppKit
import Catalog
@testable import latent_app

@MainActor
final class FileCommandsTests: XCTestCase {
    private func library(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 1
        change(&state)
        return state
    }

    func testFileCommandsNeedTheGridAndASelection() {
        XCTAssertTrue(library().isEnabled(.rename))
        XCTAssertTrue(library().isEnabled(.moveToFolder))
        XCTAssertTrue(library().isEnabled(.copyToFolder))
        XCTAssertFalse(library { $0.selectionCount = 3 }.isEnabled(.rename), "one image at a time")
        XCTAssertTrue(library { $0.selectionCount = 3 }.isEnabled(.moveToFolder))
        XCTAssertFalse(library { $0.mode = .develop }.isEnabled(.rename), "the editor has the file open")
        XCTAssertFalse(library { $0.mode = .loupe }.isEnabled(.moveToFolder))
        XCTAssertFalse(library { $0.hasSelection = false; $0.selectionCount = 0 }.isEnabled(.copyToFolder))
        XCTAssertFalse(library { $0.fileOperationRunning = true }.isEnabled(.rename))
        XCTAssertFalse(library { $0.exportQueueRunning = true }.isEnabled(.moveToFolder), "an export is reading them")
    }

    func testBackAndForwardFollowTheHistory() {
        XCTAssertFalse(CommandState().isEnabled(.back))
        XCTAssertFalse(CommandState().isEnabled(.forward))
        XCTAssertTrue(library { $0.canGoBack = true; $0.mode = .develop }.isEnabled(.back))
        XCTAssertTrue(library { $0.canGoForward = true }.isEnabled(.forward))
    }

    func testKeys() throws {
        let f2 = BareKeyPress(charactersIgnoringModifiers: "\u{F705}", shift: false, command: false, option: false, control: false)
        XCTAssertEqual(f2?.key, .f2)
        XCTAssertEqual(f2.flatMap(KeyCommand.command(for:)), .rename)
        XCTAssertEqual(Shortcuts.menuTitle("Rename…", for: .rename), "Rename… (F2)")
        XCTAssertEqual(try XCTUnwrap(Shortcuts.shortcut(for: .back)).glyphs, "⌥⌘←")
        XCTAssertEqual(try XCTUnwrap(Shortcuts.shortcut(for: .forward)).glyphs, "⌥⌘→")
        XCTAssertNil(Shortcuts.shortcut(for: .moveToFolder), "menu items without keys")
        XCTAssertNil(Shortcuts.shortcut(for: .copyToFolder))
        // ⌥⌘← is not the bare ← that steps through images.
        let arrow = BareKeyPress(charactersIgnoringModifiers: "\u{F702}", shift: false, command: true, option: true, control: false)
        XCTAssertNil(arrow)
    }

    func testDropMovesUnlessOptionOrTheDragCantMove() {
        XCTAssertEqual(FolderDrop.mode(allowed: [.copy, .move], optionHeld: false), .move)
        XCTAssertEqual(FolderDrop.mode(allowed: [.copy, .move], optionHeld: true), .copy)
        XCTAssertEqual(FolderDrop.mode(allowed: .copy, optionHeld: false), .copy)
        XCTAssertEqual(FolderDrop.mode(allowed: .generic, optionHeld: false), .move)
        XCTAssertEqual(FolderDrop.mode(allowed: .every, optionHeld: false), .move)
        XCTAssertNil(FolderDrop.mode(allowed: .link, optionHeld: false))
        XCTAssertNil(FolderDrop.mode(allowed: [], optionHeld: true))
    }

    func testMovingIntoTheImagesOwnFolderIsNoDrop() {
        let folder = URL(fileURLWithPath: "/Photos/Trip", isDirectory: true)
        let here = [folder.appendingPathComponent("A.NEF"), folder.appendingPathComponent("B.NEF")]
        XCTAssertFalse(FolderDrop.changesAnything(here, folder: folder, mode: .move))
        XCTAssertTrue(FolderDrop.changesAnything(here, folder: folder, mode: .copy))
        XCTAssertTrue(FolderDrop.changesAnything(here + [URL(fileURLWithPath: "/Photos/C.NEF")], folder: folder, mode: .move))
    }

    func testSummaries() {
        var report = TransferReport()
        let folder = URL(fileURLWithPath: "/Photos/Picks", isDirectory: true)
        let a = URL(fileURLWithPath: "/Photos/A.NEF")
        report.completed = [CompletedTransfer(kind: .move, source: a, destination: folder.appendingPathComponent("A.NEF"),
                                              destinationIdentity: nil, preservedNameChanged: false,
                                              previousPreservedName: nil, newPreservedName: nil)]
        XCTAssertEqual(LibraryFileCommands.summary(report, mode: .move, folder: folder), "Moved 1 image to “Picks”")
        report.failures = [.init(url: URL(fileURLWithPath: "/Photos/B.NEF"), reason: "The disk is full.")]
        report.wasCancelled = true
        XCTAssertEqual(LibraryFileCommands.summary(report, mode: .copy, folder: folder),
                       "Copied 1 image to “Picks”, 1 failed, stopped before the rest")
        XCTAssertEqual(LibraryFileCommands.failureSummary(report, mode: .copy),
                       "Copying failed for 1 of 2: B.NEF (The disk is full.)")
    }

    func testRecentDestinationsKeepTheLastFive() throws {
        let suite = "latent.tests.recent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("latent-recent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folders = try (0..<7).map { i -> URL in
            let url = base.appendingPathComponent("F\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let recent = RecentDestinations(defaults: defaults, key: "recent")
        folders.forEach(recent.add)
        recent.add(folders[3])
        XCTAssertEqual(recent.folders.map(\.lastPathComponent), ["F3", "F6", "F5", "F4", "F2"])

        try FileManager.default.removeItem(at: folders[5])
        XCTAssertEqual(recent.availableFolders.map(\.lastPathComponent), ["F3", "F6", "F4", "F2"])

        let reloaded = RecentDestinations(defaults: defaults, key: "recent")
        XCTAssertEqual(reloaded.folders.first?.lastPathComponent, "F3")
    }
}
