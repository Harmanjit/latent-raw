import XCTest
import Metal
import Combine
import PixelEngine
@testable import latent_app

/// The editor's renders off the main thread's wait, latest wins
/// (EditorModel+RenderQueue.swift, docs/Performance-Plan.md fixes #15 and
/// #20): edits arriving while one is on the GPU coalesce into one render
/// of the newest values, and what lands is exactly what a render on the
/// spot makes.
@MainActor
final class RenderQueueTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: try TestAssets.d750URL(), catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        model.rerenderForViewport()
        await model.renderSettled()
        model.resetDragRender()
        return model
    }

    private func bytes(_ texture: MTLTexture, gpu: GPUContext) throws -> [Float] {
        try XCTUnwrap(ScopeReadback.rgbaFloats(texture, commandQueue: gpu.commandQueue))
    }

    /// The preview as a render on the spot, waited for, in the analysis pool.
    private func onTheSpot(_ model: EditorModel) throws -> [Float] {
        let session = try XCTUnwrap(model.session), pipeline = try XCTUnwrap(model.pipeline)
        let gpu = try XCTUnwrap(model.gpuContext)
        defer { session.releasePooledTextures(in: .analysis) }
        return try session.withTexturePool(.analysis) {
            let t = try pipeline.render(session, scale: .binned(quads: model.previewQuads),
                                        parameters: model.renderParameters, output: model.displayOutput)
            return try bytes(t, gpu: gpu)
        }
    }

    func testEditsWhileOneRendersCoalesceIntoTheNewest() async throws {
        let savedHQ = ViewingSettings.shared.highQualityPreview
        ViewingSettings.shared.highQualityPreview = false
        defer { ViewingSettings.shared.highQualityPreview = savedHQ }
        let model = try await openModel()
        let gpu = try XCTUnwrap(model.gpuContext)
        var renders = 0
        let watch = model.previewPublisher.dropFirst().sink { if $0 != nil { renders += 1 } }
        defer { watch.cancel() }

        model.parameters.exposureEV = 0.1
        XCTAssertTrue(model.renderInFlight, "sent to the GPU, not waited for")
        XCTAssertEqual(renders, 1, "the first edit is encoded at once")
        for i in 2...10 { model.parameters.exposureEV = Float(i) * 0.1 }
        XCTAssertEqual(renders, 1, "the rest wait for it")
        await model.renderSettled()
        XCTAssertEqual(renders, 2, "and render once, with the newest values")
        XCTAssertFalse(model.renderInFlight)
        XCTAssertEqual(model.renderParameters.exposureEV, 1.0, accuracy: 1e-6)

        model.settleDragRender()
        await model.renderSettled()
        XCTAssertFalse(model.dragRender.previewIsDraft)
        XCTAssertEqual(try bytes(try XCTUnwrap(model.preview?.texture), gpu: gpu), try onTheSpot(model))
        XCTAssertTrue(model.renderReport.hasPrefix("preview"), model.renderReport)
        XCTAssertTrue(model.renderReport.hasSuffix(" ms"), model.renderReport)
        XCTAssertNotNil(model.histogram, "the scopes follow the finished render")
    }

    /// A render that waits (the magnifier's, masked scopes', an AI mask's
    /// input) while the editor's is on the GPU sees the editor's finished
    /// state and matches a render with nothing in flight.
    func testARenderThatWaitsWhileOneIsInFlightMatches() async throws {
        let model = try await openModel()
        model.parameters.exposureEV = 0.7
        XCTAssertTrue(model.renderInFlight)
        let during = try onTheSpot(model)
        await model.renderSettled()
        XCTAssertEqual(during, try onTheSpot(model))
    }

    /// High Quality Preview keeps its full-resolution textures between
    /// renders, and is not shown over an edit that came meanwhile.
    func testHighQualityPreviewKeepsItsBuffersAndYieldsToAnEdit() async throws {
        let model = try await openModel()
        let settings = ViewingSettings.shared
        let wasOn = settings.highQualityPreview
        defer { settings.highQualityPreview = wasOn }
        settings.highQualityPreview = true
        settings.setPrimaryEditor(model)
        let session = try XCTUnwrap(model.session)

        model.renderHighQualityPreview()
        await model.renderSettled()
        let first = try XCTUnwrap(model.preview)
        let longEdge = Int((max(model.sensorSize.width, model.sensorSize.height) * model.viewport.zoom).rounded(.up))
        XCTAssertEqual(max(first.texture.width, first.texture.height), longEdge, "the high-quality layer")
        let held = session.approximateBytesHeld

        model.parameters.exposureEV = 0.3
        await model.renderSettled()
        XCTAssertGreaterThanOrEqual(session.approximateBytesHeld, held, "the full-resolution pool stays")
        model.renderHighQualityPreview()
        await model.renderSettled()
        let second = try XCTUnwrap(model.preview)
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertTrue(second.texture === first.texture, "the resample's buffers are reused")

        // An edit while it renders: the edit's preview stays.
        model.renderHighQualityPreview()
        model.parameters.exposureEV = 0.5
        await model.renderSettled()
        XCTAssertFalse(model.preview?.texture === first.texture)
        XCTAssertNotEqual(max(model.preview?.texture.width ?? 0, model.preview?.texture.height ?? 0), longEdge,
                          "the binned preview, not the high-quality one")
    }

    /// A High Quality Preview request and a settle waiting behind the same
    /// pass: with no draft on screen the settle renders nothing, so the
    /// high-quality pass still runs instead of being dropped.
    func testHighQualityPreviewIsNotDroppedByASettleThatRendersNothing() async throws {
        let model = try await openModel()
        let settings = ViewingSettings.shared
        let wasOn = settings.highQualityPreview
        defer { settings.highQualityPreview = wasOn }
        settings.highQualityPreview = true
        settings.setPrimaryEditor(model)

        model.parameters.exposureEV = 0.2
        XCTAssertTrue(model.renderInFlight)
        XCTAssertFalse(model.dragRender.previewIsDraft, "a single edit is not a drag's draft")
        model.settleDragRender()
        model.renderHighQualityPreview()
        XCTAssertTrue(model.renderQueue.pending.settle)
        XCTAssertNotNil(model.renderQueue.pending.highQuality)
        await model.renderSettled()
        let longEdge = Int((max(model.sensorSize.width, model.sensorSize.height) * model.viewport.zoom).rounded(.up))
        let shown = try XCTUnwrap(model.preview)
        XCTAssertEqual(max(shown.texture.width, shown.texture.height), longEdge, "the high-quality layer")
        XCTAssertTrue(model.renderReport.hasPrefix("high quality"), model.renderReport)
    }

    /// A photo change doesn't wait for the last photo's render.
    func testAnotherPhotoRendersWithoutWaitingForTheLast() async throws {
        let model = try await openModel()
        model.parameters.exposureEV = 0.4
        XCTAssertTrue(model.renderInFlight)
        model.open(url: try TestAssets.d750URL(), catalogImageID: 2)
        XCTAssertTrue(model.renderInFlight, "the new photo's render is on its way")
        await model.renderSettled()
        XCTAssertNotNil(model.preview)
        XCTAssertFalse(model.renderInFlight)
    }
}
