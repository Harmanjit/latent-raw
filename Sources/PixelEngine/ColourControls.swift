import Foundation
import simd
import ColorKit

// The colour controls added beside Vibrance, HSL and Split Toning: a global
// Saturation slider, the Color / Black & White treatment with its per-colour
// grey mix, three-way Colour Grading (midtones, a global wheel, luminance per
// range and Blending), Calibration and Point Colour.
//
// Every one is off by default and stored in its own optional edit-stack
// module, absent while neutral, so an edit that never touched them encodes
// and renders exactly as it did before they existed. The shader runs none
// of their arithmetic while they are off (`ColourControls.gpuFlags` is 0).

/// One colour wheel of Colour Grading: a tint (hue in degrees, strength
/// 0...1) and a brightness shift (-1...1) for its range of tones.
public struct GradingWheel: Equatable, Sendable, Codable {
    public var hue: Float
    public var saturation: Float
    public var luminance: Float

    public init(hue: Float, saturation: Float = 0, luminance: Float = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    public var isNeutral: Bool { saturation == 0 && luminance == 0 }

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    /// Lenient, like the lens block: a missing key keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Float.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation) ?? 0
        luminance = try c.decodeIfPresent(Float.self, forKey: .luminance) ?? 0
    }

    /// Values a hand-edited file could break the shader with, brought
    /// back into range.
    var sanitized: GradingWheel {
        GradingWheel(hue: finite(hue, 0).truncatingRemainder(dividingBy: 360).wrappedDegrees,
                     saturation: clamped(saturation, 0...1),
                     luminance: clamped(luminance, -1...1))
    }
}

/// What Colour Grading adds to the shadow and highlight tints of
/// `SplitToning` (which keeps their hue, saturation and Balance, so a
/// split-toning edit made before this existed reads and renders as it
/// always did): the midtone and global wheels, a luminance for shadows and
/// highlights, and Blending, how far the three ranges overlap.
public struct ColourGrading: Equatable, Sendable, Codable {
    public var midtones: GradingWheel
    public var global: GradingWheel
    public var shadowLuminance: Float
    public var highlightLuminance: Float
    /// 0 (hard edges between shadows, midtones and highlights) ... 1 (each
    /// reaches well into the others). 0.5 is the overlap Split Toning
    /// always had.
    public var blending: Float

    public static let defaultBlending: Float = 0.5

    public static let neutral = ColourGrading(midtones: GradingWheel(hue: 30), global: GradingWheel(hue: 30),
                                              shadowLuminance: 0, highlightLuminance: 0,
                                              blending: defaultBlending)

    public init(midtones: GradingWheel, global: GradingWheel, shadowLuminance: Float,
                highlightLuminance: Float, blending: Float) {
        self.midtones = midtones; self.global = global
        self.shadowLuminance = shadowLuminance; self.highlightLuminance = highlightLuminance
        self.blending = blending
    }

    /// Nothing beyond what Split Toning already does. The hues alone don't
    /// count: a wheel with no strength tints nothing.
    public var isNeutral: Bool {
        midtones.isNeutral && global.isNeutral && shadowLuminance == 0 && highlightLuminance == 0
            && blending == Self.defaultBlending
    }

    private enum CodingKeys: String, CodingKey {
        case midtones, global, shadowLuminance, highlightLuminance, blending
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        midtones = try c.decodeIfPresent(GradingWheel.self, forKey: .midtones) ?? Self.neutral.midtones
        global = try c.decodeIfPresent(GradingWheel.self, forKey: .global) ?? Self.neutral.global
        shadowLuminance = try c.decodeIfPresent(Float.self, forKey: .shadowLuminance) ?? 0
        highlightLuminance = try c.decodeIfPresent(Float.self, forKey: .highlightLuminance) ?? 0
        blending = try c.decodeIfPresent(Float.self, forKey: .blending) ?? Self.defaultBlending
    }

    var sanitized: ColourGrading {
        ColourGrading(midtones: midtones.sanitized, global: global.sanitized,
                      shadowLuminance: clamped(shadowLuminance, -1...1),
                      highlightLuminance: clamped(highlightLuminance, -1...1),
                      blending: clamped(blending, 0...1, fallback: Self.defaultBlending))
    }
}

/// The Color / Black & White treatment and the grey mix: how light or dark
/// each of the eight HSL colours turns in black and white, -1...1. The mix
/// is kept while the treatment is Color, as Lightroom keeps it, so
/// switching back and forth doesn't lose it.
public struct BlackAndWhite: Equatable, Sendable, Codable {
    public var enabled: Bool
    public var mix: [Float]

    public static let neutralMix = [Float](repeating: 0, count: 8)
    public static let off = BlackAndWhite(enabled: false, mix: neutralMix)

    public init(enabled: Bool, mix: [Float] = BlackAndWhite.neutralMix) {
        self.enabled = enabled; self.mix = mix
    }

    public var isNeutral: Bool { !enabled && mix == Self.neutralMix }
    public var mixIsNeutral: Bool { mix == Self.neutralMix }

