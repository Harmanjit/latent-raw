import XCTest
@testable import latent_app

/// The menu bar's enabling, its File menu's print items and the Photo
/// Merge log lines, checked where a menu walk can't reach.
@MainActor
final class AppMenusTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/latent-app", isDirectory: true)

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// ⌃H typed in the export sheet's watermark field is delete-backward,
    /// not HDR Merge: the main window isn't the one editing text, so its
    /// state alone doesn't know.
    func testTypingInAnotherWindowDisablesPhotoMerge() {
        var state = CommandState()
        state.editorReady = true
        state.hasSelection = true
        state.selectionCount = 2
        XCTAssertTrue(LatentCommands.isEnabled(.photoMergeHDR, context: state, keyWindowEditingText: false))
        for command: KeyCommand in [.photoMergeHDR, .photoMergeHDRWithoutDialog, .photoMergePanorama] {
            XCTAssertFalse(LatentCommands.isEnabled(command, context: state, keyWindowEditingText: true),
                           "\(command) while the key window edits text")
        }
        XCTAssertFalse(LatentCommands.isEnabled(.openFolder, context: nil, keyWindowEditingText: false),
                       "without the main window nothing is enabled")
    }

    /// SwiftUI's own Print… and Page Setup… are replaced, so the File menu
    /// has one ⌘P item, Latent's, and ⌘P never reaches the system's print
    /// while Latent's is disabled.
    func testTheFileMenuHasOnePrintItem() throws {
        let text = try source("AppMenus.swift")
        XCTAssertTrue(text.contains("CommandGroup(replacing: .printItem)"), "the default print group must be replaced")
        XCTAssertEqual(text.components(separatedBy: ", .print)").count - 1, 1, "one Print… item")
        XCTAssertEqual(Shortcuts.all.filter { $0.key == .character("p") && $0.modifiers == .command }.count, 1, "one ⌘P")
    }

    /// The log's privacy rule (no file names or paths in public text): an
    /// NSError's description carries the full path.
    func testPhotoMergeLogsKeepNamesAndErrorsPrivate() throws {
        let text = try source("PhotoMergeJob.swift")
        for leak in ["lastPathComponent, privacy: .public", "error), privacy: .public", "error, privacy: .public"] {
            XCTAssertFalse(text.contains(leak), "PhotoMergeJob.swift logs \(leak)")
        }
    }
}
