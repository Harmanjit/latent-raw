import Foundation
import simd

// The finer controls of the Detail, Lens Corrections and Effects panels:
// grain, post-crop vignetting, the sharpening Detail and Masking sliders,
// the noise reduction Detail, Contrast and Smoothness sliders, the defringe
// hue ranges and the automatic chromatic aberration fit.
//
// Every one of them is off (or at its old behaviour) by default, and an
// edit that doesn't use them stores nothing for them, so an edit made
// before they existed loads and renders exactly as it did.

/// Film-like grain, added last, after sharpening and the post-crop
/// vignette (Shaders/DetailEffects.metal).
///
/// The grain is a pattern fixed to the image's own pixels and seeded per
/// image, so the preview, a 100 % tile and the export all show the same
/// grains in the same places, and two photos never share a pattern.
public struct Grain: Equatable, Sendable, Codable {
    /// 0 (off) … 1. How strong the grain is.
    public var amount: Float
    /// 0 … 1. How big each grain is, relative to the picture's size.
    public var size: Float
    /// 0 … 1. 0 is smooth, even grain; 1 mixes in finer, clumpier grain.
    public var roughness: Float

    public init(amount: Float = 0, size: Float = 0.25, roughness: Float = 0.5) {
        self.amount = amount; self.size = size; self.roughness = roughness
    }

    public static let off = Grain()
    public var isActive: Bool { amount > 0 }

    /// Lenient: a missing value takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 0
        size = try c.decodeIfPresent(Float.self, forKey: .size) ?? 0.25
        roughness = try c.decodeIfPresent(Float.self, forKey: .roughness) ?? 0.5
    }

    /// Values from a file, clamped to what the sliders allow.
    public var sanitized: Grain {
        Grain(amount: amount.detailClamped(0, 1), size: size.detailClamped(0, 1), roughness: roughness.detailClamped(0, 1))
    }

    /// The width of one grain in sensor pixels. Relative to the short side
    /// so a grain setting looks the same on a 12 and a 60 megapixel file:
    /// at the default size a 4000-pixel-high frame gets grains of about 3
    /// pixels, which reads as 35 mm film at full size.
    public func cellSensorPixels(shortSide: Float) -> Float {
        max(0.5, shortSide / 2000) * (0.8 + 3.2 * size.detailClamped(0, 1))
    }

    /// A seed for this image's pattern, from things the raw file records
    /// about itself, so the same file always gets the same grain.
    public static func seed(cameraModel: String, captureTime: Double, width: Int, height: Int) -> UInt32 {
        var hash: UInt32 = 2_166_136_261                     // FNV-1a
        func mix(_ bytes: [UInt8]) {
            for b in bytes { hash = (hash ^ UInt32(b)) &* 16_777_619 }
        }
        mix(Array(cameraModel.utf8))
        mix(withUnsafeBytes(of: captureTime.bitPattern.littleEndian, Array.init))
        mix(withUnsafeBytes(of: Int64(width).littleEndian, Array.init))
        mix(withUnsafeBytes(of: Int64(height).littleEndian, Array.init))
        return hash
    }
}

