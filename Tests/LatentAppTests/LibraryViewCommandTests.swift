import XCTest
import Catalog
@testable import latent_app

/// Photo › Flip for a selection, View › Sort and Mirror Image Mode
/// (LibraryViewCommands.swift).
@MainActor
final class LibraryViewCommandTests: XCTestCase {
    func testFlipNeedsWhatEachViewActsOn() {
        var state = CommandState()
        let flip = KeyCommand.libraryView(.flip(horizontal: true))
        XCTAssertFalse(state.isEnabled(flip), "nothing selected")
        state.selectionCount = 3
        XCTAssertTrue(state.isEnabled(flip), "the grid flips its selection")
        state.mode = .loupe
        XCTAssertFalse(state.isEnabled(flip), "Loupe flips the image shown")
        state.hasSelection = true
        XCTAssertTrue(state.isEnabled(flip))
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(flip), "Develop flips the open image")
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(flip))
    }

    func testViewCommandsAreAlwaysAvailable() {
        let state = CommandState()
        for command in [LibraryViewCommand.toggleMirrorImageMode, .reverseSortOrder, .sort(.pick)] {
            XCTAssertTrue(state.isEnabled(.libraryView(command)), "\(command)")
        }
    }

    func testFlipMessageNamesSkippedImages() {
        XCTAssertEqual(LibraryFlip.message(changed: 2, skipped: [], horizontal: true), "Flipped 2 images horizontally")
        XCTAssertEqual(LibraryFlip.message(changed: 1, skipped: ["OLD.NEF"], horizontal: false),
                       "Flipped 1 image vertically · skipped 1 (open in Develop to flip): OLD.NEF")
    }

    func testMirrorTransformKeepsTheLayerInPlace() {
        let layer = CALayer()
        layer.setFrame(CGRect(x: 10, y: 20, width: 100, height: 50), mirrored: true)
        XCTAssertEqual(layer.frame.origin.x, 10, accuracy: 1e-9)
        XCTAssertEqual(layer.frame.width, 100, accuracy: 1e-9)
        XCTAssertEqual(layer.affineTransform().a, -1)
        layer.anchorPoint = .zero
        layer.setMirrored(true)
        XCTAssertEqual(layer.affineTransform().tx, 100, accuracy: 1e-9, "about the centre with a corner anchor")
        layer.setMirrored(false)
        XCTAssertTrue(layer.affineTransform().isIdentity)
    }
}
