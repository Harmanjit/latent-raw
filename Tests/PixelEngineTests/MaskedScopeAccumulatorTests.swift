import XCTest
@testable import PixelEngine

/// Scopes limited to a mask: every pixel counts by its mask weight.
final class MaskedScopeAccumulatorTests: XCTestCase {
    private let all: MaskedScopeAccumulator.Wanted = [.histogram, .waveform, .vectorscope]
    private let full = UInt32(MaskedScopeAccumulator.weightScale)

    /// A 2×1 image: left pixel black, right pixel white (linear).
    private func blackWhite() -> [Float] { [0, 0, 0, 1, 1, 1, 1, 1] }

    func testWeightZeroPixelsAreIgnored() throws {
        let r = MaskedScopeAccumulator.accumulate(rgba: blackWhite(), weights: [0, 1], width: 2, height: 1, wanted: all)
        let h = try XCTUnwrap(r.histogram)
        XCTAssertEqual(h.red[0], 0)
        XCTAssertEqual(h.red[255], full)
        XCTAssertEqual(h.luminance[255], full)
        XCTAssertEqual(h.totalPixels, Int(full))
        XCTAssertEqual(h.clippedFraction.red, 1, accuracy: 1e-6)
        XCTAssertEqual(h.peak, full)
    }

    func testWeightsScaleCounts() throws {
        let r = MaskedScopeAccumulator.accumulate(rgba: blackWhite(), weights: [0.25, 0.5], width: 2, height: 1, wanted: all)
        let h = try XCTUnwrap(r.histogram)
        XCTAssertEqual(h.red[0], full / 4)
        XCTAssertEqual(h.red[255], full / 2)
        XCTAssertEqual(h.totalPixels, Int(full) * 3 / 4)
        // Weights outside 0...1 clamp.
        let c = MaskedScopeAccumulator.accumulate(rgba: blackWhite(), weights: [-1, 7], width: 2, height: 1, wanted: all)
        XCTAssertEqual(c.histogram?.red[0], 0)
        XCTAssertEqual(c.histogram?.red[255], full)
    }

    func testEmptyMaskGivesEmptyScopes() {
        let r = MaskedScopeAccumulator.accumulate(rgba: blackWhite(), weights: [0, 0], width: 2, height: 1, wanted: all)
        XCTAssertEqual(r.histogram?.peak, 0)
        XCTAssertEqual(r.waveform?.peak, 0)
        XCTAssertEqual(r.vectorscope?.peak, 0)
        XCTAssertEqual(r.histogram?.totalPixels, 0)
    }

    func testOnlyWantedScopesAreBuilt() {
        let r = MaskedScopeAccumulator.accumulate(rgba: blackWhite(), weights: [1, 1], width: 2, height: 1, wanted: .vectorscope)
        XCTAssertNil(r.histogram)
        XCTAssertNil(r.waveform)
        XCTAssertNotNil(r.vectorscope)
    }

    func testWaveformColumnsAndRows() throws {
        let r = MaskedScopeAccumulator.accumulate(rgba: blackWhite(), weights: [1, 1], width: 2, height: 1, wanted: .waveform)
        let w = try XCTUnwrap(r.waveform)
        let cols = Waveform.columns
        // Left pixel in column 0, row 0 (dark); right in column 128, top row.
        XCTAssertEqual(w.red[0 * cols + 0], full)
        XCTAssertEqual(w.green[(Waveform.rows - 1) * cols + cols / 2], full)
        XCTAssertEqual(w.blue.reduce(0, +), 2 * full)
    }

    func testVectorscopeMatchesSamplePosition() throws {
        // A saturated red lands where Vectorscope.position says it does.
        let red: [Float] = [0.8, 0.05, 0.05, 1]
        let r = MaskedScopeAccumulator.accumulate(rgba: red, weights: [1], width: 1, height: 1, wanted: .vectorscope)
        let v = try XCTUnwrap(r.vectorscope)
        let n = Vectorscope.size
        let at = Vectorscope.position(ofLinear: SIMD3(0.8, 0.05, 0.05))
        let x = Int(at.x * Float(n - 1) + 0.5), y = Int(at.y * Float(n - 1) + 0.5)
        XCTAssertEqual(v.counts[y * n + x], full)
        // Neutral sits in the centre.
        let grey = MaskedScopeAccumulator.accumulate(rgba: [0.2, 0.2, 0.2, 1], weights: [1], width: 1, height: 1,
                                                     wanted: .vectorscope)
        // Neutral sits in the centre cell: (0.5 × 127 + 0.5) rounds down to 64.
        XCTAssertEqual(grey.vectorscope?.counts[64 * n + 64], full)
    }

    func testAboveSDRWhiteIsWeighted() {
        let bright: [Float] = [2, 2, 2, 1, 0.5, 0.5, 0.5, 1]
        let r = MaskedScopeAccumulator.accumulate(rgba: bright, weights: [0.5, 1], width: 2, height: 1, wanted: .histogram)
        XCTAssertEqual(r.histogram?.aboveSDRWhite, Int(full) / 2)
    }

    func testMaskWeightUndoesTheWhiteOnBlackOverlay() {
        // The overlay writes mask² × 0.6 in a linear render.
        for m: Float in [0, 0.1, 0.5, 0.9, 1] {
            let v = m * m * MaskedScopeAccumulator.overlayWhiteLinear
            XCTAssertEqual(MaskedScopeAccumulator.maskWeight(fromOverlay: v, v, v), m, accuracy: 1e-5)
        }
        XCTAssertEqual(MaskedScopeAccumulator.maskWeight(fromOverlay: 5, 5, 5), 1)
        XCTAssertEqual(MaskedScopeAccumulator.maskWeight(fromOverlay: -1, -1, -1), 0)
        XCTAssertEqual(MaskedScopeAccumulator.maskWeight(fromOverlay: .nan, 0, 0), 0)
    }
}