    private enum CodingKeys: String, CodingKey { case enabled, mix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mix = try c.decodeIfPresent([Float].self, forKey: .mix) ?? Self.neutralMix
    }

    var sanitized: BlackAndWhite {
        let m = mix.count == 8 ? mix.map { clamped($0, -1...1) } : Self.neutralMix
        return BlackAndWhite(enabled: enabled, mix: m)
    }
}

/// Lightroom's Calibration panel: a green-magenta tint for the shadows and
/// a hue and saturation shift for each of the red, green and blue
/// primaries, all -1...1. The primaries are moved by changing the colour
/// matrix (`matrix`), so they shift every colour built from them the way a
/// different camera profile would, and white stays white.
public struct Calibration: Equatable, Sendable, Codable {
    public var shadowTint: Float
    public var redHue: Float, redSaturation: Float
    public var greenHue: Float, greenSaturation: Float
    public var blueHue: Float, blueSaturation: Float

    public static let neutral = Calibration()

    public init(shadowTint: Float = 0, redHue: Float = 0, redSaturation: Float = 0,
                greenHue: Float = 0, greenSaturation: Float = 0,
                blueHue: Float = 0, blueSaturation: Float = 0) {
        self.shadowTint = shadowTint
        self.redHue = redHue; self.redSaturation = redSaturation
        self.greenHue = greenHue; self.greenSaturation = greenSaturation
        self.blueHue = blueHue; self.blueSaturation = blueSaturation
    }

    public var isNeutral: Bool { self == .neutral }
    /// Whether the primaries move (the matrix isn't the identity).
    public var movesPrimaries: Bool {
        redHue != 0 || redSaturation != 0 || greenHue != 0 || greenSaturation != 0
            || blueHue != 0 || blueSaturation != 0
    }

    /// A slider at ±1 turns its primary this far round the hue circle.
    public static let maximumHueDegrees: Float = 30
    /// A slider at ±1 scales its primary's colourfulness by 1 ± this.
    public static let saturationReach: Float = 0.7

    private enum CodingKeys: String, CodingKey {
        case shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? 0 }
        self.init(shadowTint: try f(.shadowTint), redHue: try f(.redHue), redSaturation: try f(.redSaturation),
                  greenHue: try f(.greenHue), greenSaturation: try f(.greenSaturation),
                  blueHue: try f(.blueHue), blueSaturation: try f(.blueSaturation))
    }

    var sanitized: Calibration {
        let r: ClosedRange<Float> = -1...1
        return Calibration(shadowTint: clamped(shadowTint, r),
                           redHue: clamped(redHue, r), redSaturation: clamped(redSaturation, r),
                           greenHue: clamped(greenHue, r), greenSaturation: clamped(greenSaturation, r),
                           blueHue: clamped(blueHue, r), blueSaturation: clamped(blueSaturation, r))
    }

    /// The working-space (linear Rec.2020) matrix that moves the primaries.
    ///
    /// Each primary is split into its grey part (a third of it on every
    /// channel) and its colour part; the colour part is turned about the
    /// grey axis by the hue slider and scaled by the saturation slider.
    /// The three moved primaries then become the matrix's columns, each
    /// scaled so that equal amounts of all three still make grey: without
    /// that, turning red towards yellow would tint every neutral in the
    /// picture. Identity when no primary moves.
    public var matrix: simd_float3x3 {
        guard movesPrimaries else { return matrix_identity_float3x3 }
        let grey = SIMD3<Float>(repeating: 1.0 / 3.0)
        let axis = simd_normalize(SIMD3<Float>(1, 1, 1))
        func moved(_ primary: SIMD3<Float>, hue: Float, saturation: Float) -> SIMD3<Float> {
            let angle = hue * Self.maximumHueDegrees * .pi / 180
            let chroma = primary - grey
            // Rodrigues' rotation about the grey axis; chroma is
            // perpendicular to it, so the axis term vanishes.
            let turned = chroma * cos(angle) + simd_cross(axis, chroma) * sin(angle)
            return grey + turned * (1 + saturation * Self.saturationReach)
        }
        let t = simd_float3x3(columns: (moved(SIMD3(1, 0, 0), hue: redHue, saturation: redSaturation),
                                        moved(SIMD3(0, 1, 0), hue: greenHue, saturation: greenSaturation),
                                        moved(SIMD3(0, 0, 1), hue: blueHue, saturation: blueSaturation)))
        guard abs(t.determinant) > 1e-4 else { return matrix_identity_float3x3 }
        let weights = t.inverse * SIMD3<Float>(1, 1, 1)
        return simd_float3x3(columns: (t.columns.0 * weights.x, t.columns.1 * weights.y, t.columns.2 * weights.z))
    }
}

/// One Point Colour swatch: a colour picked from the image (hue in
/// degrees, saturation and value 0...1, in the grading stage's own
/// display-referred terms) and what to do to colours near it.
public struct PointColour: Equatable, Sendable, Codable {
    public var hue: Float
    public var saturation: Float
    public var value: Float
    /// -1...1: up to `maximumHueShiftDegrees` round the hue circle.
    public var hueShift: Float
    /// -1...1: -1 greys the colour, +1 doubles its saturation.
    public var saturationShift: Float
    /// -1...1: darker or lighter, by up to half.
    public var luminanceShift: Float
    /// 0...1: how different a colour may be from the picked one and still
    /// be changed. 0.5 by default.
    public var range: Float
    /// -1...1: below zero the colours in range are pulled together towards
    /// the picked one, above zero pushed further apart.
    public var variance: Float

