import Foundation
import simd

/// The Tone Curve's region mode, Lightroom's parametric curve: four
/// sliders (Shadows, Darks, Lights, Highlights) that each bend one stretch
/// of the tonal range, divided by three movable split points.
///
/// It is applied first and the point curve after it, so the two modes
/// stack the way they do in Lightroom: a parametric lift of the darks,
/// then any points on top. Neutral (all four sliders at zero) is skipped
/// entirely, so an edit that never used it renders exactly as before.
///
/// How a slider bends its region: the curve is built as a handful of
/// anchor points (each region's centre, the splits, the two ends) and
/// drawn through them with the same monotone spline as the point curve.
/// A region's centre moves up or down by its slider times half the
/// region's width; a split moves by the average of its two neighbours,
/// halved, so adjacent regions blend instead of meeting at a corner. The
/// ends stay pinned at black and white, and the anchors are kept in order,
/// so the curve can flatten but never reverse tones.
public struct ParametricCurve: Codable, Equatable, Sendable {
    /// −1…1 each.
    public var shadows: Float
    public var darks: Float
    public var lights: Float
    public var highlights: Float
    /// The three split points on the input axis, in order: between
    /// Shadows and Darks, Darks and Lights, Lights and Highlights.
    public var shadowSplit: Float
    public var midSplit: Float
    public var highlightSplit: Float

    public static let defaultSplits: SIMD3<Float> = [0.25, 0.5, 0.75]
    /// The closest two splits (or a split and an end) may come.
    public static let minimumGap: Float = 0.05

    public static let neutral = ParametricCurve()

    public init(shadows: Float = 0, darks: Float = 0, lights: Float = 0, highlights: Float = 0,
                shadowSplit: Float = ParametricCurve.defaultSplits.x,
                midSplit: Float = ParametricCurve.defaultSplits.y,
                highlightSplit: Float = ParametricCurve.defaultSplits.z) {
        self.shadows = shadows; self.darks = darks; self.lights = lights; self.highlights = highlights
        self.shadowSplit = shadowSplit; self.midSplit = midSplit; self.highlightSplit = highlightSplit
    }

    /// No slider moved. The splits alone change nothing, so they don't count.
    public var isNeutral: Bool { shadows == 0 && darks == 0 && lights == 0 && highlights == 0 }

    /// The four amounts in input order (Shadows first).
    public var amounts: [Float] {
        get { [shadows, darks, lights, highlights] }
        set {
            guard newValue.count == 4 else { return }
            shadows = newValue[0]; darks = newValue[1]; lights = newValue[2]; highlights = newValue[3]
        }
    }

    public var splits: SIMD3<Float> {
        get { SIMD3(shadowSplit, midSplit, highlightSplit) }
        set { shadowSplit = newValue.x; midSplit = newValue.y; highlightSplit = newValue.z }
    }

    public enum Region: Int, CaseIterable, Sendable {
        case shadows, darks, lights, highlights
        public var title: String {
            switch self {
            case .shadows: return "Shadows"
            case .darks: return "Darks"
            case .lights: return "Lights"
            case .highlights: return "Highlights"
            }
        }
    }

    /// Which region an input tone (0…1) falls in, by the splits.
    public func region(containing x: Float) -> Region {
        let s = sanitized.splits
        if x < s.x { return .shadows }
        if x < s.y { return .darks }
        if x < s.z { return .lights }
        return .highlights
    }

    /// Moves one split, keeping it between its neighbours.
    public mutating func setSplit(_ index: Int, to value: Float) {
        var s = splits
        let lower = index == 0 ? Self.minimumGap : s[index - 1] + Self.minimumGap
        let upper = index == 2 ? 1 - Self.minimumGap : s[index + 1] - Self.minimumGap
        guard lower <= upper else { return }
        s[index] = min(max(value, lower), upper)
        splits = s
    }

    /// Amounts clamped to −1…1 and splits put in order with room between,
    /// so a hand-edited sidecar can't build a curve that folds back.
    public var sanitized: ParametricCurve {
        func amount(_ v: Float) -> Float { v.isFinite ? min(max(v, -1), 1) : 0 }
        var c = self
        c.shadows = amount(shadows); c.darks = amount(darks)
        c.lights = amount(lights); c.highlights = amount(highlights)
        var s = [shadowSplit, midSplit, highlightSplit].map { $0.isFinite ? $0 : 0.5 }.sorted()
        let gap = Self.minimumGap
        s[0] = min(max(s[0], gap), 1 - 3 * gap)
        s[1] = min(max(s[1], s[0] + gap), 1 - 2 * gap)
        s[2] = min(max(s[2], s[1] + gap), 1 - gap)
        c.splits = SIMD3(s[0], s[1], s[2])
        return c
    }