/// Vignetting placed on the cropped picture rather than on the lens: it
/// follows the crop's centre, size and angle, so it always frames what is
/// exported.
public struct PostCropVignette: Equatable, Sendable, Codable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// Works like exposure in linear light. Darkening holds back on
        /// bright areas (by `highlights`), and brightening rolls off
        /// towards white per channel, so bright colours may shift slightly.
        case highlightPriority
        /// Changes brightness only, keeping every pixel's hue and
        /// saturation; brightening stops before any channel clips.
        case colourPriority

        public var displayName: String {
            switch self {
            case .highlightPriority: return "Highlight Priority"
            case .colourPriority: return "Colour Priority"
            }
        }
    }

    public var style: Style
    /// −1 (darken the edges) … +1 (lighten them). 0 is off.
    public var amount: Float
    /// 0 … 1: how far in from the corners the effect reaches. Lower
    /// reaches closer to the centre.
    public var midpoint: Float
    /// −1 (follows the crop's rectangle) … 0 (an oval fitting the crop) …
    /// +1 (a circle).
    public var roundness: Float
    /// 0 (a hard edge) … 1 (a very soft one).
    public var feather: Float
    /// 0 … 1: how much bright areas keep their brightness when darkening.
    public var highlights: Float

    public init(style: Style = .highlightPriority, amount: Float = 0, midpoint: Float = 0.5,
                roundness: Float = 0, feather: Float = 0.5, highlights: Float = 0) {
        self.style = style; self.amount = amount; self.midpoint = midpoint
        self.roundness = roundness; self.feather = feather; self.highlights = highlights
    }

    public static let off = PostCropVignette()
    public var isActive: Bool { amount != 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? .highlightPriority
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 0
        midpoint = try c.decodeIfPresent(Float.self, forKey: .midpoint) ?? 0.5
        roundness = try c.decodeIfPresent(Float.self, forKey: .roundness) ?? 0
        feather = try c.decodeIfPresent(Float.self, forKey: .feather) ?? 0.5
        highlights = try c.decodeIfPresent(Float.self, forKey: .highlights) ?? 0
    }

    public var sanitized: PostCropVignette {
        PostCropVignette(style: style, amount: amount.detailClamped(-1, 1), midpoint: midpoint.detailClamped(0, 1),
                         roundness: roundness.detailClamped(-1, 1), feather: feather.detailClamped(0, 1),
                         highlights: highlights.detailClamped(0, 1))
    }

    /// The vignette's strength (0 at the centre, 1 at full effect) at a
    /// point given in crop-frame coordinates, where the crop spans −1…1 on
    /// both axes and `aspect` is its width over its height. A Swift twin
    /// of `dfxVignetteMask` in DetailEffects.metal, for tests.
    public func mask(atCropPoint u: SIMD2<Float>, aspect: Float) -> Float {
        let d = Self.distance(u, aspect: aspect, roundness: roundness)
        let (lo, hi) = Self.edges(midpoint: midpoint, feather: feather)
        return Self.smoothstep(lo, hi, d)
    }

    /// The shape: an oval through the crop's corners at roundness 0, a
    /// squarer superellipse below it, a circle at +1. Scaled so the
    /// corners sit at about 1.41 whatever the shape.
    static func distance(_ u: SIMD2<Float>, aspect: Float, roundness r: Float) -> Float {
        var p = u
        if r > 0 {
            // Towards a circle: measure both axes in the same pixels,
            // normalised by the crop's mean half-extent.
            let a = max(aspect, 1e-3)
            let norm = ((a * a + 1) / 2).squareRoot()
            let circle = SIMD2<Float>(u.x * a, u.y) / norm
            p = u + (circle - u) * r
        }
        let n: Float = r < 0 ? 2 + 6 * (-r) : 2
        let ax = abs(p.x), ay = abs(p.y)
        let d = pow(pow(ax, n) + pow(ay, n), 1 / n)
        // A superellipse's corner sits at 2^(1/n); bring it to √2.
        return d * pow(2, 0.5 - 1 / n)
    }

    /// Where the falloff starts and ends, in the same units.
    static func edges(midpoint: Float, feather: Float) -> (Float, Float) {
        let centre: Float = 0.45 + 0.95 * midpoint
        let width = max(0.02, 1.4 * feather)
        return (centre - width / 2, centre + width / 2)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = ((x - a) / (b - a)).detailClamped(0, 1)
        return t * t * (3 - 2 * t)
    }
}

/// The sharpening Detail and Masking sliders.
public enum SharpenRefinement {
    /// Detail's neutral value: plain unsharp masking, as before.
    public static let neutralDetail: Float = 1
    /// Masking's neutral value: every pixel is sharpened.
    public static let neutralMasking: Float = 0
}

/// Noise reduction's finer sliders. At the defaults the filter is exactly
/// the one Latent always had.
public struct NoiseReductionDetail: Hashable, Sendable, Codable {
    /// 0 … 1, default 0.5. Higher keeps more fine luminance detail by
    /// tightening the filter's idea of "same surface".
    public var luminanceDetail: Float
    /// 0 … 1, default 0. Puts back some of the larger-scale contrast the
    /// luminance filter flattened.
    public var luminanceContrast: Float
    /// 0 … 1, default 0.5. Higher keeps thin colour edges; lower cleans
    /// colour noise harder.
    public var colourDetail: Float
    /// 0 … 1, default 0. Evens out larger blotches of colour (mottling)
    /// that the main filter is too small to reach.
    public var colourSmoothness: Float

