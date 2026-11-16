import XCTest
import Metal
import PixelEngine
@testable import latent_app

/// Scope menu › Selected Mask Only over a brush mask whose whole redraw
/// runs off the main thread (ImageSession.defersBrushRedraws): while the
/// redraw is pending the scopes may lag, but once it lands and the render
/// after it completes they describe the current mask, never the old one.
@MainActor
final class MaskedScopesBrushRedrawTests: XCTestCase {
    private var savedMaskOnly = false
    private var savedHQ = false

    override func setUp() async throws {
        savedMaskOnly = ScopeSettings.shared.selectedMaskOnly
        savedHQ = ViewingSettings.shared.highQualityPreview
        // High Quality Preview would swap in a full-resolution layer.
        ViewingSettings.shared.highQualityPreview = false
    }

    override func tearDown() async throws {
        ScopeSettings.shared.selectedMaskOnly = savedMaskOnly
        ViewingSettings.shared.highQualityPreview = savedHQ
    }

    private func strokes(feather: Float) -> [BrushStroke] {
        (0..<5).map { k in
            BrushStroke(points: (0..<30).map { j in SIMD2(0.15 + Float(j) * 0.02, 0.2 + Float(k) * 0.12) },
                        radius: 0.05, feather: feather, flow: 1, erase: false)
        }
    }

    /// A brush mask, selected, rendered at full quality with nothing left
    /// waiting. `dropRedraws`: the session's finished redraws are thrown
    /// away, so one stays pending for as long as the test needs.
    private func openModel(dropRedraws: Bool = false) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        if dropRedraws { try XCTUnwrap(model.session).onBrushRasterReady = { _ in } }
        var p = model.parameters
        p.locals = [LocalAdjustment(name: "brush", shape: .brush(strokes: strokes(feather: 0.3)), exposureEV: 1)]
        model.parameters = p
        model.selectedLocalIndex = 0
        model.scope = .histogram
        model.rerenderAtFullQuality()
        await model.renderSettled()
        model.settleDragRender()
        await model.renderSettled()
        XCTAssertFalse(try XCTUnwrap(model.session).hasPendingBrushRedraws, "a new mask is drawn on the spot")
        return model
    }

    /// Every scope measurement asked for has run and landed.
    private func waitForScopes(_ model: EditorModel) async {
        for _ in 0..<50 {
            if let pending = model.pendingScopeMeasurement { await pending.value; continue }
            if let task = model.maskedScopeTask { await task.value }
            if model.pendingScopeMeasurement == nil { return }
        }
    }

    /// The masked histogram measured on the spot from the current
    /// analysis render and the current mask (a render that does not defer
    /// brings every brush slice up to date).
    private func reference(_ model: EditorModel) throws -> Histogram {
        let session = try XCTUnwrap(model.session), pipeline = try XCTUnwrap(model.pipeline)
        let gpu = try XCTUnwrap(model.gpuContext), analysis = try XCTUnwrap(model.analysisTexture)
        XCTAssertFalse(session.defersBrushRedraws)
        XCTAssertNil(model.displayOutput.maskOverlay)
        defer { session.releasePooledTextures(in: .analysis) }
        let pixels = try XCTUnwrap(ScopeReadback.rgbaFloats(analysis, commandQueue: gpu.commandQueue))
        var maskOutput = RenderOutput.edrDisplay(headroom: 1)
        maskOutput.maskOverlay = 0
        maskOutput.maskOverlayStyle = MaskOverlayStyle(mode: .whiteOnBlack)
        let maskPixels = try XCTUnwrap(try session.withTexturePool(.analysis) {
            let t = try pipeline.render(session, scale: .binned(quads: max(model.previewQuads, 4)),
                                        parameters: model.renderParameters, output: maskOutput)
            return ScopeReadback.rgbaFloats(t, commandQueue: gpu.commandQueue)
        })
        let result = MaskedScopeReadback.measure(pixels: pixels, maskPixels: maskPixels, width: analysis.width,
                                                 height: analysis.height, wanted: .histogram)
        return try XCTUnwrap(result.histogram)
    }

    private func assertSame(_ a: Histogram?, _ b: Histogram, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("missing histogram: \(message)", file: file, line: line) }
        // Booleans, so a failure does not print every bin.
        XCTAssertTrue(a.red == b.red && a.green == b.green && a.blue == b.blue && a.luminance == b.luminance,
                      message, file: file, line: line)
        XCTAssertEqual(a.totalPixels, b.totalPixels, message, file: file, line: line)
        XCTAssertEqual(a.peak, b.peak, message, file: file, line: line)
    }

    /// The editor's own flow: a feather change defers the whole redraw,
    /// the edit's render completes and measures the scopes, the redraw
    /// lands and the editor renders again. What is shown in the end is
    /// the current mask's histogram.
    func testScopesDescribeTheCurrentMaskOnceTheRedrawLands() async throws {
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        ScopeSettings.shared.selectedMaskOnly = true
        model.lastScopeMeasurement = nil
        model.updateScopes()
        await waitForScopes(model)
        let old = try reference(model)
        assertSame(model.histogram, old, "the old mask's histogram to start from")

        model.parameters.locals[0].shape = .brush(strokes: strokes(feather: 0.9))
        XCTAssertTrue(session.hasPendingBrushRedraws, "redrawn off the main thread")
        await model.renderSettled()
        for _ in 0..<200 where session.hasPendingBrushRedraws {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.hasPendingBrushRedraws, "the redraw landed")
        await model.brushRedrawRender?.value
        await model.renderSettled()
        await model.dragRender.settleTask?.value
        await model.renderSettled()
        await waitForScopes(model)

        let current = try reference(model)
        XCTAssertFalse(current.luminance == old.luminance, "the feather change moved the masked histogram")
        assertSame(model.histogram, current, "the scopes describe the current mask")
    }

    /// A masked measurement made while the session defers brush redraws
    /// (as one made from inside the editor's render would be) and one is
    /// still pending: its mask is the current one, not the slice the
    /// deferring render kept.
    func testMeasurementWhileDeferringUsesTheCurrentMask() async throws {
        let model = try await openModel(dropRedraws: true)
        let session = try XCTUnwrap(model.session)
        model.parameters.locals[0].shape = .brush(strokes: strokes(feather: 0.9))
        await model.renderSettled()
        XCTAssertTrue(session.hasPendingBrushRedraws, "the dropped redraw stays pending")

        ScopeSettings.shared.selectedMaskOnly = true
        model.pendingScopeMeasurement?.cancel()
        model.pendingScopeMeasurement = nil
        model.histogram = nil
        model.deferBrushRedraws(in: session)
        let started = model.measureMaskedScopes(from: try XCTUnwrap(model.analysisTexture))
        XCTAssertTrue(session.defersBrushRedraws, "the caller's setting is left as it was")
        session.defersBrushRedraws = false
        XCTAssertTrue(started)
        let current = try reference(model)
        await model.maskedScopeTask?.value
        assertSame(model.histogram, current, "measured over the current mask")
    }
}
