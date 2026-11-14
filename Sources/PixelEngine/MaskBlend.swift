import Foundation
import simd

/// How a mask's result joins the picture under it (darktable's blend
/// modes, the two most asked for).
///
/// - Normal: the result as the sliders made it. Every mask before blend
///   modes existed, and the default.
/// - Colour only: the result's colour on the picture's own lightness, so
///   a warm-up or a hue turn never brightens or darkens.
/// - Lightness only: the result's lightness with the picture's own
///   colour, so an exposure or contrast move never shifts saturation.
///
/// The colour kernel recombines after the mask's colour and tone sliders
/// (ColorPipeline.metal, `localBlend`), and the local detail stage does
/// the same after the mask's detail sliders, curve, Point Colour and
/// grain (LocalDetail.metal, `ldBlend`). Lightness is luminance in linear
/// light, so the recombination keeps hue and saturation exactly.
public enum LocalBlendMode: String, Codable, Sendable, CaseIterable {
    case normal, colour, lightness

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .colour: return "Colour Only"
        case .lightness: return "Lightness Only"
        }
    }

    /// `LocalAdjustGPU.info.w` and `LocalDetailGPU.extra.z`.
    var gpuCode: Int32 {
        switch self {
        case .normal: return 0
        case .colour: return 1
        case .lightness: return 2
        }
    }

    /// The recombination on one linear pixel, with luminance weights
    /// `weights`: what the shaders do, for tests.
    public func blend(before: SIMD3<Float>, after: SIMD3<Float>,
                      weights: SIMD3<Float> = SIMD3(0.2627, 0.6780, 0.0593)) -> SIMD3<Float> {
        let yIn = simd_dot(before, weights), yOut = simd_dot(after, weights)
        switch self {
        case .normal:
            return after
        case .colour:
            // The result's colour scaled to the picture's lightness. A
            // black result has no colour to keep: the picture stays.
            return yOut > 1e-6 ? after * (yIn / yOut) : before
        case .lightness:
            // The picture's colour scaled to the result's lightness. A
            // black picture has no colour: the result's lightness, grey.
            return yIn > 1e-6 ? before * (yOut / yIn) : SIMD3(repeating: yOut)
        }
    }
}