    public init(luminanceDetail: Float = 0.5, luminanceContrast: Float = 0,
                colourDetail: Float = 0.5, colourSmoothness: Float = 0) {
        self.luminanceDetail = luminanceDetail; self.luminanceContrast = luminanceContrast
        self.colourDetail = colourDetail; self.colourSmoothness = colourSmoothness
    }

    public static let neutral = NoiseReductionDetail()
    public var isNeutral: Bool { self == .neutral }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        luminanceDetail = try c.decodeIfPresent(Float.self, forKey: .luminanceDetail) ?? 0.5
        luminanceContrast = try c.decodeIfPresent(Float.self, forKey: .luminanceContrast) ?? 0
        colourDetail = try c.decodeIfPresent(Float.self, forKey: .colourDetail) ?? 0.5
        colourSmoothness = try c.decodeIfPresent(Float.self, forKey: .colourSmoothness) ?? 0
    }

    public var sanitized: NoiseReductionDetail {
        NoiseReductionDetail(luminanceDetail: luminanceDetail.detailClamped(0, 1),
                             luminanceContrast: luminanceContrast.detailClamped(0, 1),
                             colourDetail: colourDetail.detailClamped(0, 1),
                             colourSmoothness: colourSmoothness.detailClamped(0, 1))
    }

    /// Multiplier on the bilateral filter's luminance tolerance: 1 at the
    /// default (exactly, so the default renders as before), 2× wider at
    /// 0, a quarter at 1.
    public var luminanceToleranceScale: Float { Self.toleranceScale(luminanceDetail) }
    public var colourToleranceScale: Float { Self.toleranceScale(colourDetail) }

    static func toleranceScale(_ detail: Float) -> Float {
        detail == 0.5 ? 1 : Float(pow(4.0, Double(0.5 - detail.detailClamped(0, 1))))
    }

    /// Whether the second pass (contrast and smoothness) has work to do.
    public var wantsRefinePass: Bool { luminanceContrast > 0 || colourSmoothness > 0 }
}

/// Which hues defringe treats as purple and green fringing, in degrees.
public struct DefringeHueRanges: Equatable, Sendable, Codable {
    public var purpleLow: Float, purpleHigh: Float
    public var greenLow: Float, greenHigh: Float

    public init(purpleLow: Float = 252, purpleHigh: Float = 331.2,
                greenLow: Float = 79.2, greenHigh: Float = 158.4) {
        self.purpleLow = purpleLow; self.purpleHigh = purpleHigh
        self.greenLow = greenLow; self.greenHigh = greenHigh
    }

    /// The bands defringe always used: 0.70–0.92 and 0.22–0.44 turns.
    public static let standard = DefringeHueRanges()
    public var isStandard: Bool { self == .standard }

