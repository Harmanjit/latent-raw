import PixelEngine

/// How hard an HDR merge looks for things that moved between frames (people,
/// waves, leaves) and keeps each of them to one exposure. The dialog's
/// None / Low / Medium / High.
///
/// **What each level means.** Deghosting compares every frame with the
/// frame that sees each part of the scene best (the *local reference*: the
/// reference frame wherever it's well exposed; see
/// Shaders/MergeDeghost.metal), at quarter size. A part of a frame counts as
/// moving when both of these hold:
/// - its brightness and the local reference's are further apart than
///   `gapStops`, or its colour (red and blue over green, which exposure
///   doesn't change) further than `colourStops`, beyond the noise either
///   could hold and beyond each other's 3 x 3 neighbourhood (so an edge a
///   pixel or two off doesn't count);
/// - at least `patchCount` of the 81 quarter-size blocks in the 9 x 9 patch
///   around it (36 x 36 photosites) disagree too, so scattered noise doesn't.
///
/// Movement found in any frame is closed (gaps up to twice `closeRadius`
/// filled, so a shirt that matched the wall doesn't split a person in two),
/// widened by `dilateRadius` and cut into connected *moving areas*. Each area
/// comes from one frame, the same for all of it (`HDRGhostAreas` has the
/// rules), and every other frame, the reference included, is left out
/// there, feathered by `featherSigma`. Radii are in quarter-size pixels of a
/// 16 MP frame and grow with larger frames.
///
/// | level | gap | colour | patch | close | widen | feather |
/// |---|---|---|---|---|---|---|
/// | low | 0.8 stop | 0.5 stop | 18 of 81 | 4 | 4 | 2 |
/// | medium | 0.5 stop | 0.35 stop | 12 of 81 | 5 | 5 | 2.5 |
/// | high | 0.3 stop | 0.25 stop | 6 of 81 | 6 | 6 | 3 |
///
/// Low catches only large, strong changes (a dark coat crossing a pale
/// wall); high also catches faint ones (ripples, thin branches) at the cost
/// of taking more of the picture from a single, noisier exposure. Left out
/// of each frame (Auto Align on): Market Mires 5%, 14% and 26% at low,
/// medium and high; Ihrke 4%, 10% and 30%; Crete's sea 17%, 21% and 27%.
public enum DeghostAmount: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high

    /// The detector's settings; nil for none.
    public var settings: HDRDeghostSettings? {
        switch self {
        case .none: nil
        case .low: HDRDeghostSettings(gapStops: 0.8, patchRadius: 4, patchCount: 18, dilateRadius: 4, featherSigma: 2,
                                      colourStops: 0.5, closeRadius: 4)
        case .medium: HDRDeghostSettings(gapStops: 0.5, patchRadius: 4, patchCount: 12, dilateRadius: 5,
                                         featherSigma: 2.5, colourStops: 0.35, closeRadius: 5)
        case .high: HDRDeghostSettings(gapStops: 0.3, patchRadius: 4, patchCount: 6, dilateRadius: 6, featherSigma: 3,
                                       colourStops: 0.25, closeRadius: 6)
        }
    }
}
