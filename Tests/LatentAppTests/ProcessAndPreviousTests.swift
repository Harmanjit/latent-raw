import XCTest
import PixelEngine
@testable import latent_app

/// The Update Process Version prompt's rule, Previous's memory of the
/// photo before, and their keys.
@MainActor
final class ProcessAndPreviousTests: XCTestCase {
    private let v2 = ProcessVersion(id: "2.0", number: 2, changes: [])

    private func params(_ version: String, exposure: Float = 0) -> EditParameters {
        var p = EditParameters(); p.processVersion = version; p.exposureEV = exposure
        return p
    }

    func testPromptAsksOnAnEditOfAnOlderPhotoOnce() {
        let old = params("1.0"), new = params("1.0", exposure: 0.3)
        XCTAssertTrue(ProcessUpdatePrompt.shouldAsk(old: old, new: new, alreadyAsked: false, dontShow: false, current: v2))
        XCTAssertFalse(ProcessUpdatePrompt.shouldAsk(old: old, new: new, alreadyAsked: true, dontShow: false, current: v2))
        XCTAssertFalse(ProcessUpdatePrompt.shouldAsk(old: old, new: new, alreadyAsked: false, dontShow: true, current: v2))
        // Already current, or the version itself changing (menu, preview).
        XCTAssertFalse(ProcessUpdatePrompt.shouldAsk(old: params("2.0"), new: params("2.0", exposure: 1),
                                                     alreadyAsked: false, dontShow: false, current: v2))
        XCTAssertFalse(ProcessUpdatePrompt.shouldAsk(old: old, new: params("2.0"), alreadyAsked: false, dontShow: false, current: v2))
        // Today there is one version, so nothing is ever outdated.
        XCTAssertFalse(ProcessUpdatePrompt.shouldAsk(old: old, new: new, alreadyAsked: false, dontShow: false))
    }

    func testPreviousRemembersThePhotoBeforeInThisFolder() {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        var previous = PreviousPhoto()
        previous.selectionChanged(from: nil, to: 1, folder: a)
        XCTAssertNil(previous.id(in: a, current: 1))
        previous.selectionChanged(from: 1, to: 2, folder: a)
        XCTAssertEqual(previous.id(in: a, current: 2), 1)
        // Back to the first: the previous is now the second.
        previous.selectionChanged(from: 2, to: 1, folder: a)
        XCTAssertEqual(previous.id(in: a, current: 1), 2)
        // Deselecting keeps it; another folder forgets it.
        previous.selectionChanged(from: 1, to: nil, folder: a)
        XCTAssertEqual(previous.id(in: a, current: nil), 1)
        XCTAssertNil(previous.id(in: b, current: nil))
        previous.selectionChanged(from: nil, to: 7, folder: b)
        XCTAssertNil(previous.id(in: b, current: 7))
    }

    func testPreviousCarriesTheLookNotOneFramesRetouching() {
        XCTAssertTrue(EditGroup.previousGroups.isSuperset(of: EditGroup.lookGroups))
        XCTAssertTrue(EditGroup.previousGroups.isDisjoint(with: [.heal, .dust, .touchUp]))
    }

    func testPreviousHasLightroomsKeyAndNeedsAPhotoBefore() throws {
        XCTAssertEqual(try XCTUnwrap(Shortcuts.shortcut(for: .pasteFromPrevious)).glyphs, "⌥⌘V")
        var state = CommandState()
        state.hasImage = true
        XCTAssertFalse(state.isEnabled(.pasteFromPrevious))
        state.hasPreviousPhoto = true
        XCTAssertTrue(state.isEnabled(.pasteFromPrevious))
    }
}