    /// Where each range may sit, and how narrow it may get.
    public static let purpleLimits: ClosedRange<Float> = 180...360
    public static let greenLimits: ClosedRange<Float> = 30...210
    public static let minimumWidth: Float = 10

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = DefringeHueRanges.standard
        purpleLow = try c.decodeIfPresent(Float.self, forKey: .purpleLow) ?? s.purpleLow
        purpleHigh = try c.decodeIfPresent(Float.self, forKey: .purpleHigh) ?? s.purpleHigh
        greenLow = try c.decodeIfPresent(Float.self, forKey: .greenLow) ?? s.greenLow
        greenHigh = try c.decodeIfPresent(Float.self, forKey: .greenHigh) ?? s.greenHigh
    }

    /// Each range inside its limits, low below high, at least
    /// `minimumWidth` wide.
    public var sanitized: DefringeHueRanges {
        func fix(_ lo: Float, _ hi: Float, _ limits: ClosedRange<Float>) -> (Float, Float) {
            var a = min(lo, hi).detailClamped(limits.lowerBound, limits.upperBound)
            var b = max(lo, hi).detailClamped(limits.lowerBound, limits.upperBound)
            if b - a < Self.minimumWidth {
                let mid = (a + b) / 2
                a = (mid - Self.minimumWidth / 2).detailClamped(limits.lowerBound, limits.upperBound - Self.minimumWidth)
                b = a + Self.minimumWidth
            }
            return (a, b)
        }
        let p = fix(purpleLow, purpleHigh, Self.purpleLimits)
        let g = fix(greenLow, greenHigh, Self.greenLimits)
        return DefringeHueRanges(purpleLow: p.0, purpleHigh: p.1, greenLow: g.0, greenHigh: g.1)
    }

    /// The ranges in turns, as the shader wants them: purple low, high,
    /// green low, high. The standard ranges give exactly the constants the
    /// shader always had, so an untouched edit renders bit for bit as
    /// before.
    public var turns: SIMD4<Float> {
        if isStandard { return SIMD4(0.70, 0.92, 0.22, 0.44) }
        return SIMD4(purpleLow, purpleHigh, greenLow, greenHigh) / 360
    }

    /// Which range a picked fringe colour belongs to.
    public enum Band: Equatable, Sendable { case purple, green }

    /// The ranges re-centred on `hue` (degrees) by the eyedropper, keeping
    /// the band's width: green for yellow-green to cyan, purple for
    /// everything else. Returns the band it moved.
    public func picking(hue: Float) -> (ranges: DefringeHueRanges, band: Band) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        var result = self
        if h >= 60 && h < 200 {
            let half = max(greenHigh - greenLow, Self.minimumWidth) / 2
            let centre = h.detailClamped(Self.greenLimits.lowerBound + half, Self.greenLimits.upperBound - half)
            result.greenLow = centre - half; result.greenHigh = centre + half
            return (result.sanitized, .green)
        }
        // Reds just past 0° are purple's neighbours at 360°.
        let wrapped = h < 60 ? 360 : h
        let half = max(purpleHigh - purpleLow, Self.minimumWidth) / 2
        let centre = wrapped.detailClamped(Self.purpleLimits.lowerBound + half, Self.purpleLimits.upperBound - half)
        result.purpleLow = centre - half; result.purpleHigh = centre + half
        return (result.sanitized, .purple)
    }
}

/// Profile-free lateral chromatic aberration removal: how much larger the
/// red and blue images are than the green one, measured on the photo
/// itself (`ChromaticAberrationEstimator`) and stored in the edit, so the
/// correction never changes once made.
public struct AutoChromaticAberration: Equatable, Sendable, Codable {
    /// Radial scale of red and blue relative to green, minus 1: a red
    /// image 0.05 % larger than green is 0.0005.
    public var red: Float
    public var blue: Float

    public init(red: Float, blue: Float) { self.red = red; self.blue = blue }

    /// The most a lens plausibly needs, either way; anything beyond is a
    /// mismeasurement, or a hand-edited file.
    public static let limit: Float = 0.004

    public var sanitized: AutoChromaticAberration {
        AutoChromaticAberration(red: red.isFinite ? red.detailClamped(-Self.limit, Self.limit) : 0,
                                blue: blue.isFinite ? blue.detailClamped(-Self.limit, Self.limit) : 0)
    }
}

/// Manual lens vignetting's Midpoint slider: 0.5 is the old falloff.
public enum ManualVignettingShape {
    public static let neutralMidpoint: Float = 0.5

    /// The power of the radius the brightening follows: 2 at the default
    /// midpoint (the old r²), up to 8 (corners only) at 1, down to 0.5
    /// (reaching well into the frame) at 0.
    public static func exponent(midpoint: Float) -> Float {
        midpoint == neutralMidpoint ? 2 : 2 * Float(pow(4.0, Double(2 * midpoint.detailClamped(0, 1) - 1)))
    }
}

extension Float {
    /// Clamped to lo…hi; NaN becomes lo.
    func detailClamped(_ lo: Float, _ hi: Float) -> Float { isNaN ? lo : Swift.min(Swift.max(self, lo), hi) }
}
