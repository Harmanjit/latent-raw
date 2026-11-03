import Foundation

/// How the selected mask is shown while editing: a display setting, like
/// `RenderOutput.maskOverlay`, never part of the edit or of a file.
public enum MaskOverlayMode: Int, CaseIterable, Codable, Sendable {
    /// A colour over the picture (the long-standing red tint).
    case colour = 0
    /// The colour over a black-and-white picture, so it reads on a
    /// picture of the same colour.
    case colourOnBlackAndWhite = 1
    /// Only what the mask covers, on black.
    case imageOnBlack = 2
    /// Only what the mask covers, on white.
    case imageOnWhite = 3
    /// The mask itself: white where it is full, black where it is empty.
    case whiteOnBlack = 4

    public var displayName: String {
        switch self {
        case .colour: return "Colour Overlay"
        case .colourOnBlackAndWhite: return "Colour Overlay on B&W"
        case .imageOnBlack: return "Image on Black"
        case .imageOnWhite: return "Image on White"
        case .whiteOnBlack: return "White on Black"
        }
    }

    /// Whether the overlay colour and opacity mean anything in this mode.
    public var usesColour: Bool { self == .colour || self == .colourOnBlackAndWhite }
}

public struct MaskOverlayStyle: Equatable, Sendable {
    public var mode: MaskOverlayMode
    /// Linear RGB in the output space.
    public var colour: SIMD3<Float>
    /// 0…1: how far the colour covers the picture where the mask is full.
    public var opacity: Float

    public init(mode: MaskOverlayMode = .colour, colour: SIMD3<Float> = SIMD3(0.8, 0.05, 0.05), opacity: Float = 0.5) {
        self.mode = mode; self.colour = colour; self.opacity = opacity
    }

    /// The red tint at half strength every version before this one drew.
    public static let standard = MaskOverlayStyle()
}
