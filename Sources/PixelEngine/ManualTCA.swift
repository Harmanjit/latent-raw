import Foundation
import LensKit

/// Manual lateral chromatic aberration (docs/wiki/Develop.md, "Lens
/// Corrections"): the Red and Blue sliders under Chromatic Aberration,
/// for a lens Lensfun doesn't know or a correction that needs a nudge.
///
/// Each is the percentage by which that colour's image is larger than the
/// green one, −0.5…+0.5. The lens pass reads the colour at a radius scaled
/// by 1 + that amount, the same radial resample the automatic correction
/// uses (`AutoChromaticAberration.tcaModel`), added to whatever TCA model
/// is in use: the profile's, the measured one, or none. Zero is no change,
/// and absent from the edit then (`EditStack.Lens.tcaRed`, `tcaBlue`).
public enum ManualTCA {
    /// The sliders' range, in percent.
    public static let range: ClosedRange<Float> = -0.5...0.5

    /// A stored or typed value brought into range; 0 when not finite.
    public static func clamped(_ percent: Float) -> Float {
        percent.isFinite ? min(max(percent, range.lowerBound), range.upperBound) : 0
    }

    /// Whether either slider is off zero.
    static func isActive(_ p: EditParameters) -> Bool {
        p.manualTCARed != 0 || p.manualTCABlue != 0
    }

    /// `model` with the manual amounts (percent) added to its linear
    /// terms; a model of its own when there is none and either is set.
    static func adding(red: Float, blue: Float, to model: TCAModel?) -> TCAModel? {
        let kr = clamped(red) / 100, kb = clamped(blue) / 100
        guard kr != 0 || kb != 0 else { return model }
        var m = model ?? .identity
        m.red.z += kr
        m.blue.z += kb
        return m
    }
}
