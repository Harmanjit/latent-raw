import Foundation

/// Highlights, Shadows, Whites and Blacks: brightness changes aimed at one
/// band of tones each, −1…1 (DESIGN.md §8.1 stage 9, just ahead of the tone
/// map).
///
/// Not to be confused with highlight *recovery* (`EditStack.Highlights`),
/// which neutralises clipped channels in camera space. These sliders move
/// tones; recovery repairs colour.
///
/// How they work, and why this way:
///
/// - **Where a pixel sits** is judged from its luminance on the log scale
///   the sigmoid works on, t = contrast × log2(Y / mid grey). The SDR tone
///   map's output depends on nothing else, so a band means the same part of
///   the picture whatever the contrast and grey point are, and on an HDR
///   screen the bands stay where the export puts them.
/// - **What moves** is exposure, per pixel: the pixel is multiplied by a
///   gain before the tone map. All three channels scale together, so hue is
///   kept, and a pure black stays black. The gain depends on the pixel's own
///   luminance only (no blur, no neighbourhood), so there are no halos; it
///   is a global tone curve, not local contrast.
/// - **Tones never reverse.** Each slider on its own shifts t by
///   `amount × reach × weight(t)`, with the weight's slope limited so no
///   tone can overtake a brighter one (`maximumSlope`). The four are then
///   applied one after another, each looking at the result of the last, and
///   a chain of order-keeping steps keeps order, whatever the combination.
/// - **Zero is exactly nothing.** The render skips the step when all four
///   are zero, so an untouched edit renders bit for bit as before.
///
/// Mid grey (t = 0) is outside every band, so none of the four moves it.
public struct ToneRanges: Equatable, Sendable, Codable {
    public var highlights: Float
    public var shadows: Float
    public var whites: Float
    public var blacks: Float

    public init(highlights: Float = 0, shadows: Float = 0, whites: Float = 0, blacks: Float = 0) {
        self.highlights = highlights; self.shadows = shadows
        self.whites = whites; self.blacks = blacks
    }

    public static let neutral = ToneRanges()
    public var isNeutral: Bool { self == .neutral }

    /// Lenient: a missing slider is zero, so a partial block still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try c.decodeIfPresent(Float.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Float.self, forKey: .shadows) ?? 0
        whites = try c.decodeIfPresent(Float.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Float.self, forKey: .blacks) ?? 0
    }

    // MARK: - The bands

    /// One slider's band: how far (in units of t) a full ±1 moves a tone,
    /// and how much of that each tone gets.
    struct Band: Sendable {
        let reach: Float
        let weight: @Sendable (Float) -> Float
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// For reference, the default SDR render puts t = −6, −3, 0, 3, 6 at
    /// about 15%, 37%, 73%, 95% and 99% of the gamma-2.2 display scale. The
    /// far ends of t are squeezed together on screen, which is why Whites
    /// and Blacks reach further than Highlights and Shadows.
    ///
    /// Each weight rises or falls over at least 1.5 × reach / 0.9 units of
    /// t (a smoothstep's steepest slope is 1.5 / width), which is what keeps
    /// every band's own slope under `maximumSlope`.
    static let shadowsBand = Band(reach: 1.6) { t in
        smoothstep(-9, -3.3, t) * (1 - smoothstep(-3.3, 0, t))
    }
    static let highlightsBand = Band(reach: 1.9) { t in
        smoothstep(0, 3.3, t) * (1 - smoothstep(3.3, 9, t))
    }
    static let blacksBand = Band(reach: 3) { t in 1 - smoothstep(-10, -3.5, t) }
    static let whitesBand = Band(reach: 4) { t in smoothstep(2, 9, t) }

    /// The steepest any single band's shift may change with t. At 1, a
    /// slider at full strength would merge neighbouring tones into one;
    /// beyond it they would swap places.
    static let maximumSlope: Float = 0.9

    /// Shadows and highlights first, then the end points on their result.
    private var steps: [(amount: Float, band: Band)] {
        func clamped(_ v: Float) -> Float { v.isFinite ? min(max(v, -1), 1) : 0 }
        return [(clamped(shadows), Self.shadowsBand), (clamped(highlights), Self.highlightsBand),
                (clamped(blacks), Self.blacksBand), (clamped(whites), Self.whitesBand)]
    }

    /// Where tone `t` ends up.
    public func remap(_ t: Float) -> Float {
        var x = t
        for step in steps where step.amount != 0 {
            x += step.amount * step.band.reach * step.band.weight(x)
        }
        return x
    }

    // MARK: - For the GPU

    public static let lutSize = 256
    /// Every band is flat beyond this, so clamping to it loses nothing.
    public static let lutRange: ClosedRange<Float> = -12...12

    /// The shift `remap(t) − t` at `lutSize` evenly spaced t across
    /// `lutRange`, which the colour kernel interpolates.
    public func lookupTable() -> [Float] {
        let lo = Self.lutRange.lowerBound, span = Self.lutRange.upperBound - lo
        return (0..<Self.lutSize).map { i in
            let t = lo + span * Float(i) / Float(Self.lutSize - 1)
            return remap(t) - t
        }
    }
}
