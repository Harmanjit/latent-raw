import XCTest
import Metal
import PixelEngine
@testable import latent_app

/// The editor's renders hand whole brush-mask redraws off the main thread
/// (ImageSession.defersBrushRedraws): after an undo or a feather change
/// the redraw lands, the editor renders again by itself, and the preview
/// is then exactly what a render made on the spot gives.
@MainActor
final class BrushRedrawEditorTests: XCTestCase {
    private func strokes(feather: Float, count: Int = 5) -> [BrushStroke] {
        (0..<count).map { k in
            BrushStroke(points: (0..<30).map { j in SIMD2(0.15 + Float(j) * 0.02, 0.2 + Float(k) * 0.12) },
                        radius: 0.05, feather: feather, flow: 1, erase: false)
        }
    }

    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    private func bytes(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [Float] {
        try XCTUnwrap(ScopeReadback.rgbaFloats(texture, commandQueue: queue))
    }

    /// Waits for the redraw to land and the editor's own render after it.
    private func waitForRedraw(_ model: EditorModel, session: ImageSession) async throws {
        for _ in 0..<200 where session.hasPendingBrushRedraws {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.hasPendingBrushRedraws, "the redraw landed")
        await model.brushRedrawRender?.value   // and the render that shows it
        await model.renderSettled()
    }

    /// The preview as a render on the spot (nothing deferred) makes it.
    private func onTheSpot(_ model: EditorModel) throws -> [Float] {
        let session = try XCTUnwrap(model.session), pipeline = try XCTUnwrap(model.pipeline)
        let gpu = try XCTUnwrap(model.gpuContext)
        XCTAssertFalse(session.defersBrushRedraws)
        defer { session.releasePooledTextures(in: .analysis) }
        return try session.withTexturePool(.analysis) {
            let t = try pipeline.render(session, scale: .binned(quads: model.previewQuads),
                                        parameters: model.renderParameters, output: model.displayOutput)
            return try bytes(t, queue: gpu.commandQueue)
        }
    }

    func testFeatherChangeAndUndoEndExactlyAsOnTheSpot() async throws {
        // High Quality Preview would swap in a full-resolution layer.
        let savedHQ = ViewingSettings.shared.highQualityPreview
        ViewingSettings.shared.highQualityPreview = false
        defer { ViewingSettings.shared.highQualityPreview = savedHQ }
        let model = try await openModel()
        let session = try XCTUnwrap(model.session), gpu = try XCTUnwrap(model.gpuContext)
        var p = model.parameters
        p.locals = [LocalAdjustment(name: "brush", shape: .brush(strokes: strokes(feather: 0.3)), exposureEV: 1)]
        model.parameters = p
        model.rerender()
        await model.renderSettled()
        XCTAssertFalse(session.hasPendingBrushRedraws, "a new mask is drawn on the spot")

        // Feather: every stroke changes, a whole redraw.
        model.parameters.locals[0].shape = .brush(strokes: strokes(feather: 0.8))
        model.rerender()
        await model.renderSettled()
        XCTAssertTrue(session.hasPendingBrushRedraws, "redrawn off the main thread")
        try await waitForRedraw(model, session: session)
        let preview = try XCTUnwrap(model.preview?.texture)
        XCTAssertEqual(try bytes(preview, queue: gpu.commandQueue), try onTheSpot(model))

        // Fast repeated changes: only the latest is what stays.
        for f in [Float(0.5), 0.6, 0.1] {
            model.parameters.locals[0].shape = .brush(strokes: strokes(feather: f))
            model.rerender()
        }
        try await waitForRedraw(model, session: session)
        XCTAssertEqual(try bytes(try XCTUnwrap(model.preview?.texture), queue: gpu.commandQueue), try onTheSpot(model))

        // Undo of a stroke: a shorter list, also a whole redraw.
        model.parameters.locals[0].shape = .brush(strokes: strokes(feather: 0.1, count: 3))
        model.rerender()
        try await waitForRedraw(model, session: session)
        XCTAssertEqual(try bytes(try XCTUnwrap(model.preview?.texture), queue: gpu.commandQueue), try onTheSpot(model))
    }

    /// A render that does not defer (the magnifier's delayed render, the
    /// masked scope measurement) runs after rerender() but before the
    /// redraw lands: it brings the slice current in its own texture, and
    /// the editor must still render again so the preview shows it.
    func testRenderThatDoesNotDeferBeforeTheRedrawLandsStillUpdatesThePreview() async throws {
        let savedHQ = ViewingSettings.shared.highQualityPreview
        ViewingSettings.shared.highQualityPreview = false
        defer { ViewingSettings.shared.highQualityPreview = savedHQ }
        let model = try await openModel()
        let session = try XCTUnwrap(model.session), gpu = try XCTUnwrap(model.gpuContext)
        var p = model.parameters
        p.locals = [LocalAdjustment(name: "brush", shape: .brush(strokes: strokes(feather: 0.3)), exposureEV: 1)]
        model.parameters = p
        model.rerender()
        await model.renderSettled()
        let before = try bytes(try XCTUnwrap(model.preview?.texture), queue: gpu.commandQueue)

        model.parameters.locals[0].shape = .brush(strokes: strokes(feather: 0.8))
        model.rerender()
        await model.renderSettled()
        XCTAssertTrue(session.hasPendingBrushRedraws)
        // Synchronous on the main actor, so the redraw cannot land first.
        let current = try onTheSpot(model)
        // Booleans, so a failure does not print every pixel.
        XCTAssertTrue(try bytes(try XCTUnwrap(model.preview?.texture), queue: gpu.commandQueue) == before,
                      "the preview still shows the old mask")
        XCTAssertTrue(current != before)
        try await waitForRedraw(model, session: session)
        XCTAssertTrue(try bytes(try XCTUnwrap(model.preview?.texture), queue: gpu.commandQueue) == current,
                      "the editor rendered again and shows the current mask")
    }
}
