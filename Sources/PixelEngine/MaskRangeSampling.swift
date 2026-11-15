import Foundation
import simd

// Multi-sample Pick Range (wave 4): the Luminance and Channel Range
// eyedropper can take several samples. Shift-click adds one, Option-click
// takes away the nearest, and the range becomes the smallest band that
// covers every sample. Only the resulting band is stored in the edit (in
// the range's existing low/high fields); the samples are session state
// the app keeps while the tool is in use and draws on the image.

/// One sample taken with the Pick Range eyedropper: where it was taken
/// (normalised output coordinates, for drawing it and for Option-click to
/// find it) and the span of values it asks the range to cover.
///
/// A click covers its value ± `MaskRangeSampleSet.pointPadding`, the
/// same band a single plain click has always made; a dragged rectangle
/// covers the least to the most value inside it.
public struct MaskRangeSample: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var low: Float
    public var high: Float

    public init(position: SIMD2<Float>, low: Float, high: Float) {
        self.position = position
        self.low = min(low, high)
        self.high = max(low, high)
    }

    /// A click's sample: the value with the padding either side, kept in 0…1.
    public static func point(_ value: Float, at position: SIMD2<Float>) -> MaskRangeSample {
        let pad = MaskRangeSampleSet.pointPadding
        return MaskRangeSample(position: position, low: max(value - pad, 0), high: min(value + pad, 1))
    }

    /// A rectangle's sample: exactly the least to the most value inside
    /// it; nil when there are none.
    public static func region(_ values: [Float], at position: SIMD2<Float>) -> MaskRangeSample? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return MaskRangeSample(position: position, low: lo, high: hi)
    }
}

/// The samples behind one range, and the band they make.
///
/// `base` is the band the range had when the first sample was added with
/// Shift (a range set by hand or by an earlier plain click): Shift-click
/// grows that band rather than starting over, and Option-click never
/// takes it away. A plain click starts a new set with no base.
public struct MaskRangeSampleSet: Equatable, Sendable {
    public var base: MaskRangeBand?
    public var samples: [MaskRangeSample]

    /// How far either side of a clicked value the range reaches: the ±0.1
    /// of `MaskRangeBand.around`.
    public static let pointPadding: Float = 0.1

    public init(base: MaskRangeBand? = nil, samples: [MaskRangeSample] = []) {
        self.base = base
        self.samples = samples
    }

    /// Whether there is anything to make a band from.
    public var isEmpty: Bool { base == nil && samples.isEmpty }

    /// The union: the smallest band covering the base and every sample.
    /// The fades are `current`'s, so setting them apart by hand survives
    /// more samples. Nil when the set is empty.
    public func band(keepingFeathersOf current: MaskRangeBand) -> MaskRangeBand? {
        var lows = samples.map(\.low), highs = samples.map(\.high)
        if let base { lows.append(base.low); highs.append(base.high) }
        guard let low = lows.min(), let high = highs.max() else { return nil }
        return MaskRangeBand(low: low, high: high,
                             featherLow: current.featherLow, featherHigh: current.featherHigh).sanitised()
    }

    /// The index of the sample nearest `point`, distance measured in
    /// sensor pixels (`aspect` is the sensor's width and height, so a
    /// tall or wide frame doesn't skew it). Nil when there are no samples.
    public func nearestIndex(to point: SIMD2<Float>, aspect: SIMD2<Float> = SIMD2(1, 1)) -> Int? {
        samples.indices.min { a, b in
            simd_length_squared((samples[a].position - point) * aspect)
                < simd_length_squared((samples[b].position - point) * aspect)
        }
    }

    /// Takes away the sample nearest `point` and returns it; nil (and no
    /// change) when there are none. The base stays.
    @discardableResult
    public mutating func removeNearest(to point: SIMD2<Float>, aspect: SIMD2<Float> = SIMD2(1, 1)) -> MaskRangeSample? {
        guard let i = nearestIndex(to: point, aspect: aspect) else { return nil }
        return samples.remove(at: i)
    }
}

extension ColourRange {
    /// The sample whose colour is nearest `colour` on the colour wheel
    /// (the distance the mask itself uses): Option-click with the Colour
    /// Range eyedropper takes it away when no sample positions are known.
    public func nearestSampleIndex(to colour: ColourSample) -> Int? {
        let p = colour.wheel
        return samples.indices.min { simd_distance(samples[$0].wheel, p) < simd_distance(samples[$1].wheel, p) }
    }
}
