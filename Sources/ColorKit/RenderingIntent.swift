import Foundation

/// How colours a destination can't reproduce are brought into its gamut
/// (soft proofing, printing, and any conversion into an ICC profile).
///
/// Perceptual and Relative Colorimetric are the two photographers usually
/// choose between, as in Lightroom, and come first. Saturation (for
/// graphics, where vivid colour matters more than accuracy) and Absolute
/// Colorimetric (which keeps the paper's own white, for proofing one
/// press on another) are offered too, as darktable offers all four. The
/// raw values are the stored ones, so settings saved before the last two
/// existed decode unchanged.
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
    /// Colours are pushed to the destination's most saturated ones, at the
    /// cost of accuracy. Meant for charts and graphics.
    case saturation
    /// Colours that fit are kept exactly, paper white included: the print
    /// is tinted by the difference between the paper and the source white.
    case absoluteColorimetric

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .perceptual: "Perceptual"
        case .relativeColorimetric: "Relative Colorimetric"
        case .saturation: "Saturation"
        case .absoluteColorimetric: "Absolute Colorimetric"
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
        case .saturation:
            "Pushes colours to the most saturated the destination can make, giving up accuracy. Meant for graphics rather than photos."
        case .absoluteColorimetric:
            "Keeps colours that fit exactly, the paper's white included, without black point compensation. For proofing one paper or press on another."
        }
    }
}
