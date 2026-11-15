import XCTest
import Metal
import PixelEngine
@testable import latent_app

/// Scope menu › Selected Mask Only, measured off the main thread
/// (EditorModel+MaskedScopes.swift): the scopes it shows are exactly what
/// measuring on the spot gave (the old main-thread path, rebuilt here as
/// the reference), and a result overtaken by a newer measurement is
/// dropped.
@MainActor
final class MaskedScopesAsyncTests: XCTestCase {
    private var savedMaskOnly = false

    override func setUp() async throws {
        savedMaskOnly = ScopeSettings.shared.selectedMaskOnly
    }

    override func tearDown() async throws {
        ScopeSettings.shared.selectedMaskOnly = savedMaskOnly
    }

    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        var p = model.parameters
        p.locals = [LocalAdjustment(name: "radial", shape: .radial(centre: [0.4, 0.5], radii: [0.3, 0.2], feather: 0.6),
                                    exposureEV: 0.7)]
        model.parameters = p
        model.selectedLocalIndex = 0
        model.rerender()
        return model
    }

    /// Stops a throttled measurement queued by the setup from starting a
    /// newer one (which would rightly drop the result under test).
    private func settle(_ model: EditorModel) {
        model.pendingScopeMeasurement?.cancel()
        model.pendingScopeMeasurement = nil
    }

    /// The measurement as it was made on the main thread before: the mask
    /// overlay rendered into the analysis pool, both read back, weighted.
    private func reference(_ model: EditorModel, wanted: MaskedScopeAccumulator.Wanted) throws
        -> MaskedScopeAccumulator.Result {
        let session = try XCTUnwrap(model.session), pipeline = try XCTUnwrap(model.pipeline)
        let gpu = try XCTUnwrap(model.gpuContext), analysis = try XCTUnwrap(model.analysisTexture)
        defer { session.releasePooledTextures(in: .analysis) }
        let quads = max(model.previewQuads, 4)
        func readBack(_ output: RenderOutput) throws -> [Float] {
            try XCTUnwrap(try session.withTexturePool(.analysis) {
                let t = try pipeline.render(session, scale: .binned(quads: quads),
                                            parameters: model.renderParameters, output: output)
                return ScopeReadback.rgbaFloats(t, commandQueue: gpu.commandQueue)
            })
        }
        var clean = model.displayOutput
        clean.rawClipMask = false
        let pixels: [Float]
        if clean.maskOverlay != nil {
            clean.maskOverlay = nil
            clean.maskOverlayStyle = .standard
            pixels = try readBack(clean)
        } else {
            pixels = try XCTUnwrap(ScopeReadback.rgbaFloats(analysis, commandQueue: gpu.commandQueue))
        }
        var maskOutput = RenderOutput.edrDisplay(headroom: 1)
        maskOutput.maskOverlay = 0
        maskOutput.maskOverlayStyle = MaskOverlayStyle(mode: .whiteOnBlack)
        let maskPixels = try readBack(maskOutput)
        return MaskedScopeReadback.measure(pixels: pixels, maskPixels: maskPixels, width: analysis.width,
                                           height: analysis.height, wanted: wanted)
    }

    private func assertSame(_ a: Histogram?, _ b: Histogram?, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("missing histogram", file: file, line: line) }
        XCTAssertEqual(a.red, b.red, file: file, line: line)
        XCTAssertEqual(a.green, b.green, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, file: file, line: line)
        XCTAssertEqual(a.luminance, b.luminance, file: file, line: line)
        XCTAssertEqual(a.peak, b.peak, file: file, line: line)
        XCTAssertEqual(a.totalPixels, b.totalPixels, file: file, line: line)
        XCTAssertEqual(a.aboveSDRWhite, b.aboveSDRWhite, file: file, line: line)
    }

    func testHistogramMatchesTheMainThreadMeasurement() async throws {
        let model = try await openModel()
        ScopeSettings.shared.selectedMaskOnly = true
        model.scope = .histogram
        let expected = try reference(model, wanted: .histogram)
        XCTAssertGreaterThan(expected.histogram?.totalPixels ?? 0, 0, "the mask covers part of the frame")
        model.histogram = nil
        settle(model)
        XCTAssertTrue(model.measureMaskedScopes(from: try XCTUnwrap(model.analysisTexture)))
        await model.maskedScopeTask?.value
        assertSame(model.histogram, expected.histogram)
    }

    func testWaveformAndVectorscopeMatchWithTheOverlayShowing() async throws {
        let model = try await openModel()
        ScopeSettings.shared.selectedMaskOnly = true
        model.showMaskOverlay = true
        model.rerender()
        XCTAssertNotNil(model.displayOutput.maskOverlay, "the analysis render carries the tint")
        model.scope = .waveformVectorscope
        let expected = try reference(model, wanted: [.waveform, .vectorscope])
        model.waveform = nil
        model.vectorscope = nil
        settle(model)
        XCTAssertTrue(model.measureMaskedScopes(from: try XCTUnwrap(model.analysisTexture)))
        await model.maskedScopeTask?.value
        let waveform = try XCTUnwrap(model.waveform), want = try XCTUnwrap(expected.waveform)
        XCTAssertEqual(waveform.red, want.red)
        XCTAssertEqual(waveform.green, want.green)
        XCTAssertEqual(waveform.blue, want.blue)
        XCTAssertEqual(waveform.peak, want.peak)
        let vectorscope = try XCTUnwrap(model.vectorscope), wantV = try XCTUnwrap(expected.vectorscope)
        XCTAssertEqual(vectorscope.counts, wantV.counts)
        XCTAssertEqual(vectorscope.peak, wantV.peak)
    }

    /// Turning the option off while a masked measurement runs: the whole
    /// picture's histogram, measured after, is what stays.
    func testOvertakenResultIsDropped() async throws {
        let model = try await openModel()
        ScopeSettings.shared.selectedMaskOnly = true
        model.scope = .histogram
        let analysis = try XCTUnwrap(model.analysisTexture)
        settle(model)
        XCTAssertTrue(model.measureMaskedScopes(from: analysis))
        let task = model.maskedScopeTask
        ScopeSettings.shared.selectedMaskOnly = false
        model.lastScopeMeasurement = nil
        model.updateScopes()
        let whole = try XCTUnwrap(model.histogram)
        await task?.value
        let shown = try XCTUnwrap(model.histogram)
        XCTAssertEqual(shown.totalPixels, whole.totalPixels)
        XCTAssertEqual(shown.luminance, whole.luminance)
        XCTAssertEqual(shown.totalPixels, analysis.width * analysis.height, "the whole picture, not the mask")
    }
}
