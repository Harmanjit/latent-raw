import Foundation

/// The tone equalizer (darktable's tone equalizer, docs/wiki/Develop.md
/// "Tone Equalizer"): nine exposure bands, one stop apart, each raising or
/// lowering the parts of the picture whose *smoothed* brightness falls in
/// it. The brightness comes from an edge-aware mask (a guided filter over
/// the image's luminance in log space), so a whole sky or a whole shadowed
/// face moves together and local contrast inside it survives, which a
/// global curve cannot do.
///
/// Applied in scene-linear camera space as a gain, the same factor on all
/// three channels, so it never shifts a colour (ToneEqualizerStage.swift).
/// Stored as the optional `toneEqualizer` module of the edit stack: absent
/// while every band is at 0 and the mask settings are at their defaults,
/// so an edit that never used it encodes byte for byte as before.
public struct ToneEqualizer: Codable, Equatable, Sendable {
    /// Gains in EV, −3…+3, for the zones −8 EV (index 0) to 0 EV (index 8).
    public var bands: [Float]
    /// Mask exposure compensation, EV: slides the mask up or down the zones
    /// so the picture's tones land on the bands. Absent at 0.
    public var maskExposure: Float?
    /// Mask contrast compensation, −1…1: stretches (+) or squeezes (−) the
    /// mask about −4 EV, the middle of the zones. Absent at 0.
    public var maskContrast: Float?
    /// How far the mask is smoothed, 0…1. Absent at the default.
    public var smoothing: Float?
    /// How closely the mask follows edges, 0 (soft, little edge respect)
    /// to 1 (hugs edges tightly). Absent at the default.
    public var edgeRefinement: Float?

    public init(bands: [Float] = Array(repeating: 0, count: ToneEqualizer.bandCount),
                maskExposure: Float? = nil, maskContrast: Float? = nil,
                smoothing: Float? = nil, edgeRefinement: Float? = nil) {
        self.bands = bands
        self.maskExposure = maskExposure
        self.maskContrast = maskContrast
        self.smoothing = smoothing
        self.edgeRefinement = edgeRefinement
    }

    public static let neutral = ToneEqualizer()

    // MARK: - Constants

    public static let bandCount = 9
    /// The zone each band is centred on, in EV (0 EV is sensor white).
    public static let zones: [Float] = (0..<bandCount).map { Float($0) - 8 }
    public static let gainRange: ClosedRange<Float> = -3...3
    public static let maskExposureRange: ClosedRange<Float> = -4...4
    public static let maskContrastRange: ClosedRange<Float> = -1...1
    public static let defaultSmoothing: Float = 0.5
    public static let defaultEdgeRefinement: Float = 0.5
    /// The mask's contrast compensation pivots here, the middle of the zones.
    public static let contrastPivot: Float = -4
    /// The gain table the GPU reads: mask EV from `lutRange`, `lutCount` entries.
    public static let lutRange: ClosedRange<Float> = -10...2
    public static let lutCount = 256

    // MARK: - State

    /// Whether the stage changes the picture at all.
    public var isActive: Bool { bands.contains { $0 != 0 } }

    /// Nothing to store: every band at 0 and the mask at its defaults.
    public var isNeutral: Bool {
        !isActive && maskExposure == nil && maskContrast == nil && smoothing == nil && edgeRefinement == nil
    }

    public var exposureCompensation: Float { maskExposure ?? 0 }
    public var contrastCompensation: Float { maskContrast ?? 0 }
    public var smoothingAmount: Float { smoothing ?? Self.defaultSmoothing }
    public var edgeRefinementAmount: Float { edgeRefinement ?? Self.defaultEdgeRefinement }

