import XCTest
@testable import Catalog
@testable import latent_app

/// Metadata › Edit Capture Time… and Geotag from GPX Track…: when they are
/// offered, and that the Keyboard settings list them.
@MainActor
final class GeoTimeCommandTests: XCTestCase {
    private func library(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .library
        state.hasCatalog = true
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 2
        change(&state)
        return state
    }

    func testWhenTheCommandsAreAvailable() {
        for command in [MetadataCommand.editCaptureTime, .geotagFromGPX] {
            XCTAssertTrue(library().isEnabled(.metadata(command)))
            XCTAssertFalse(library { $0.hasSelection = false; $0.selectionCount = 0 }.isEnabled(.metadata(command)),
                           "they work on the selection")
            XCTAssertFalse(library { $0.hasCatalog = false }.isEnabled(.metadata(command)))
            XCTAssertFalse(library { $0.fileOperationRunning = true }.isEnabled(.metadata(command)))
            XCTAssertFalse(library { $0.mode = .survey }.isEnabled(.metadata(command)))
            XCTAssertNotNil(Keymap.info(for: .metadata(command)), "listed in Settings › Keyboard")
        }
    }
}
