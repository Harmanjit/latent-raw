import Foundation
import simd

/// Latent's own profiles: starting looks defined here, in code, on top of
/// the camera matrix. None is copied from or modelled on another vendor's
/// profile.
///
/// Each is a ProfileLookTable-style table (hue, saturation and value moves
/// by colour, applied in linear ProPhoto RGB after exposure, exactly where
/// a DCP's look table goes) plus a contrast factor for the tone curve.
/// Latent Standard is no profile at all: the rendering every edit had
/// before profiles existed, so old edits look the same.
public struct BuiltInProfile: Sendable, Identifiable, Equatable {
    public enum Group: String, Sendable {
        /// Plain renderings: no Amount slider.
        case basic
        /// Looks with an Amount slider.
        case creative
        /// Black and white looks, also with an Amount slider.
        case monochrome
    }

    /// Stored in edits: never change one once released.
    public let id: String
    public let name: String
    public let group: Group
    /// What the profile does, for the picker's tooltip.
    public let summary: String
    /// The sigmoid's contrast is multiplied by this (raised to the Amount).
    public let contrastScale: Float
    /// How far the Amount slider goes: 2 (200%) for colour looks, 1 for
    /// black and white, where pushing past grey would bring back inverted
    /// colour.
    public let maximumAmount: Float
    /// The look table; nil only for Standard.
    public let look: HueSatTable?

    public var hasAmount: Bool { group != .basic }

    public static func == (a: BuiltInProfile, b: BuiltInProfile) -> Bool { a.id == b.id }

    // MARK: - The profiles

    public static let standardID = "latent:standard"

    public static let standard = BuiltInProfile(
        id: standardID, name: "Latent Standard", group: .basic,
        summary: "Latent's own rendering from the camera matrix. Every edit made before profiles existed uses it.",
        contrastScale: 1, maximumAmount: 1, look: nil)

    public static let all: [BuiltInProfile] = [
        standard,
        BuiltInProfile(id: "latent:neutral", name: "Latent Neutral", group: .basic,
                       summary: "Lower contrast and gentler colour: a quiet starting point that leaves room to edit.",
                       contrastScale: 0.85, maximumAmount: 1,
                       look: table { _, _, _ in SIMD3(0, 0.92, 1) }),
        BuiltInProfile(id: "latent:flat", name: "Latent Flat", group: .basic,
                       summary: "Very low contrast and muted colour, holding the most shadow and highlight detail, for grading.",
                       contrastScale: 0.65, maximumAmount: 1,
                       look: table { _, _, _ in SIMD3(0, 0.8, 1) }),
        BuiltInProfile(id: "latent:vivid", name: "Vivid", group: .creative,
                       summary: "More saturation and contrast, strongest on muted colours, a little easier on skin.",
                       contrastScale: 1.12, maximumAmount: 2,
                       look: table { h, s, _ in
                           let lift = 0.32 * (1 - 0.6 * s) - 0.1 * band(h, centre: 25, width: 30)
                           return SIMD3(0, 1 + lift, 1)
                       }),
        BuiltInProfile(id: "latent:portrait", name: "Portrait", group: .creative,
                       summary: "Softer contrast; skin tones drawn together, a touch lighter and less red.",
                       contrastScale: 0.92, maximumAmount: 2,
                       look: table { h, s, _ in
                           let skin = band(h, centre: 25, width: 35)
                           // Pull reddish and yellowish skin toward one hue,
                           // more for saturated pixels, which carry the blotches.
                           let shift = wrapDegrees(25 - h) * 0.25 * skin * min(s * 2, 1)
                           // Value moves fade out toward grey, which has no
                           // hue and must not be brightened as if it were skin.
                           return SIMD3(shift, 1 - 0.1 * skin - 0.03 * (1 - skin),
                                        1 + 0.03 * skin * min(s * 4, 1))
                       }),
        BuiltInProfile(id: "latent:landscape", name: "Landscape", group: .creative,
                       summary: "Richer foliage and deeper skies, with a little more contrast.",
                       contrastScale: 1.08, maximumAmount: 2,
                       look: table { h, s, _ in
                           let green = band(h, centre: 100, width: 50)
                           let blue = band(h, centre: 225, width: 40)
                           return SIMD3(-5 * green,
                                        1.05 + 0.15 * green + 0.13 * blue,
                                        1 - 0.06 * blue * min(s * 4, 1))
                       }),
        mono(id: "latent:mono", name: "Monochrome",
             summary: "Black and white from each colour's brightness.",
             filter: SIMD3(1, 1, 1)),
        mono(id: "latent:mono-yellow", name: "Monochrome Yellow Filter",
             summary: "Black and white as through a yellow filter: blue skies a little darker, skin a little lighter.",
             filter: SIMD3(1, 0.9, 0.35)),
        mono(id: "latent:mono-red", name: "Monochrome Red Filter",
             summary: "Black and white as through a red filter: dark, dramatic skies and pale skin.",
             filter: SIMD3(1, 0.35, 0.1)),
        mono(id: "latent:mono-green", name: "Monochrome Green Filter",
             summary: "Black and white as through a green filter: lighter foliage, darker reds and lips.",
             filter: SIMD3(0.45, 1, 0.4)),
    ]

    public static func named(_ id: String) -> BuiltInProfile? {
        all.first { $0.id == id }
    }

    // MARK: - Building tables

    static let hueDivisions = 36
    static let satDivisions = 16

    static func table(_ entry: (Float, Float, Float) -> SIMD3<Float>) -> HueSatTable {
        HueSatTable(hue: hueDivisions, sat: satDivisions, val: 1, entry)
    }

    /// A smooth window: 1 at `centre`, falling to 0 at `width` degrees
    /// either side (raised cosine), with hue wrapping round.
    static func band(_ hue: Float, centre: Float, width: Float) -> Float {
        let d = abs(wrapDegrees(hue - centre))
        guard d < width else { return 0 }
        return 0.5 + 0.5 * cosf(.pi * d / width)
    }

    /// An angle difference folded into -180...180.
    static func wrapDegrees(_ a: Float) -> Float {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    /// Rec.2020 luminance weights, the working space's.
    static let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    /// A black and white profile. For each table colour (its ProPhoto hue
    /// and saturation at full value) the grey is its luminance seen
    /// through `filter`, given per working-space channel and normalised so
    /// white stays white. A 2D table is exact for this at any brightness,
    /// because luminance scales with the colour just as value does.
    static func mono(id: String, name: String, summary: String, filter: SIMD3<Float>) -> BuiltInProfile {
        let norm = simd_dot(luma, filter)
        let look = table { h, s, _ in
            let pp = ColorKit.hsvToRGB(SIMD3(h, s, 1))
            let working = ColorKit.proPhotoToWorking * pp
            let grey = simd_dot(luma, simd_max(working, .zero) * filter) / norm
            return SIMD3(0, 0, max(grey, 0))
        }
        return BuiltInProfile(id: id, name: name, group: .monochrome, summary: summary,
                              contrastScale: 1, maximumAmount: 1, look: look)
    }
}