    /// Values from a file clamped to what the controls allow, defaults
    /// written back as absent, so a hand-edited number can't blow up a
    /// render and a stored default doesn't make the module look used.
    public var sanitized: ToneEqualizer {
        func clamp(_ v: Float, _ r: ClosedRange<Float>, _ fallback: Float) -> Float {
            v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
        }
        func optional(_ v: Float?, _ r: ClosedRange<Float>, _ neutral: Float) -> Float? {
            guard let v else { return nil }
            let c = clamp(v, r, neutral)
            return c == neutral ? nil : c
        }
        var b = bands.prefix(Self.bandCount).map { clamp($0, Self.gainRange, 0) }
        if b.count < Self.bandCount { b += Array(repeating: 0, count: Self.bandCount - b.count) }
        return ToneEqualizer(bands: b,
                             maskExposure: optional(maskExposure, Self.maskExposureRange, 0),
                             maskContrast: optional(maskContrast, Self.maskContrastRange, 0),
                             smoothing: optional(smoothing, 0...1, Self.defaultSmoothing),
                             edgeRefinement: optional(edgeRefinement, 0...1, Self.defaultEdgeRefinement))
    }

    // MARK: - The gain curve

    /// The gain in EV at a (compensated) mask value: a monotone cubic
    /// (Fritsch–Carlson) through the nine bands, so the curve passes
    /// through every band's value, is smooth, never overshoots between two
    /// bands, gives exactly the gain everywhere when the bands are equal,
    /// and past either end holds the end band's gain.
    public func gain(atMaskEV m: Float) -> Float {
        guard isActive, m.isFinite else { return 0 }
        let n = Self.bandCount
        let y = (0..<n).map { $0 < bands.count ? bands[$0] : 0 }
        let x = min(max(m - Self.zones[0], 0), Float(n - 1))
        let k = min(Int(x), n - 2)
        let t = x - Float(k)
        // Slopes: flat at the ends (the curve carries on level), the
        // harmonic mean of the neighbouring steps inside, 0 at a peak.
        func slope(_ i: Int) -> Float {
            guard i > 0, i < n - 1 else { return 0 }
            let a = y[i] - y[i - 1], b = y[i + 1] - y[i]
            guard a * b > 0 else { return 0 }
            return 2 / (1 / a + 1 / b)
        }
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y[k] + (t3 - 2 * t2 + t) * slope(k)
            + (-2 * t3 + 3 * t2) * y[k + 1] + (t3 - t2) * slope(k + 1)
    }

    /// The gain curve sampled for the GPU (`lutCount` entries over `lutRange`).
    public func gainTable() -> [Float] {
        let lo = Self.lutRange.lowerBound, span = Self.lutRange.upperBound - lo
        return (0..<Self.lutCount).map { i in
            gain(atMaskEV: lo + span * Float(i) / Float(Self.lutCount - 1))
        }
    }

    /// A mask value (scene EV, exposure already applied) with the mask
    /// compensation applied: what the bands are read at.
    public func compensated(_ maskEV: Float) -> Float {
        (maskEV + exposureCompensation - Self.contrastPivot) * contrastFactor + Self.contrastPivot
    }

    /// The contrast compensation as the factor the mask is stretched by.
    public var contrastFactor: Float { exp2(contrastCompensation) }

    /// The band nearest a compensated mask value: the one scrolling or a
    /// targeted drag over that pixel moves.
    public static func band(atMaskEV m: Float) -> Int {
        guard m.isFinite else { return 0 }
        return min(max(Int((m - zones[0]).rounded()), 0), bandCount - 1)
    }

    /// The guided filter's regularisation, from Edge Refinement: smaller
    /// means only weaker texture is smoothed away (edges are kept).
    var epsilon: Float { exp2(2 - 8 * edgeRefinementAmount) }

    /// The mask's blur, as a fraction of the image's long side.
    var smoothingFraction: Float { 0.005 + 0.045 * smoothingAmount }

    // MARK: - Mask compensation from a histogram

    /// What "Fit Mask" sets: the exposure and contrast compensation that
    /// spread the mask's 5th to 95th percentile across the bands (−7.5 to
    /// −0.5 EV), from `low` and `high`, those percentiles before any
    /// compensation.
    public static func fittedCompensation(low: Float, high: Float) -> (exposure: Float, contrast: Float) {
        let spread = max(high - low, 0.25)
        let contrast = min(max(log2(7 / spread), maskContrastRange.lowerBound), maskContrastRange.upperBound)
        // After contrast c about the pivot, the centre lands at
        // (centre + e - pivot) * 2^c + pivot; aim it at −4 EV, the pivot.
        let centre = (low + high) / 2
        let exposure = min(max(contrastPivot - centre, maskExposureRange.lowerBound), maskExposureRange.upperBound)
        return (exposure, contrast)
    }
}

