import CoreGraphics
import Foundation
import MergeKit
import PixelEngine

/// The panorama's first edit: Auto Crop's rectangle and, when it is on,
/// Auto Settings' adjustments, as one edit stack.
///
/// **Why an edit and not cut pixels.** A stitched panorama has ragged,
/// empty edges. Auto Crop hides them with an ordinary crop edit in
/// normalised sensor coordinates, stored through the catalog's usual edit
/// path, so Develop's history starts at the merge as it came out and
/// undoing the crop brings the whole canvas back. Nothing is thrown away.
///
/// Auto Settings is exactly the HDR dialog's (`HDRAutoSettings`): Develop's
/// Auto Adjust of the written DNG. Both options can be on at once, and then
/// they are one edit, so one undo takes the photo back to the raw merge.
enum PanoramaResultEdit {
    /// The layout's auto-crop rectangle as a crop edit, or nil when there
    /// is nothing to crop (the rectangle is the whole canvas, or empty).
    ///
    /// `PanoramaLayout.autoCropRect` is in canvas pixels at scale 1, so it
    /// is measured against the canvas's full size; normalised, it is the
    /// same rectangle whatever scale the panorama was merged at.
    static func crop(for analysis: PanoramaMergeAnalysis) -> CropParameters? {
        let rect = analysis.layout.autoCropRect
        let width = Double(analysis.outputSize.fullWidth), height = Double(analysis.outputSize.fullHeight)
        guard width > 0, height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let size = SIMD2<Float>(Float(min(rect.width / width, 1)), Float(min(rect.height / height, 1)))
        let centre = SIMD2<Float>(Float(min(max(rect.midX / width, 0), 1)),
                                  Float(min(max(rect.midY / height, 0), 1)))
        let parameters = CropParameters(centre: centre, size: size)
        return parameters.isIdentity ? nil : parameters
    }

    /// The edit the merged photo at `url` opens with, as the catalog stores
    /// edits; nil when neither option has anything to store.
    ///
    /// - Parameter crop: Auto Crop's rectangle, or nil when it is off.
    /// - Parameter autoAdjust: whether Auto Settings is on.
    static func editStackJSON(forPhotoAt url: URL, crop: CropParameters?, autoAdjust: Bool,
                              gpu: GPUContext) throws -> String? {
        var adjusted: EditStack?
        if autoAdjust, let json = try HDRAutoSettings.edit(forPhotoAt: url, gpu: gpu).editStackJSON {
            adjusted = try EditStack.decode(json: json)
        }
        return try combine(autoAdjusted: adjusted, crop: crop)
    }

    /// Auto Settings' stack (nil when it is off, or made no change) and Auto
    /// Crop's rectangle (nil when it is off) as one stack; nil when neither
    /// has anything to store.
    static func combine(autoAdjusted: EditStack?, crop: CropParameters?) throws -> String? {
        guard let crop else { return try autoAdjusted?.encodeJSON() }
        // The crop goes into whatever Auto Adjust made, through parameters,
        // so the result is one stack the catalog and Develop read as usual.
        var parameters = (autoAdjusted ?? EditStack()).parameters()
        parameters.crop = crop
        var stack = EditStack(parameters: parameters)
        if let lens = autoAdjusted?.modules.lens {
            stack.setLensProvenance(profile: lens.profile, databaseVersion: lens.lensfunDb)
        }
        return try stack.encodeJSON()
    }
}
