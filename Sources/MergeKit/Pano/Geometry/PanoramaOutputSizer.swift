import Foundation
import Metal

/// How big a panorama is made: Harman's rule (docs/PhotoMerge.md section 4,
/// "Output size"). A panorama is never refused for being too big; when the
/// full-resolution canvas wouldn't fit what this Mac can edit, it is made at
/// the largest size that does, once the user agrees.
///
/// **The rule.** `s = min(1, L / max(W, H), sqrt(P / (W × H)))`, output
/// `floor(W × s) × floor(H × s)`:
/// - `L`, the largest texture side the GPU takes (16,384 px on Apple
///   Silicon, read from the device): the editor holds the whole image in
///   textures.
/// - `P`, the pixel budget for *editing* the result:
///   `0.4 × recommendedMaxWorkingSetSize / bytesPerEditPixel`.
/// - Never above 1: Latent never upsamples.
///
/// **Decoding smaller.** When `s <= 1/2`, frames are demosaiced with a
/// binned span `k`, the largest whole number with `1/k >= s`: still at least
/// the output's resolution, less noise, and far less memory and time. The
/// warp then covers the remaining reduction (under 2x).
///
/// Pure: every input is a parameter, so it is tested without a GPU.
public enum PanoramaOutputSizer {
    /// GPU memory an edit of a linear source holds per full-resolution
    /// pixel, the `bytesPerEditPixel` of the rule. Measured on main
    /// (LinearSeamRoundTripTests.testMeasureBytesPerEditPixel, a 24 MP
    /// linear source): 46 bytes with default settings, 112 with denoise,
    /// heal, lens correction, presence, a local adjustment and sharpening
    /// all on.
    ///
    /// **Why the heavy figure.** A panorama is exactly the photo people
    /// edit hard (lens-corrected skies, local adjustments, noise reduction
    /// in the shadows), and running out of GPU memory mid-edit is far worse
    /// than a slightly smaller result: macOS pages GPU memory to disk and
    /// the editor stalls for seconds per slider move. At 112 bytes the
    /// heaviest edit measured stays inside 40% of the working set (the rest
    /// is the app, the viewport's caches and every other app's GPU use); a
    /// default edit then uses about 16% of it.
    public static let bytesPerEditPixel = 112
    /// The share of the GPU's recommended working set an edit may plan on.
    public static let workingSetShare = 0.4

    /// The editing pixel budget `P` for a working set of `bytes`:
    /// about 41 MP for the 11.4 GB an M1 Pro with 16 GB recommends.
    public static func editPixelBudget(recommendedWorkingSetBytes bytes: UInt64) -> Double {
        workingSetShare * Double(bytes) / Double(bytesPerEditPixel)
    }

    /// The output size for a `fullWidth x fullHeight` canvas (scale 1).
    ///
    /// - Parameters:
    ///   - maxTextureSide: the GPU's largest texture side, `L`.
    ///   - editPixelBudget: `P`, in pixels.
    public static func size(fullWidth: Int, fullHeight: Int, maxTextureSide: Int,
                            editPixelBudget: Double) -> PanoramaOutputSize {
        let w = max(1, fullWidth), h = max(1, fullHeight)
        let sideScale = Double(maxTextureSide) / Double(max(w, h))
        let memoryScale = (max(editPixelBudget, 1) / (Double(w) * Double(h))).squareRoot()
        let scale = min(1, sideScale, memoryScale)
        let limit: PanoramaOutputSize.Limit = scale >= 1 ? .none : sideScale <= memoryScale ? .textureSide : .memory
        // floor(W x s), with a hair of tolerance so a scale computed as
        // exactly L / W doesn't round L - 1 down from 16383.9999999.
        func scaled(_ n: Int) -> Int { max(1, Int((Double(n) * scale + 1e-9).rounded(.down))) }
        var width = scaled(w), height = scaled(h)
        if limit == .none { (width, height) = (w, h) }
        return PanoramaOutputSize(fullWidth: w, fullHeight: h, scale: scale, width: width, height: height,
                                  limit: limit, decodeSpan: decodeSpan(scale: scale))
    }

    /// For a `device`: its largest texture side and recommended working set.
    public static func size(fullWidth: Int, fullHeight: Int, device: MTLDevice) -> PanoramaOutputSize {
        size(fullWidth: fullWidth, fullHeight: fullHeight, maxTextureSide: maxTextureSide(device),
             editPixelBudget: editPixelBudget(recommendedWorkingSetBytes: device.recommendedMaxWorkingSetSize))
    }

    /// The largest 2D texture side `device` supports: 16,384 px on Apple
    /// silicon (Apple7 GPU family and later), 8,192 px before. Metal has no
    /// query for the number itself, so it is read from the GPU family, the
    /// way Apple's feature set tables state it.
    public static func maxTextureSide(_ device: MTLDevice) -> Int {
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) { return 16_384 }
        return 8_192
    }

    /// The binned demosaic span: the largest k with 1/k >= `scale` when the
    /// scale is at most 1/2, else 1 (full resolution).
    public static func decodeSpan(scale: Double) -> Int {
        guard scale > 0, scale <= 0.5 else { return 1 }
        // floor(1/s), guarded against 1/0.25 landing a hair under 4.
        return max(1, Int((1 / scale + 1e-9).rounded(.down)))
    }
}
