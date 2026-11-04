import XCTest
@testable import Catalog
@testable import latent_app

/// Photo › Verify Files… and Find Duplicates…: when they are offered, and
/// the verify run as a job quitting stops.
@MainActor
final class FileIntegrityCommandTests: XCTestCase {
    private func library(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.editorReady = true
        change(&state)
        return state
    }

    func testWhenTheCommandsAreAvailable() {
        XCTAssertTrue(library().isEnabled(.verifyFiles), "the whole folder when nothing is selected")
        XCTAssertFalse(library { $0.hasVisibleImages = false }.isEnabled(.verifyFiles))
        XCTAssertTrue(library { $0.hasVisibleImages = false; $0.hasSelection = true; $0.selectionCount = 1 }
            .isEnabled(.verifyFiles))
        XCTAssertFalse(library { $0.fileOperationRunning = true }.isEnabled(.verifyFiles))
        XCTAssertFalse(library { $0.outputJobRunning = true }.isEnabled(.verifyFiles), "one run at a time")
        XCTAssertFalse(library { $0.mode = .develop; $0.hasImage = true }.isEnabled(.verifyFiles))

        XCTAssertTrue(library().isEnabled(.findDuplicates))
        XCTAssertFalse(library { $0.hasVisibleImages = false }.isEnabled(.findDuplicates))
        XCTAssertFalse(library { $0.mode = .develop }.isEnabled(.findDuplicates))
    }

    func testVerifyingIsAJobQuittingStops() {
        let jobs = OutputJobs()
        var stopped = false
        let job = jobs.begin(.verifyFiles, name: "120 files") { stopped = true }
        let text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still verifying files")
        XCTAssertEqual(text.information, "Quitting now stops the verification, which keeps the files already checked.")
        XCTAssertEqual(text.button, "Stop and Quit")
        jobs.cancelAll()
        XCTAssertTrue(stopped)
        jobs.end(job)
    }

    func testDuplicatesSummary() {
        XCTAssertEqual(DuplicatesSheet.summary(exact: 1, near: 0), "1 group of identical files")
        XCTAssertEqual(DuplicatesSheet.summary(exact: 0, near: 2),
                       "0 groups of identical files · 2 groups taken at the same moment")
    }
}