    public static let maximumCount = 8
    public static let maximumHueShiftDegrees: Float = 60
    public static let defaultRange: Float = 0.5

    public init(hue: Float, saturation: Float, value: Float, hueShift: Float = 0, saturationShift: Float = 0,
                luminanceShift: Float = 0, range: Float = PointColour.defaultRange, variance: Float = 0) {
        self.hue = hue; self.saturation = saturation; self.value = value
        self.hueShift = hueShift; self.saturationShift = saturationShift; self.luminanceShift = luminanceShift
        self.range = range; self.variance = variance
    }

    /// A swatch from a picked colour, in the grading stage's 0...1 RGB.
    public init(picked rgb: SIMD3<Float>) {
        let hsv = PointColour.hsv(rgb)
        self.init(hue: hsv.x, saturation: hsv.y, value: hsv.z)
    }

    /// Whether it changes anything: a swatch only picked does nothing.
    public var isActive: Bool {
        hueShift != 0 || saturationShift != 0 || luminanceShift != 0 || variance != 0
    }

    private enum CodingKeys: String, CodingKey {
        case hue, saturation, value, hueShift, saturationShift, luminanceShift, range, variance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ d: Float = 0) throws -> Float { try c.decodeIfPresent(Float.self, forKey: k) ?? d }
        self.init(hue: try f(.hue), saturation: try f(.saturation), value: try f(.value),
                  hueShift: try f(.hueShift), saturationShift: try f(.saturationShift),
                  luminanceShift: try f(.luminanceShift), range: try f(.range, Self.defaultRange),
                  variance: try f(.variance))
    }

    var sanitized: PointColour {
        PointColour(hue: finite(hue, 0).truncatingRemainder(dividingBy: 360).wrappedDegrees,
                    saturation: clamped(saturation, 0...1), value: clamped(value, 0...1),
                    hueShift: clamped(hueShift, -1...1), saturationShift: clamped(saturationShift, -1...1),
                    luminanceShift: clamped(luminanceShift, -1...1),
                    range: clamped(range, 0...1, fallback: Self.defaultRange), variance: clamped(variance, -1...1))
    }

    /// HSV as the shader computes it (`rgbToHSV` in ColorPipeline.metal):
    /// hue in degrees, saturation and value 0...1.
    public static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == c.x { h = (c.y - c.z) / d } else if mx == c.y { h = (c.z - c.x) / d + 2 } else { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return SIMD3(h, mx > 1e-6 ? d / mx : 0, mx)
    }
}

/// All of the above, carried by `EditParameters.colour`.
public struct ColourControls: Equatable, Sendable {
    /// -1 (grey) ... +1 (twice as colourful), applied evenly to every
    /// colour, unlike Vibrance.
    public var saturation: Float = 0
    public var blackAndWhite: BlackAndWhite = .off
    public var grading: ColourGrading = .neutral
    public var calibration: Calibration = .neutral
    public var pointColours: [PointColour] = []

    public static let neutral = ColourControls()

    public init(saturation: Float = 0, blackAndWhite: BlackAndWhite = .off, grading: ColourGrading = .neutral,
                calibration: Calibration = .neutral, pointColours: [PointColour] = []) {
        self.saturation = saturation; self.blackAndWhite = blackAndWhite; self.grading = grading
        self.calibration = calibration; self.pointColours = pointColours
    }

    public var isNeutral: Bool { self == .neutral }

    /// Which parts the shader runs; 0 when none, and then it runs none of
    /// this code. Mirrors the `kExtra…` bits in ColorPipeline.metal.
    var gpuFlags: UInt32 {
        var f: UInt32 = 0
        if blackAndWhite.enabled {
            f |= Self.flagBlackAndWhite
        } else {
            // Black & White replaces the colour controls, as Lightroom's
            // treatment does: in grey, saturation means nothing.
            if saturation != 0 { f |= Self.flagSaturation }
            if pointColours.contains(where: \.isActive) { f |= Self.flagPointColour }
        }
        if !grading.isNeutral { f |= Self.flagColourGrading }
        if calibration.shadowTint != 0 { f |= Self.flagShadowTint }
        return f
    }

    static let flagSaturation: UInt32 = 1
    static let flagBlackAndWhite: UInt32 = 2
    static let flagColourGrading: UInt32 = 4
    static let flagPointColour: UInt32 = 8
    static let flagShadowTint: UInt32 = 16
}

fileprivate extension Float {
    /// Degrees brought into 0..<360.
    var wrappedDegrees: Float { self < 0 ? self + 360 : self }
}

fileprivate func finite(_ v: Float, _ fallback: Float) -> Float { v.isFinite ? v : fallback }

fileprivate func clamped(_ v: Float, _ r: ClosedRange<Float>, fallback: Float = 0) -> Float {
    v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
}
