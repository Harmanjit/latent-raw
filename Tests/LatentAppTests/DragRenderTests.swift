import XCTest
import Metal
import PixelEngine
@testable import latent_app

/// The cheaper renders a drag shows (EditorModel+DragRender.swift,
/// docs/Performance-Plan.md fixes 3, 4 and 25): the first edit of a burst
/// renders at full quality, the ticks after it render the draft, and the
/// full-quality render comes back once the edits stop.
@MainActor
final class DragRenderTests: XCTestCase {
    /// A 6032 x 4032 D750 raw in a retina 2560 x 1600 view: fit is about
    /// 0.42, so the full preview bins 1 quad (3016 px wide, about one
    /// pixel per screen pixel) and the draft bins 2 (one per point).
    private func openModel(drawable: CGSize = CGSize(width: 2560, height: 1600)) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewBackingScale = 2
        model.viewportDidResize(to: drawable)
        model.rerenderForViewport()
        // The renders above came moments ago; the test's first edit must
        // not count as a tick of a drag that began with them.
        model.resetDragRender()
        return model
    }

    // MARK: - The bin factor

    func testDraftAsksForOnePreviewPixelPerPoint() {
        // Unchanged without the new argument.
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.42, secondaryZoom: nil), 1)
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.42, secondaryZoom: nil, mainPixelsPerPreviewPixel: 2), 2,
                       "retina fit: binned-2, about the view's size in points")
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.25, secondaryZoom: nil, mainPixelsPerPreviewPixel: 2), 4)
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.42, secondaryZoom: nil, mainPixelsPerPreviewPixel: 1), 1,
                       "a 1x screen keeps its size")
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.42, secondaryZoom: 0.42, mainPixelsPerPreviewPixel: 2), 1,
                       "the second display keeps its own full size")
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.42, secondaryZoom: nil, mainPixelsPerPreviewPixel: 0), 1,
                       "a nonsense scale counts as 1")
    }

    // MARK: - Fit (fix 4)

    func testDragAtFitRendersTheDraftAndSettlesToFullSize() async throws {
        let model = try await openModel()
        XCTAssertEqual(model.previewQuads, 1)
        let fullWidth = try XCTUnwrap(model.preview?.texture.width)

        model.parameters.exposureEV = 0.2   // the first edit: full quality
        XCTAssertEqual(model.previewQuads, 1)
        XCTAssertFalse(model.dragRender.previewIsDraft)

        model.parameters.exposureEV = 0.3   // a tick right after it: the draft
        XCTAssertEqual(model.previewQuads, 2)
        XCTAssertTrue(model.dragRender.previewIsDraft)
        XCTAssertEqual(model.preview?.texture.width, fullWidth / 2)
        XCTAssertNotNil(model.dragRender.settleTask, "the full-quality render is queued")

        // Left alone, the settle render runs by itself.
        try await Task.sleep(for: EditorModel.dragSettleDelay + .milliseconds(250))
        XCTAssertEqual(model.previewQuads, 1)
        XCTAssertFalse(model.dragRender.previewIsDraft)
        XCTAssertEqual(model.preview?.texture.width, fullWidth)
        XCTAssertNil(model.dragRender.settleTask)
        XCTAssertEqual(model.parameters.exposureEV, 0.3)
    }

    /// The settled picture is exactly what a lone edit renders.
    func testSettledPreviewMatchesAnUndraggedRender() async throws {
        let model = try await openModel()
        model.parameters.exposureEV = 0.2
        model.parameters.exposureEV = 0.5
        XCTAssertTrue(model.dragRender.previewIsDraft)
        model.settleDragRender()
        let gpu = try await GPUContext.shared()
        let settled = try TextureReadback.float16Pixels(of: try XCTUnwrap(model.preview?.texture), gpu: gpu)

        model.resetDragRender()
        model.rerender()   // not a tick: nothing came before it
        XCTAssertFalse(model.dragRender.previewIsDraft)
        let fresh = try TextureReadback.float16Pixels(of: try XCTUnwrap(model.preview?.texture), gpu: gpu)
        XCTAssertEqual(settled, fresh)
    }

    /// A viewport change while the draft shows renders the full preview.
    func testViewportChangeReplacesTheDraft() async throws {
        let model = try await openModel()
        model.parameters.exposureEV = 0.2
        model.parameters.exposureEV = 0.3
        XCTAssertEqual(model.previewQuads, 2)
        model.rerenderForViewport()
        XCTAssertEqual(model.previewQuads, 1)
        XCTAssertFalse(model.dragRender.previewIsDraft)
    }

    /// A new photo's first render is never a draft, and the old photo's
    /// queued settle render is dropped.
    func testOpeningAnotherPhotoForgetsTheDrag() async throws {
        let model = try await openModel()
        model.parameters.exposureEV = 0.2
        model.parameters.exposureEV = 0.3
        XCTAssertNotNil(model.dragRender.settleTask)
        model.open(url: try TestAssets.d750URL(), catalogImageID: 2)
        XCTAssertNil(model.dragRender.settleTask)
        XCTAssertFalse(model.dragRender.previewIsDraft)
        XCTAssertEqual(model.previewQuads, 1)
    }

    // MARK: - 100% (fix 3)

    /// At 100% the tile covers the view, so the preview behind it renders
    /// at the scopes' size during a drag, and that render is the scopes'
    /// too. The tile itself is the full one.
    func testDragAtOneHundredPercentRendersACoarseBackdrop() async throws {
        let model = try await openModel()
        model.toggleZoom(at: CGPoint(x: 1280, y: 800))
        model.rerenderForViewport()
        XCTAssertTrue(model.wantsTile)
        XCTAssertEqual(model.previewQuads, 1)
        let tileWidth = try XCTUnwrap(model.tile?.texture.width)

        model.parameters.exposureEV = 0.2
        XCTAssertEqual(model.previewQuads, 1, "the first edit renders the full backdrop")
        model.parameters.exposureEV = 0.3
        XCTAssertEqual(model.previewQuads, EditorModel.analysisQuads)
        XCTAssertTrue(model.dragRender.previewIsDraft)
        XCTAssertTrue(model.preview?.texture === model.analysisTexture, "one render serves the backdrop and the scopes")
        XCTAssertEqual(model.tile?.texture.width, tileWidth)

        model.settleDragRender()
        XCTAssertEqual(model.previewQuads, 1)
        XCTAssertFalse(model.dragRender.previewIsDraft)
        XCTAssertFalse(model.preview?.texture === model.analysisTexture)
    }

    /// With the second display's Loupe open the backdrop is what that
    /// screen shows, so it keeps the size the Loupe asks for.
    func testBackdropKeepsTheSecondDisplaysSize() async throws {
        let model = try await openModel()
        model.secondaryViewportDidResize(to: CGSize(width: 5120, height: 2880))
        model.toggleZoom(at: CGPoint(x: 1280, y: 800))
        model.rerenderForViewport()
        model.parameters.exposureEV = 0.2
        model.parameters.exposureEV = 0.3
        let secondary = try XCTUnwrap(model.secondaryFitZoom)
        XCTAssertEqual(model.previewQuads, SecondaryPreview.previewQuads(mainZoom: nil, secondaryZoom: secondary))
        XCTAssertFalse(model.preview?.texture === model.analysisTexture)
    }
}
