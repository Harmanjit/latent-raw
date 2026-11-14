import Foundation

/// How much of each Colour Grading range a tone belongs to: the weights
/// `applyColourGrading` in ColorPipeline.metal uses, on the CPU, for the
/// panel's range graph and the tests. Keep the two the same.
public enum ColourGradingRanges {
    /// Shadows, midtones and highlights weights (each 0…1) for a tone, the
    /// grading stage's perceptual luminance 0…1, with Split Toning's
    /// Balance (−1…1) and Colour Grading's Blending (0…1).
    public static func weights(luminance l: Float, balance: Float, blending: Float) -> SIMD3<Float> {
        let lb = pow(min(max(l, 0), 1), exp(-balance))
        let b = min(max(blending, 0), 1)
        let half = max(b, 0.02)
        let wH = smoothstep(0.5 - half, 0.5 + half, lb)
        let wM = 1 - smoothstep(0, 0.5 + b, abs(lb - 0.5) * 2)
        return SIMD3(1 - wH, wM, wH)
    }

    /// Metal's smoothstep.
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
