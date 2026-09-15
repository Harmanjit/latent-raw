import PixelEngine

/// How hard an HDR merge looks for things that moved between frames (people,
/// waves, leaves) and keeps each of them to one exposure. The dialog's
/// None / Low / Medium / High.
///
/// **What each level means.** Deghosting compares every frame with the
/// frame that sees each part of the scene best (the *local reference*: the
/// reference frame wherever it's well exposed; see
/// Shaders/MergeDeghost.metal), at quarter size, in stops of scene
/// brightness. A part of a frame counts as moving when both of these hold:
/// - its brightness and the local reference's are further apart than
///   `gapStops`, beyond the noise either could hold and beyond each other's
///   3 x 3 neighbourhood (so an edge a pixel or two off doesn't count);
/// - at least `patchCount` of the 81 quarter-size blocks in the 9 x 9 patch
///   around it (36 x 36 photosites) disagree too, so scattered noise doesn't.
///
/// Movement found in any frame is widened by `dilateRadius` and feathered by
/// `featherSigma` (quarter-size pixels), and every frame is left out there
/// except the one that is the local reference.
///
/// | level | gap | patch | widen | feather |
/// |---|---|---|---|---|
/// | low | 1.0 stop | 24 of 81 | 2 | 1.5 |
/// | medium | 0.5 stop | 12 of 81 | 3 | 2 |
/// | high | 0.3 stop | 6 of 81 | 4 | 2.5 |
///
/// Low catches only large, strong changes (a dark coat crossing a pale
/// wall); high also catches faint ones (ripples, thin branches) at the cost
/// of taking more of the picture from a single, noisier exposure. On the
/// Crete seashore bracket, Low leaves out about 11% of each frame, Medium
/// 19% and High 23%.
public enum DeghostAmount: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high

    /// The detector's settings; nil for none.
    public var settings: HDRDeghostSettings? {
        switch self {
        case .none: nil
        case .low: HDRDeghostSettings(gapStops: 1.0, patchRadius: 4, patchCount: 24, dilateRadius: 2, featherSigma: 1.5)
        case .medium: HDRDeghostSettings(gapStops: 0.5, patchRadius: 4, patchCount: 12, dilateRadius: 3, featherSigma: 2)
        case .high: HDRDeghostSettings(gapStops: 0.3, patchRadius: 4, patchCount: 6, dilateRadius: 4, featherSigma: 2.5)
        }
    }
}
