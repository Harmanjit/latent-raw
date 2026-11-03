import Foundation

/// How colours a destination can't reproduce are brought into its gamut
/// (soft proofing, printing, and any conversion into an ICC profile).
///
/// Only the two intents photographers actually choose between are
/// offered, as in Lightroom. Saturation is for business graphics and
/// Absolute Colorimetric is what "Simulate Paper & Ink" uses on the
/// way back to the screen, not something to print with.
public enum RenderingIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The whole image is compressed into the destination's gamut, so
    /// relationships between colours survive at the cost of shifting the
    /// ones that already fit. Best for photos with many saturated colours.
    case perceptual
    /// Colours that fit are kept exactly; the rest are clipped to the
    /// nearest reproducible colour. Black point compensation maps the
    /// image's black to the paper's deepest black so shadows don't block
    /// up. Best for photos with few out-of-gamut colours.
    case relativeColorimetric

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .perceptual: "Perceptual"
        case .relativeColorimetric: "Relative Colorimetric"
        }
    }

    /// Lightroom always pairs relative colorimetric with black point
    /// compensation; perceptual tables already map black to black.
    public var usesBlackPointCompensation: Bool { self == .relativeColorimetric }

    public var help: String {
        switch self {
        case .perceptual:
            "Squeezes every colour into the destination's gamut, keeping how colours relate. Best when many colours are out of gamut."
        case .relativeColorimetric:
            "Keeps colours that fit exactly and clips the rest, with black point compensation. Best when only a few colours are out of gamut."
        }
    }
}
