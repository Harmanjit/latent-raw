import XCTest
import AppKit
import PixelEngine
@testable import latent_app

/// Arrow keys that pan a zoomed-in image, and the magnifier's renders.
@MainActor
final class ViewerInputTests: XCTestCase {
    private func press(_ characters: String) -> BareKeyPress? {
        BareKeyPress(charactersIgnoringModifiers: characters, shift: false, command: false,
                     option: false, control: false)
    }

    private func loupe(_ zoomed: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .loupe
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 1
        state.hasImage = true
        state.arrowKeysPanImage = true
        state.imageZoomedIn = true
        zoomed(&state)
        return state
    }

    // MARK: - Arrow keys

    func testUpAndDownArrowsAreReadAndPan() {
        XCTAssertEqual(press("\u{F700}")?.key, .upArrow)
        XCTAssertEqual(press("\u{F701}")?.key, .downArrow)
        XCTAssertEqual(press("\u{F700}").flatMap(KeyCommand.command(for:)), .panImage(.up))
        XCTAssertEqual(press("\u{F701}").flatMap(KeyCommand.command(for:)), .panImage(.down))
        XCTAssertEqual(Shortcuts.glyphs(.upArrow, []), "↑")
        XCTAssertTrue(press("\u{F701}")!.belongs(to: .slider), "a focused slider moves with ↓")
        XCTAssertTrue(press("\u{F700}")!.belongs(to: .list), "the sidebar keeps its arrows")
    }

    func testLeftAndRightPanOnlyWhenTheSettingAndTheZoomSaySo() {
        XCTAssertEqual(KeyCommand.step(1).panningImage(true), .panImage(.right))
        XCTAssertEqual(KeyCommand.step(-1).panningImage(true), .panImage(.left))
        XCTAssertEqual(KeyCommand.step(1).panningImage(false), .step(1))
        XCTAssertEqual(KeyCommand.pick.panningImage(true), .pick)

        XCTAssertTrue(loupe().arrowKeysPan)
        XCTAssertTrue(loupe { $0.mode = .develop }.arrowKeysPan)
        XCTAssertFalse(loupe { $0.arrowKeysPanImage = false }.arrowKeysPan, "off by default in Settings")
        XCTAssertFalse(loupe { $0.imageZoomedIn = false }.arrowKeysPan, "at fit the arrows step")
        XCTAssertFalse(loupe { $0.mode = .compare }.arrowKeysPan, "Compare keeps them for the candidate")
        XCTAssertFalse(loupe { $0.mode = .library }.arrowKeysPan)
        XCTAssertFalse(CommandState().arrowKeysPan)
    }

    /// ↑ and ↓ with nothing to pan carry on to the grid, which moves its
    /// selection with them.
    func testPanKeysPassThroughWhenTheyCannotPan() {
        XCTAssertTrue(loupe().isEnabled(.panImage(.up)))
        XCTAssertFalse(loupe { $0.mode = .library }.isEnabled(.panImage(.down)))
        XCTAssertTrue(CommandState.passesThroughWhenUnavailable(.panImage(.down)))
    }

    // MARK: - Model

    private static func asset(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets").appendingPathComponent(name)
    }

    private func openedModel() async throws -> EditorModel {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testArrowKeyPanMovesAZoomedInImage() async throws {
        let model = try await openedModel()
        model.panImage(.right)
        XCTAssertTrue(model.fitMode, "nothing to pan at fit")
        model.zoomToActualSize()
        let before = model.viewport.center
        model.panImage(.right)
        XCTAssertEqual(model.viewport.center.x, before.x + 150, accuracy: 1e-6, "an eighth of the view, rightwards")
        model.panImage(.up)
        XCTAssertEqual(model.viewport.center.y, before.y - 100, accuracy: 1e-6)
    }

    /// The loupe gets a full-resolution tile covering it; small moves reuse
    /// it, a far move renders again but no more often than the interval,
    /// before/after renders what is shown, and letting go frees it.
    func testMagnifierRendersCoversThrottlesAndEnds() async throws {
        let model = try await openedModel()
        XCTAssertTrue(model.fitMode)
        let zoom = ViewerInteraction.Magnifier.zoom(backingScale: 2, viewZoom: model.viewport.zoom)
        func loupe(_ x: CGFloat, _ y: CGFloat) -> ViewerInteraction.Magnifier {
            ViewerInteraction.Magnifier(center: CGPoint(x: x, y: y), radius: 220, zoom: zoom)
        }
        func covers(_ l: ViewerInteraction.Magnifier) -> Bool {
            guard let tile = model.magnifierTile else { return false }
            let needed = model.frame.sensorRect(fromCanvasRect: l.canvasRect(in: model.viewport,
                                                                              drawableSize: model.drawableSize))
            return tile.coverage.insetBy(dx: tile.inset, dy: tile.inset).contains(needed)
        }

        model.magnifierChanged(loupe(600, 400))
        let first = try XCTUnwrap(model.magnifierTile, "rendered at once")
        XCTAssertTrue(covers(loupe(600, 400)))
        XCTAssertLessThan(first.texture.width, 600, "a small tile, not the view")

        model.magnifierChanged(loupe(605, 402))
        XCTAssertEqual(model.magnifierTile?.generation, first.generation, "a small move needs no render")

        model.magnifierChanged(loupe(200, 150))
        XCTAssertEqual(model.magnifierTile?.generation, first.generation, "too soon: queued, not rendered")
        XCTAssertNotNil(model.magnifierState.pending)
        model.magnifierChanged(loupe(900, 650))   // moves on before the queued render runs
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNotEqual(model.magnifierTile?.generation, first.generation)
        XCTAssertTrue(covers(loupe(900, 650)), "the queued render used the latest position")
        XCTAssertEqual(model.magnifierTile?.texture.width, first.texture.width, "same size, same pooled textures")

        let moved = try XCTUnwrap(model.magnifierTile).generation
        try await Task.sleep(for: .milliseconds(50))
        model.parameters.exposureEV = 1
        let edited = try XCTUnwrap(model.magnifierTile).generation
        XCTAssertNotEqual(edited, moved, "an edit re-renders the loupe")
        try await Task.sleep(for: .milliseconds(50))
        model.showingBefore = true
        XCTAssertNotEqual(model.magnifierTile?.generation, edited, "before/after re-renders the loupe")

        model.magnifierChanged(nil)
        XCTAssertNil(model.magnifierTile)
        XCTAssertNil(model.magnifierState.loupe)
    }
}