/// The tone equalizer's mask as last computed for a session: the
/// edge-aware log luminance on a small whole-image grid (the long side
/// `ToneEqualizerStage.gridLongSide` cells), for the readout under the
/// histogram, the Advanced tab's histogram and choosing the band under the
/// pointer. Values are scene EV before exposure and compensation;
/// `exposureEV` is the render's exposure (with a profile's offset).
public struct ToneEqualizerMaskSnapshot: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let values: [Float]
    public let exposureEV: Float
    /// Counts up each time the session reads a new mask back from the GPU,
    /// so the panel can tell a new mask from the same one seen again
    /// without comparing every value (`ToneEqualizerMaskStats`).
    public let generation: Int

    public init(width: Int, height: Int, values: [Float], exposureEV: Float, generation: Int = 0) {
        self.width = width; self.height = height; self.values = values; self.exposureEV = exposureEV
        self.generation = generation
    }

    /// The mask at a point given as 0…1 of the sensor, bilinear, exposure
    /// applied but not compensation; nil off the grid or when empty.
    public func maskEV(atNormalized p: SIMD2<Float>) -> Float? {
        guard width > 0, height > 0, values.count == width * height,
              p.x >= 0, p.y >= 0, p.x <= 1, p.y <= 1 else { return nil }
        let fx = min(max(p.x * Float(width) - 0.5, 0), Float(width - 1))
        let fy = min(max(p.y * Float(height) - 0.5, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty + exposureEV
    }

    /// Every cell's mask value with exposure and `equalizer`'s compensation
    /// applied: what the bands see.
    public func compensatedValues(_ equalizer: ToneEqualizer) -> [Float] {
        values.map { equalizer.compensated($0 + exposureEV) }
    }

    /// The `fraction` percentile of the mask with exposure applied but no
    /// compensation (Fit Mask's input).
    public func percentile(_ fraction: Float) -> Float? {
        percentiles([fraction])[0]
    }

    /// Several percentiles from one sort of the mask (`percentile` sorts
    /// the whole grid each time it is asked).
    public func percentiles(_ fractions: [Float]) -> [Float?] {
        valuePercentiles(fractions).map { $0.map { $0 + exposureEV } }
    }

    /// The same percentiles of `values` themselves, before exposure: they
    /// stay right while only the exposure changes, so they can be kept
    /// for as long as the mask's values are the same.
    public func valuePercentiles(_ fractions: [Float]) -> [Float?] {
        guard !values.isEmpty else { return fractions.map { _ in nil } }
        let sorted = values.sorted()
        return fractions.map { fraction in
            let i = min(max(Int(Float(sorted.count - 1) * fraction), 0), sorted.count - 1)
            return sorted[i]
        }
    }
}

// MARK: - Built-in presets

extension Preset {
    /// Range compression starting points (docs/wiki/Develop.md, "Tone
    /// Equalizer"): three tone equalizer settings, which carry nothing but
    /// the equalizer, and Compress Range, the same idea with the Tone and
    /// Presence sliders for those who prefer them.
    static var rangeCompressionBuiltIns: [Preset] {
        func equalizer(_ name: String, _ bands: [Float]) -> Preset {
            var p = EditParameters()
            p.toneEqualizer = ToneEqualizer(bands: bands)
            return Preset(name: name, groups: [.toneEqualizer], stack: EditStack(parameters: p), isBuiltIn: true)
        }
        var range = EditParameters()
        range.toneRanges.highlights = -0.4
        range.toneRanges.shadows = 0.4
        range.clarity = 0.1
        return [
            equalizer("Compress Shadows and Highlights (Soft)", [0.75, 0.6, 0.45, 0.3, 0.15, 0, -0.15, -0.3, -0.45]),
            equalizer("Compress Shadows and Highlights (Strong)", [1.5, 1.2, 0.9, 0.6, 0.3, 0, -0.3, -0.6, -0.9]),
            equalizer("Lift Shadows", [1, 0.9, 0.75, 0.5, 0.25, 0.1, 0, 0, 0]),
            Preset(name: "Compress Range", groups: [.tone, .presence], stack: EditStack(parameters: range), isBuiltIn: true),
        ]
    }
}
