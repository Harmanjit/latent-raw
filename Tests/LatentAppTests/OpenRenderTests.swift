import XCTest
import Combine
import PixelEngine
@testable import latent_app

/// What an open renders (plan fixes #8 and #10): once, even when the
/// stored edit differs from the previous photo's settings, and the
/// high-quality preview follows it without the settle delay.
@MainActor
final class OpenRenderTests: XCTestCase {
    private func readyModel() async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        XCTAssertTrue(model.isReady)
        return model
    }

    /// One render per open (#8); it used to be two whenever the new photo's
    /// settings differed, the parameters' didSet rendering first.
    func testAnOpenRendersOnce() async throws {
        let model = try await readyModel()
        let url = try TestAssets.d750URL()
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        model.open(url: url, catalogImageID: 1)
        var renders = 0
        let watch = model.$preview.dropFirst().sink { if $0 != nil { renders += 1 } }
        defer { watch.cancel() }
        var stored = EditParameters()
        stored.exposureEV = 1.3
        stored.contrast = 20
        model.open(url: url, catalogImageID: 2, editStackJSON: try EditStack(parameters: stored).encodeJSON())
        XCTAssertEqual(renders, 1, "the parameters' didSet no longer renders during an open")
        XCTAssertEqual(model.parameters.exposureEV, 1.3, accuracy: 1e-6)
        // An edit afterwards still renders from the didSet.
        await model.renderSettled()
        model.parameters.exposureEV = 0.2
        XCTAssertEqual(renders, 2)
    }

    /// Right after an open the high-quality preview waits only a frame
    /// (#10); after an edit, the usual settle delay again.
    func testTheHighQualityPreviewSkipsTheSettleDelayAfterAnOpen() async throws {
        let model = try await readyModel()
        let url = try TestAssets.d750URL()
        model.open(url: url, catalogImageID: 1)
        XCTAssertEqual(model.highQualityPreviewWait, EditorModel.highQualityPreviewDelayAfterOpen)
        XCTAssertLessThan(EditorModel.highQualityPreviewDelayAfterOpen, .milliseconds(50))
        model.parameters.exposureEV = 0.5
        XCTAssertEqual(model.highQualityPreviewWait, EditorModel.highQualityPreviewDelay)
        // The next open shortens it again; its own preview ends that.
        model.open(url: url, catalogImageID: 2)
        XCTAssertEqual(model.highQualityPreviewWait, EditorModel.highQualityPreviewDelayAfterOpen)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        model.renderHighQualityPreview()
        XCTAssertEqual(model.highQualityPreviewWait, EditorModel.highQualityPreviewDelay)
    }

    /// At launch the shared GPU context is often built before the task
    /// that attaches it gets to run (#9): an open takes it at once rather
    /// than waiting for that task.
    func testAnOpenTakesTheBuiltContextWithoutWaiting() async throws {
        let gpu = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        // As if the attach task hadn't run yet.
        model.gpuContext = nil
        model.open(url: try TestAssets.d750URL(), catalogImageID: 1)
        XCTAssertNil(model.openWhenGPUReady, "not deferred")
        XCTAssertTrue(model.gpuContext === gpu)
        XCTAssertTrue(model.hasImage)
    }
}
