import Foundation
import CoreGraphics
import PixelEngine

/// Sharpens a coarse subject mask against the image it came from, for
/// models whose manifest says `refine: guided` (U²-Net's edges are soft
/// at its 320 px; docs/Retouch.md §5).
public enum GuidedMaskRefiner {
    /// Upsamples `mask` to `guide`'s size with a guided filter on the
    /// guide's luminance (CPU, box sums). Wave 1 (W1-A) fills this in;
    /// until then the mask comes back as it went in.
    public static func refine(_ mask: MaskBitmap, guide: CGImage, radius: Int = 8, epsilon: Float = 1e-3) -> MaskBitmap {
        mask
    }
}
