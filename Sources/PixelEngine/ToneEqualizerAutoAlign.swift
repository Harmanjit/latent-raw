import Foundation

/// A compact summary of the tone equalizer's mask (`ToneEqualizerMaskSnapshot`):
/// a fine histogram of its values *before* exposure and compensation.
///
/// Building it touches every mask cell once (about 260 000 on the 512-cell
/// grid), so the editor builds it off the main thread, once per new mask.
/// Everything the panel shows is then derived from it in a few thousand
/// operations, whatever the exposure or the mask compensation: both are an
/// affine map of the mask (`ToneEqualizer.compensated`), so each fine bin
/// is simply carried to where its centre lands. That keeps the histogram
/// behind the band curve live while a Mask Exposure or Mask Contrast slider
/// is dragged, without sorting or rescanning the mask on every frame.
public struct ToneEqualizerMaskStats: Sendable, Equatable {
    /// The span of mask values (log2 luminance) the fine histogram covers.
    /// The mask's floor is log2(1/65536) = −16; values outside the span are
    /// counted in the end bins.
    public static let range: ClosedRange<Float> = -18...6
    /// Fine bins over `range`: 0.02 EV each, well under the panel's 0.1 EV
    /// display bins even when Mask Contrast doubles the spread.
    public static let binCount = 1200

    /// How many mask cells fall in each fine bin.
    public let counts: [Float]
    /// All the finite cells counted.
    public let total: Float

    /// Counts `values` (mask values before exposure, as on the snapshot);
    /// non-finite values are skipped.
    public init(values: [Float]) {
        var counts = [Float](repeating: 0, count: Self.binCount)
        let lo = Self.range.lowerBound
        let scale = Float(Self.binCount) / (Self.range.upperBound - lo)
        var total: Float = 0
        for v in values where v.isFinite {
            let i = min(max(Int((v - lo) * scale), 0), Self.binCount - 1)
            counts[i] += 1
            total += 1
        }
        self.counts = counts
        self.total = total
    }

    public init(snapshot: ToneEqualizerMaskSnapshot) {
        self.init(values: snapshot.values)
    }

    public var isEmpty: Bool { total <= 0 }

    static var binWidth: Float { (range.upperBound - range.lowerBound) / Float(binCount) }

    /// The centre of fine bin `i`, before exposure.
    static func centre(_ i: Int) -> Float {
        range.lowerBound + (Float(i) + 0.5) * binWidth
    }

    /// The `fraction` (0…1) percentile of the mask with `exposureEV` added
    /// but no compensation, interpolated inside its bin; nil when empty.
    public func percentile(_ fraction: Float, exposureEV: Float) -> Float? {
        guard !isEmpty, fraction.isFinite else { return nil }
        let target = min(max(fraction, 0), 1) * total
        var running: Float = 0
        for (i, c) in counts.enumerated() where c > 0 {
            if running + c >= target {
                let t = min(max((target - running) / c, 0), 1)
                return Self.range.lowerBound + (Float(i) + t) * Self.binWidth + exposureEV
            }
            running += c
        }
        return Self.range.upperBound + exposureEV
    }

    /// The mask's histogram as the bands see it (exposure and `equalizer`'s
    /// compensation applied) over `range` in `bins` bins, fullest bin 1,
    /// like `HistogramCalculator.normalizedHistogram`; values past either
    /// end land in the end bins. Empty when there is no mask.
    public func histogram(equalizer: ToneEqualizer, exposureEV: Float, range: ClosedRange<Float>,
                          bins: Int) -> [Float] {
        guard bins > 0, range.upperBound > range.lowerBound, !isEmpty else { return [] }
        var out = [Float](repeating: 0, count: bins)
        let scale = Float(bins) / (range.upperBound - range.lowerBound)
        for (i, c) in counts.enumerated() where c > 0 {
            let m = equalizer.compensated(Self.centre(i) + exposureEV)
            let b = min(max(Int((m - range.lowerBound) * scale), 0), bins - 1)
            out[b] += c
        }
        let peak = out.max() ?? 0
        return peak > 0 ? out.map { $0 / peak } : out
    }

    /// The share (0…1, summing to 1) of the photo each band reads: the
    /// cells whose compensated mask value is nearest that band's stop
    /// (`ToneEqualizer.band(atMaskEV:)`, so tones past either end count
    /// for the end band, whose gain they get). Nine zeros when empty.
    public func bandShares(equalizer: ToneEqualizer, exposureEV: Float) -> [Float] {
        var shares = [Float](repeating: 0, count: ToneEqualizer.bandCount)
        guard !isEmpty else { return shares }
        for (i, c) in counts.enumerated() where c > 0 {
            shares[ToneEqualizer.band(atMaskEV: equalizer.compensated(Self.centre(i) + exposureEV))] += c
        }
        return shares.map { $0 / total }
    }
}

extension ToneEqualizer {
    /// The percentiles Auto Align treats as the photo's darkest and
    /// brightest tones: the 1st and 99th, so a few specular highlights or a
    /// black border don't decide the alignment.
    public static let autoAlignFractions: (low: Float, high: Float) = (0.01, 0.99)

    /// What Auto Align sets: the mask exposure and contrast compensation
    /// that put the photo's darkest tones (`low`, before compensation) on
    /// the −8 EV band and its brightest (`high`) on the 0 EV band, so the
    /// nine bands span exactly the photo's tonal range and each one has a
    /// part of the photo to move.
    ///
    /// Where Fit Mask (`fittedCompensation`) leaves half a stop inside the
    /// outer bands for the middle 90 %, this reaches the outer stops with
    /// the 1st to 99th percentile. The contrast is clamped to
    /// `maskContrastRange` and the exposure to `maskExposureRange`; with
    /// either clamped, the photo's middle still lands on −4 EV, the middle
    /// band, as nearly as the exposure range allows.
    public static func autoAlignedCompensation(low: Float, high: Float) -> (exposure: Float, contrast: Float) {
        guard low.isFinite, high.isFinite else { return (0, 0) }
        let span = zones[bandCount - 1] - zones[0]   // 8 EV, band centre to band centre
        let spread = max(high - low, 0.25)
        let contrast = min(max(log2(span / spread), maskContrastRange.lowerBound), maskContrastRange.upperBound)
        // Contrast pivots on −4 EV, the middle of the zones, so aiming the
        // photo's centre at the pivot spreads it evenly both ways.
        let centre = (low + high) / 2
        let exposure = min(max(contrastPivot - centre, maskExposureRange.lowerBound), maskExposureRange.upperBound)
        return (exposure, contrast)
    }

    /// Auto Align from a mask's statistics: nil when there is no mask yet.
    public static func autoAlignedCompensation(stats: ToneEqualizerMaskStats,
                                               exposureEV: Float) -> (exposure: Float, contrast: Float)? {
        guard let low = stats.percentile(autoAlignFractions.low, exposureEV: exposureEV),
              let high = stats.percentile(autoAlignFractions.high, exposureEV: exposureEV) else { return nil }
        return autoAlignedCompensation(low: low, high: high)
    }

    /// This equalizer with its mask compensation set, a value within half a
    /// hundredth of 0 stored as absent (the module's "neutral is absent"
    /// rule), bands and the other mask settings untouched.
    public func withCompensation(exposure: Float, contrast: Float) -> ToneEqualizer {
        var eq = self
        eq.maskExposure = abs(exposure) < 0.005 ? nil : exposure
        eq.maskContrast = abs(contrast) < 0.005 ? nil : contrast
        return eq
    }
}
