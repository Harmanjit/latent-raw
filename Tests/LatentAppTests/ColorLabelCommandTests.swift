import XCTest
@testable import Catalog
@testable import latent_app

/// The colour label keys, menu and VoiceOver wording.
@MainActor
final class ColorLabelCommandTests: XCTestCase {
    func testKeysSixToNineSetLightroomsLabels() {
        let expected: [Character: ColorLabel] = ["6": .red, "7": .yellow, "8": .green, "9": .blue]
        for (key, label) in expected {
            let press = BareKeyPress(.character(key))
            XCTAssertEqual(KeyCommand.command(for: press), .label(label), "\(key)")
        }
        XCTAssertNil(Shortcuts.shortcut(for: .label(.purple)), "purple has no key, as in Lightroom")
        XCTAssertEqual(Shortcuts.menuTitle("Red", for: .label(.red)), "Red (6)")
        XCTAssertEqual(ColorLabel.red.keyHint, "6")
    }

    func testLabelNeedsASelection() {
        var state = CommandState()
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(.label(.red)))
        state.hasSelection = true
        XCTAssertTrue(state.isEnabled(.label(.red)))
        XCTAssertTrue(state.isEnabled(.label(nil)))
    }

    func testSpokenLabel() {
        XCTAssertEqual(SpokenText.label("Red"), "red label")
        XCTAssertEqual(SpokenText.label("Approved"), "label Approved")
        XCTAssertEqual(SpokenText.label(nil), "")
        XCTAssertEqual(SpokenText.label(""), "")
    }

    func testRecordCarriesItsDescriptionIntoExports() {
        var record = ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        XCTAssertTrue(record.exportDescription.isEmpty)
        record.title = "T"
        record.copyright = "© A"
        XCTAssertEqual(record.exportDescription.title, "T")
        XCTAssertEqual(record.exportDescription.copyright, "© A")
        XCTAssertNil(record.exportDescription.caption)
    }
}