    /// The anchor points the curve is drawn through.
    func anchors() -> [SIMD2<Float>] {
        let c = sanitized
        let edges: [Float] = [0, c.shadowSplit, c.midSplit, c.highlightSplit, 1]
        let a = c.amounts
        // Each region's centre moves by its amount times half its width.
        var centreShift = [Float](repeating: 0, count: 4)
        for i in 0..<4 { centreShift[i] = a[i] * 0.5 * (edges[i + 1] - edges[i]) }
        var points: [SIMD2<Float>] = [SIMD2(0, 0)]
        for i in 0..<4 {
            let centre = (edges[i] + edges[i + 1]) / 2
            points.append(SIMD2(centre, centre + centreShift[i]))
            if i < 3 {
                let split = edges[i + 1]
                points.append(SIMD2(split, split + (centreShift[i] + centreShift[i + 1]) / 4))
            }
        }
        points.append(SIMD2(1, 1))
        // In range and in order: a strong negative Shadows flattens the
        // bottom to black rather than dipping below it.
        var floor: Float = 0
        for i in points.indices {
            let y = min(max(points[i].y, floor), 1)
            points[i].y = y
            floor = y
        }
        return points
    }

    /// The curve sampled at `ToneCurve.lutSize` evenly spaced inputs.
    public func lookupTable() -> [Float] {
        guard !isNeutral else { return ToneCurve.identity.lookupTable() }
        var lut = ToneCurve(points: anchors()).lookupTable()
        // The spline is monotone between ordered anchors; this only guards
        // float rounding at flat stretches.
        for i in 1..<lut.count { lut[i] = max(lut[i], lut[i - 1]) }
        return lut
    }

    // Lenient decoding: a missing key keeps its default.
    private enum CodingKeys: String, CodingKey {
        case shadows, darks, lights, highlights, shadowSplit, midSplit, highlightSplit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaultSplits
        self.init(shadows: try c.decodeIfPresent(Float.self, forKey: .shadows) ?? 0,
                  darks: try c.decodeIfPresent(Float.self, forKey: .darks) ?? 0,
                  lights: try c.decodeIfPresent(Float.self, forKey: .lights) ?? 0,
                  highlights: try c.decodeIfPresent(Float.self, forKey: .highlights) ?? 0,
                  shadowSplit: try c.decodeIfPresent(Float.self, forKey: .shadowSplit) ?? d.x,
                  midSplit: try c.decodeIfPresent(Float.self, forKey: .midSplit) ?? d.y,
                  highlightSplit: try c.decodeIfPresent(Float.self, forKey: .highlightSplit) ?? d.z)
    }
}

extension ToneCurve {
    /// Lightroom's three point-curve starting points.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case linear, mediumContrast, strongContrast

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .linear: return "Linear"
            case .mediumContrast: return "Medium Contrast"
            case .strongContrast: return "Strong Contrast"
            }
        }

        /// Lightroom's point values (0…255 in its panel), as fractions.
        public var curve: ToneCurve {
            func c(_ pts: [(Float, Float)]) -> ToneCurve {
                ToneCurve(points: pts.map { SIMD2($0.0 / 255, $0.1 / 255) })
            }
            switch self {
            case .linear: return .identity
            case .mediumContrast: return c([(0, 0), (32, 22), (64, 56), (128, 128), (192, 196), (255, 255)])
            case .strongContrast: return c([(0, 0), (32, 16), (64, 50), (128, 128), (192, 202), (255, 255)])
            }
        }

        /// The preset a curve is exactly, if any.
        public static func matching(_ curve: ToneCurve) -> Preset? {
            allCases.first { $0.curve == curve }
        }
    }

    /// The table the colour kernel's master curve uses: the parametric
    /// curve first, then this point curve. With a neutral parametric curve
    /// it is this curve's own table, value for value.
    public func masterLookupTable(parametric: ParametricCurve) -> [Float] {
        let points = lookupTable()
        guard !parametric.isNeutral else { return points }
        return parametric.lookupTable().map { Self.sample(points, at: $0) }
    }

    /// Linear interpolation into a `lutSize` table, as the kernel does.
    public static func sample(_ lut: [Float], at x: Float) -> Float {
        let n = lut.count
        guard n > 1 else { return x }
        let f = min(max(x, 0), 1) * Float(n - 1)
        let i = min(Int(f), n - 2)
        return lut[i] + (lut[i + 1] - lut[i]) * (f - Float(i))
    }

    /// The input that a monotone table maps to `y`: the middle of the
    /// stretch that reaches it, so a flat run (crushed blacks) answers its
    /// centre. Used to find which tone the pointer is over before the
    /// curve moved it.
    public static func inverse(_ lut: [Float], at y: Float) -> Float {
        let n = lut.count
        guard n > 1 else { return y }
        if y <= lut[0] { return 0 }
        if y >= lut[n - 1] { return 1 }
        var lo = -1, hi = -1
        for i in 0..<(n - 1) {
            let a = lut[i], b = lut[i + 1]
            guard min(a, b) <= y, y <= max(a, b) else { continue }
            let t = b == a ? 0.5 : (y - a) / (b - a)
            if lo < 0 { lo = i }
            hi = i
            if b != a, lo == hi { return (Float(i) + t) / Float(n - 1) }
        }
        guard lo >= 0 else { return y }
        return (Float(lo) + Float(hi + 1)) / 2 / Float(n - 1)
    }
}
