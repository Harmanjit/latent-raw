import XCTest
import AppKit
@testable import Catalog
@testable import latent_app

/// Auto Advance's keys, the culling commands' menu rules and Refine
/// Photos' confirmation text, without a window.
@MainActor
final class CullingCommandTests: XCTestCase {
    private func press(_ characters: String, shift: Bool = false) -> BareKeyPress? {
        BareKeyPress(charactersIgnoringModifiers: characters, shift: shift, command: false, option: false, control: false)
    }

    private func resolve(_ characters: String, shift: Bool = false, unshifted: String? = nil,
                         capsLock: Bool = false) -> (first: KeyCommand, fallback: KeyCommand?)? {
        guard let press = press(characters, shift: shift) else { return nil }
        return CullingKeys.commands(for: press, unshifted: unshifted.flatMap { self.press($0) }, capsLock: capsLock)
    }

    func testPlainKeysAreUnchanged() {
        XCTAssertEqual(resolve("3")?.first, .rate(3))
        XCTAssertNil(resolve("3")?.fallback)
        XCTAssertEqual(resolve("p")?.first, .pick)
        XCTAssertEqual(resolve("g")?.first, .library)
        XCTAssertNil(resolve("q"))
    }

    /// Shift-1 types "!", so the key read without Shift finds the stars.
    func testShiftAdvancesOnce() {
        XCTAssertEqual(resolve("!", shift: true, unshifted: "1")?.first, .advance(.rate(1)))
        XCTAssertEqual(resolve("P", shift: true, unshifted: "p")?.first, .advance(.pick))
        XCTAssertEqual(resolve("U", shift: true, unshifted: "u")?.first, .advance(.unflag))
        XCTAssertEqual(resolve("(", shift: true, unshifted: "9")?.first, .advance(.label(.blue)))
        XCTAssertEqual(resolve(")", shift: true, unshifted: "0")?.first, .advance(.rate(0)))
    }

    /// Shift-X stays Compare's Make Select; elsewhere that declines and the
    /// reject-and-advance runs instead. Shift-O is still the crop guide's.
    func testShiftKeysTheTableOwnsComeFirst() {
        let x = resolve("X", shift: true, unshifted: "x")
        XCTAssertEqual(x?.first, .makeSelect)
        XCTAssertEqual(x?.fallback, .advance(.reject))
        XCTAssertEqual(resolve("O", shift: true, unshifted: "o")?.first, .geometry(.rotateCropGuide))
        XCTAssertNil(resolve("O", shift: true, unshifted: "o")?.fallback)
        XCTAssertNil(resolve("G", shift: true, unshifted: "g"), "only culling keys get a Shift form")
    }

    func testCapsLockAdvancesCullingKeysOnly() {
        XCTAssertEqual(resolve("4", capsLock: true)?.first, .advance(.rate(4)))
        XCTAssertEqual(resolve("x", capsLock: true)?.first, .advance(.reject))
        XCTAssertEqual(resolve("e", capsLock: true)?.first, .loupe)
    }

    func testAdvancingCommandsDoNotRepeatWhileHeld() {
        XCTAssertFalse(KeyCommand.advance(.rate(1)).repeatsWhileHeld)
    }

    func testMenuRules() {
        var state = CommandState()
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 1
        XCTAssertTrue(state.isEnabled(.advance(.pick)))
        XCTAssertFalse(state.isEnabled(.advance(.library)), "only a culling command advances")
        XCTAssertTrue(state.isEnabled(.select(.invert)))
        XCTAssertTrue(state.isEnabled(.refinePhotos))
        XCTAssertTrue(state.isEnabled(.toggleAutoAdvance))
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(.select(.invert)), "the Select commands are the grid's")
        XCTAssertFalse(state.isEnabled(.refinePhotos))
        XCTAssertTrue(state.isEnabled(.advance(.rate(2))))
        state.hasSelection = false
        XCTAssertFalse(state.isEnabled(.advance(.rate(2))))
    }

    func testAutoAdvanceIsKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "latent-culling-\(UUID().uuidString)"))
        let preferences = CullingPreferences(defaults: defaults)
        XCTAssertFalse(preferences.autoAdvance)
        preferences.autoAdvance = true
        XCTAssertTrue(CullingPreferences(defaults: defaults).autoAdvance)
    }

    func testRefineSummary() {
        func record(_ id: Int64, _ flag: ImageFlag) -> ImageRecord {
            ImageRecord(id: id, relPath: "\(id).NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: flag.rawValue)
        }
        XCTAssertEqual(CullingCommands.refineSummary(RefinePlan(visible: [record(1, .none), record(2, .none), record(3, .picked)])),
                       "2 unflagged photos will be rejected, and 1 picked photo will be unflagged.")
        XCTAssertEqual(CullingCommands.refineSummary(RefinePlan(visible: [record(1, .none)])),
                       "1 unflagged photo will be rejected.")
        XCTAssertEqual(CullingCommands.refineSummary(RefinePlan(visible: [record(1, .picked), record(2, .picked)])),
                       "2 picked photos will be unflagged.")
    }
}
