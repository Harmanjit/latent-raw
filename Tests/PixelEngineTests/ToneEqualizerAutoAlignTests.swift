import XCTest
@testable import PixelEngine

/// Auto Align and the mask statistics behind the tone equalizer panel's
/// live histogram (ToneEqualizerAutoAlign.swift). Pure functions, no GPU.
final class ToneEqualizerAutoAlignTests: XCTestCase {
    /// An evenly spread mask from `lo` to `hi` (before exposure).
    private func ramp(_ lo: Float, _ hi: Float, count: Int = 10_001) -> [Float] {
        (0..<count).map { lo + (hi - lo) * Float($0) / Float(count - 1) }
    }

    func testPercentilesFromTheFineHistogram() {
        let stats = ToneEqualizerMaskStats(values: ramp(-10, -2) + [.nan, .infinity])
        XCTAssertEqual(stats.total, 10_001, "non-finite cells are skipped")
        XCTAssertEqual(stats.percentile(0.5, exposureEV: 0)!, -6, accuracy: 0.03)
        XCTAssertEqual(stats.percentile(0.25, exposureEV: 1)!, -7, accuracy: 0.03, "exposure is added")
        XCTAssertEqual(stats.percentile(0, exposureEV: 0)!, -10, accuracy: 0.03)
        XCTAssertEqual(stats.percentile(1, exposureEV: 0)!, -2, accuracy: 0.03)
    }

    func testEmptyStatsGiveNothing() {
        let stats = ToneEqualizerMaskStats(values: [])
        XCTAssertTrue(stats.isEmpty)
        XCTAssertNil(stats.percentile(0.5, exposureEV: 0))
        XCTAssertTrue(stats.histogram(equalizer: .neutral, exposureEV: 0, range: -9.5...0.5, bins: 100).isEmpty)
        XCTAssertEqual(stats.bandShares(equalizer: .neutral, exposureEV: 0), Array(repeating: 0, count: 9))
        XCTAssertNil(ToneEqualizer.autoAlignedCompensation(stats: stats, exposureEV: 0))
    }

    func testHistogramMatchesADirectCountWithoutCompensation() {
        let values = ramp(-9, -1, count: 5_000) + Array(repeating: -4.03, count: 500)
        let stats = ToneEqualizerMaskStats(values: values)
        let derived = stats.histogram(equalizer: .neutral, exposureEV: 0, range: -9.5...0.5, bins: 100)
        let direct = HistogramCalculator.normalizedHistogram(of: values, range: -9.5...0.5, bins: 100)
        XCTAssertEqual(derived.count, 100)
        XCTAssertEqual(derived.max(), 1)
        XCTAssertEqual(derived.firstIndex(of: 1), direct.firstIndex(of: 1), "the spike is in the same bin")
        for (a, b) in zip(derived, direct) { XCTAssertEqual(a, b, accuracy: 0.05) }
    }

    func testHistogramFollowsCompensationAndExposure() {
        let stats = ToneEqualizerMaskStats(values: Array(repeating: -6, count: 100))
        var eq = ToneEqualizer.neutral
        eq.maskExposure = 1
        // −6 + 1 (exposure) + 1 (compensation) = −4: bin (−4 + 9.5) / 0.1 = 55.
        let h = stats.histogram(equalizer: eq, exposureEV: 1, range: -9.5...0.5, bins: 100)
        XCTAssertEqual(h.firstIndex(of: 1), 55)
    }

    func testBandSharesSumToOneAndPickTheNearestBand() {
        let stats = ToneEqualizerMaskStats(values: Array(repeating: -6, count: 30) + Array(repeating: -20, count: 10))
        let shares = stats.bandShares(equalizer: .neutral, exposureEV: 0)
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(shares[2], 0.75, accuracy: 1e-5, "−6 EV is band 2")
        XCTAssertEqual(shares[0], 0.25, accuracy: 1e-5, "tones below the bands count for the lowest")
        let brighter = stats.bandShares(equalizer: .neutral, exposureEV: 2)
        XCTAssertEqual(brighter[4], 0.75, accuracy: 1e-5, "two stops of exposure move them two bands up")
    }

    func testAutoAlignPutsTheEndsOnTheOuterBands() {
        let fit = ToneEqualizer.autoAlignedCompensation(low: -10, high: -4)
        let eq = ToneEqualizer.neutral.withCompensation(exposure: fit.exposure, contrast: fit.contrast)
        XCTAssertEqual(eq.compensated(-10), -8, accuracy: 1e-4)
        XCTAssertEqual(eq.compensated(-4), 0, accuracy: 1e-4)
        XCTAssertEqual(eq.compensated(-7), -4, accuracy: 1e-4, "the middle lands on the middle band")
    }

    func testAutoAlignClampsAndStaysCentred() {
        // A very flat photo would need more contrast than the slider has.
        let flat = ToneEqualizer.autoAlignedCompensation(low: -5.2, high: -4.8)
        XCTAssertEqual(flat.contrast, ToneEqualizer.maskContrastRange.upperBound)
        XCTAssertEqual(flat.exposure, 1, accuracy: 1e-5)
        // A huge range needs less than it has.
        let wide = ToneEqualizer.autoAlignedCompensation(low: -16, high: 2)
        XCTAssertEqual(wide.contrast, ToneEqualizer.maskContrastRange.lowerBound)
        // Far too bright: exposure clamps.
        let bright = ToneEqualizer.autoAlignedCompensation(low: 2, high: 6)
        XCTAssertEqual(bright.exposure, ToneEqualizer.maskExposureRange.lowerBound)
        let bad = ToneEqualizer.autoAlignedCompensation(low: .nan, high: 0)
        XCTAssertEqual(bad.exposure, 0); XCTAssertEqual(bad.contrast, 0)
    }

    func testAutoAlignFromStatsUsesTheRobustEnds() {
        // Half a percent of outliers at each end must not decide the alignment.
        var values = ramp(-11, -5, count: 9_800)
        values += Array(repeating: -16, count: 50) + Array(repeating: 1, count: 50)
        let stats = ToneEqualizerMaskStats(values: values)
        let fit = ToneEqualizer.autoAlignedCompensation(stats: stats, exposureEV: 1)!
        let eq = ToneEqualizer.neutral.withCompensation(exposure: fit.exposure, contrast: fit.contrast)
        XCTAssertEqual(eq.compensated(-10), -8, accuracy: 0.1)
        XCTAssertEqual(eq.compensated(-4), 0, accuracy: 0.1)
    }

    func testCompensationNearZeroIsStoredAbsent() {
        var eq = ToneEqualizer(bands: [0, 0, 1, 0, 0, 0, 0, 0, 0], smoothing: 0.3)
        eq = eq.withCompensation(exposure: 0.001, contrast: -0.002)
        XCTAssertNil(eq.maskExposure)
        XCTAssertNil(eq.maskContrast)
        XCTAssertEqual(eq.bands[2], 1, "bands untouched")
        XCTAssertEqual(eq.smoothing, 0.3)
        XCTAssertEqual(ToneEqualizer(bands: Array(repeating: 0, count: 9)).withCompensation(exposure: 0, contrast: 0),
                       .neutral, "aligning at zero leaves the module neutral")
    }

    func testSnapshotGenerationDefaultsToZero() {
        XCTAssertEqual(ToneEqualizerMaskSnapshot(width: 1, height: 1, values: [0], exposureEV: 0).generation, 0)
    }
}
