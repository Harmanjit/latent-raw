import XCTest
import AppKit
import PixelEngine
@testable import latent_app

/// Escape (disarmTools) in the middle of a mask drag must not leave the
/// red overlay stuck on: the release that follows no longer reaches
/// maskToolEnded, because no tool is armed by then.
@MainActor
final class DisarmMaskDragTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testEscapeDuringABrushDragEndsTheDrag() async throws {
        let model = try await openModel()
        model.addLocal(.brush)
        XCTAssertEqual(model.maskTool, .brush)
        model.imageToolBegan(at: CGPoint(x: 500, y: 400), exclude: false)
        model.imageToolMoved(to: CGPoint(x: 560, y: 400))
        XCTAssertTrue(model.isDraggingMask)

        model.disarmTools()
        XCTAssertFalse(model.isDraggingMask, "the overlay is drawn while this is true")
        XCTAssertNil(model.lastDab)
        XCTAssertFalse(model.imageToolActive, "so the release never reaches maskToolEnded")
    }

    func testEscapeDuringAGradientDragEndsTheDrag() async throws {
        let model = try await openModel()
        model.addLocal(.linear)
        model.imageToolBegan(at: CGPoint(x: 300, y: 300), exclude: false)
        model.imageToolMoved(to: CGPoint(x: 600, y: 300))
        XCTAssertTrue(model.isDraggingMask)

        model.disarmTools()
        XCTAssertFalse(model.isDraggingMask)
        XCTAssertNil(model.maskDragBox)
    }
}
