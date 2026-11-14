import Foundation
import simd
import ColorKit

/// Calibration › Adaptation: darktable's colour calibration CAT, as an
/// extra correction after Latent's white balance.
///
/// Pick the light the scene was lit by (a CIE standard illuminant, or a
/// custom chromaticity) and a chromatic adaptation transform; colours lit
/// by that light are then carried to how they would look under D65, the
/// working space's white. With D65 chosen nothing changes. The Hue and
/// Chroma sliders fine-tune the chosen light: Hue turns it round the D65
/// white point, Chroma moves it nearer to (below zero) or further from
/// (above) that white.
///
/// The transform is a 3×3 matrix in the working space (linear Rec.2020),
/// folded into the camera matrix on the CPU (`RenderPipeline.calibrated`),
/// so the shader is unchanged. Stored as its own optional edit-stack module,
/// `adaptation`, absent while neutral: an edit that never used it encodes
/// and renders exactly as before.
public struct ChromaticAdaptation: Equatable, Sendable, Codable {
    /// How cone responses are modelled for the adaptation.
    public enum Method: String, CaseIterable, Identifiable, Sendable, Codable {
        /// CIECAM16's matrix: darktable's default, the most modern.
        case cat16
        /// Bradford: what ICC profiles and the DNG SDK use.
        case bradford
        /// Plain XYZ scaling, the simplest (von Kries in XYZ).
        case xyzScaling = "xyz"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .cat16: return "CAT16"
            case .bradford: return "Bradford"
            case .xyzScaling: return "XYZ Scaling"
            }
        }
    }

    /// The CIE standard illuminants (CIE 015:2018), and a custom light.
    public enum Illuminant: String, CaseIterable, Identifiable, Sendable, Codable {
        case a = "A", d50 = "D50", d55 = "D55", d65 = "D65", d75 = "D75"
        case f2 = "F2", f7 = "F7", f11 = "F11"
        case ledB1 = "LED-B1", ledB2 = "LED-B2", ledB3 = "LED-B3", ledB4 = "LED-B4", ledB5 = "LED-B5"
        case e = "E"
        case custom

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .a: return "A (tungsten)"
            case .d50: return "D50 (horizon daylight)"
            case .d55: return "D55 (mid-morning daylight)"
            case .d65: return "D65 (noon daylight)"
            case .d75: return "D75 (north sky)"
            case .f2: return "F2 (cool white fluorescent)"
            case .f7: return "F7 (broadband fluorescent)"
            case .f11: return "F11 (narrow tri-band fluorescent)"
            case .ledB1: return "LED-B1 (2700 K phosphor)"
            case .ledB2: return "LED-B2 (3000 K phosphor)"
            case .ledB3: return "LED-B3 (4000 K phosphor)"
            case .ledB4: return "LED-B4 (5000 K phosphor)"
            case .ledB5: return "LED-B5 (6500 K phosphor)"
            case .e: return "E (equal energy)"
            case .custom: return "Custom"
            }
        }

        /// CIE 1931 2° chromaticity; nil for Custom.
        public var xy: SIMD2<Float>? {
            switch self {
            case .a: return SIMD2(0.44757, 0.40745)
            case .d50: return SIMD2(0.34567, 0.35850)
            case .d55: return SIMD2(0.33242, 0.34743)
            case .d65: return ChromaticAdaptation.d65xy
            case .d75: return SIMD2(0.29902, 0.31485)
            case .f2: return SIMD2(0.37208, 0.37529)
            case .f7: return SIMD2(0.31292, 0.32933)
            case .f11: return SIMD2(0.38052, 0.37713)
            case .ledB1: return SIMD2(0.4560, 0.4078)
            case .ledB2: return SIMD2(0.4357, 0.4012)
            case .ledB3: return SIMD2(0.3756, 0.3723)
            case .ledB4: return SIMD2(0.3422, 0.3502)
            case .ledB5: return SIMD2(0.3118, 0.3236)
            case .e: return SIMD2(1.0 / 3.0, 1.0 / 3.0)
            case .custom: return nil
            }
        }
    }

    public var method: Method
    public var illuminant: Illuminant
    /// The custom light's chromaticity (used only when `illuminant` is
    /// `.custom`).
    public var x: Float
    public var y: Float
    /// Degrees, −180…180: the light turned round D65.
    public var hue: Float
    /// −1…1: the light's distance from D65 scaled by 1 + chroma.
    public var chroma: Float

    /// The working space's white, from ColorKit's D65 XYZ, so choosing D65
    /// is exactly no change.
    public static let d65xy: SIMD2<Float> = {
        let w = ColorKit.d65XYZ
        let s = w.x + w.y + w.z
        return SIMD2(w.x / s, w.y / s)
    }()

    public static let neutral = ChromaticAdaptation()

    public init(method: Method = .cat16, illuminant: Illuminant = .d65, x: Float? = nil, y: Float? = nil,
                hue: Float = 0, chroma: Float = 0) {
        self.method = method; self.illuminant = illuminant
        self.x = x ?? Self.d65xy.x; self.y = y ?? Self.d65xy.y
        self.hue = hue; self.chroma = chroma
    }

    /// Nothing chosen: D65, no fine-tuning, the default method.
    public var isNeutral: Bool {
        method == .cat16 && illuminant == .d65 && hue == 0 && chroma == 0
            && x == Self.d65xy.x && y == Self.d65xy.y
    }

    /// The light being adapted from, fine-tuning applied.
    public var sourceXY: SIMD2<Float> {
        let base = illuminant.xy ?? SIMD2(x, y)
        guard hue != 0 || chroma != 0 else { return base }
        let offset = base - Self.d65xy
        let angle = hue * .pi / 180
        let turned = SIMD2(offset.x * cos(angle) - offset.y * sin(angle),
                           offset.x * sin(angle) + offset.y * cos(angle))
        return Self.d65xy + turned * max(1 + chroma, 0)
    }

    /// Whether the matrix is the identity: the light is D65 itself.
    public var isIdentity: Bool { simd_distance(sourceXY, Self.d65xy) < 1e-7 }

    /// Cone response matrices.
    static let cat16 = ColorKit.matrix(rows: [
        [ 0.401288, 0.650173, -0.051461],
        [-0.250268, 1.204414,  0.045854],
        [-0.002079, 0.048952,  0.953127],
    ])
    static let bradford = ColorKit.matrix(rows: [
        [ 0.8951,  0.2664, -0.1614],
        [-0.7502,  1.7135,  0.0367],
        [ 0.0389, -0.0685,  1.0296],
    ])

    /// XYZ (Y = 1) of a chromaticity.
    static func xyz(_ xy: SIMD2<Float>) -> SIMD3<Float> {
        let y = max(xy.y, 1e-4)
        return SIMD3(xy.x / y, 1, (1 - xy.x - xy.y) / y)
    }

    /// The working-space matrix carrying colours lit by `sourceXY` to D65.
    /// Identity while the light is D65.
    public var matrix: simd_float3x3 {
        guard !isIdentity else { return matrix_identity_float3x3 }
        let cone: simd_float3x3
        switch method {
        case .cat16: cone = Self.cat16
        case .bradford: cone = Self.bradford
        case .xyzScaling: cone = matrix_identity_float3x3
        }
        let s = cone * Self.xyz(sourceXY), d = cone * ColorKit.d65XYZ
        guard s.x > 1e-6, s.y > 1e-6, s.z > 1e-6 else { return matrix_identity_float3x3 }
        let scale = simd_float3x3(diagonal: SIMD3(d.x / s.x, d.y / s.y, d.z / s.z))
        let toXYZ = ColorKit.rec2020ToXYZ
        return toXYZ.inverse * (cone.inverse * (scale * (cone * toXYZ)))
    }

    private enum CodingKeys: String, CodingKey { case method, illuminant, x, y, hue, chroma }

    /// Lenient: an unknown method or light reads as the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let m = (try? c.decodeIfPresent(String.self, forKey: .method)).flatMap { $0 }.flatMap(Method.init(rawValue:))
        let i = (try? c.decodeIfPresent(String.self, forKey: .illuminant)).flatMap { $0 }.flatMap(Illuminant.init(rawValue:))
        self.init(method: m ?? .cat16, illuminant: i ?? .d65,
                  x: try c.decodeIfPresent(Float.self, forKey: .x), y: try c.decodeIfPresent(Float.self, forKey: .y),
                  hue: try c.decodeIfPresent(Float.self, forKey: .hue) ?? 0,
                  chroma: try c.decodeIfPresent(Float.self, forKey: .chroma) ?? 0)
    }

    /// Only what isn't a default: the custom light's x and y only for a
    /// custom light, the fine-tuning only when moved.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method.rawValue, forKey: .method)
        try c.encode(illuminant.rawValue, forKey: .illuminant)
        if illuminant == .custom {
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        }
        if hue != 0 { try c.encode(hue, forKey: .hue) }
        if chroma != 0 { try c.encode(chroma, forKey: .chroma) }
    }

    /// Values a hand-edited file could break the matrix with, brought back
    /// into range: a custom light inside the spectral locus's box.
    var sanitized: ChromaticAdaptation {
        func clamp(_ v: Float, _ r: ClosedRange<Float>, _ fallback: Float) -> Float {
            v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
        }
        return ChromaticAdaptation(method: method, illuminant: illuminant,
                                   x: clamp(x, 0.2...0.6, Self.d65xy.x), y: clamp(y, 0.2...0.5, Self.d65xy.y),
                                   hue: clamp(hue, -180...180, 0), chroma: clamp(chroma, -1...1, 0))
    }
}
