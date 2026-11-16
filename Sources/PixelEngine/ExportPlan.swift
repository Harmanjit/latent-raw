import Foundation
import Metal
import RawCore
import ColorKit

/// The decisions between a saved edit and the pixels an export writes:
/// which parameters, at what render scale, turned which way. Shared by
/// `ExportWorker` and the golden-image tests, so the tests check the code
/// exports actually run rather than a copy of it.
public enum ExportPlan {
    /// The image's defaults with the saved edit over them, exactly as the
    /// editor reconstructs it. White balance saved as "as shot" becomes
    /// this camera's own; the output space comes from the export, never
    /// from the edit (an edit stack doesn't store one). Geometry from
    /// before the active-area change is moved onto it, as the editor does.
    public static func parameters(editStackJSON: String?, session: ImageSession,
                                  colorSpace: ColorKit.OutputSpace) throws -> EditParameters {
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        var parameters = defaults
        if let json = editStackJSON {
            parameters = try session.stackForThisImage(EditStack.decode(json: json)).parameters(defaults: defaults)
            if parameters.whiteBalance.isAsShot { parameters.whiteBalance = defaults.whiteBalance }
        }
        parameters.outputSpace = colorSpace
        return parameters
    }

    /// Bin as far as the target size allows (cheaper, and a correct box
    /// filter), never below it; full resolution otherwise. The target is
    /// the long edge of the exported image, which is `crop` of the render:
    /// the whole frame binned to the target would come out smaller than
    /// asked once cropped, since the exporter never enlarges.
    ///
    /// `maxTextureSide`, the GPU's largest texture side, caps the render:
    /// a photo wider than it (a big panorama TIFF, a pixel-shift raw) is
    /// binned as little as makes it fit, since a texture past it can't be
    /// made at all. Nil, no cap.
    public static func scale(for summary: RawSummary, crop: CropParameters = .none,
                             maxLongEdge: Int?, maxTextureSide: Int? = nil) -> RenderScale {
        scale(rawWidth: summary.rawWidth, rawHeight: summary.rawHeight, crop: crop, maxLongEdge: maxLongEdge,
              maxTextureSide: maxTextureSide)
    }

    static func scale(rawWidth: Int, rawHeight: Int, crop: CropParameters, maxLongEdge: Int?,
                      maxTextureSide: Int? = nil) -> RenderScale {
        let planned = uncappedScale(rawWidth: rawWidth, rawHeight: rawHeight, crop: crop, maxLongEdge: maxLongEdge)
        guard let limit = maxTextureSide, limit > 0,
              renderLongEdge(rawWidth: rawWidth, rawHeight: rawHeight, scale: planned) > limit else { return planned }
        // A binned render is the sensor over twice the quads, rounded down.
        let long = max(rawWidth, rawHeight)
        var quads = max(1, (long + 2 * limit - 1) / (2 * limit))
        while long / (2 * quads) > limit { quads += 1 }
        return .binned(quads: quads)
    }

    /// The long edge of the texture a render of the whole sensor at
    /// `scale` makes.
    public static func renderLongEdge(rawWidth: Int, rawHeight: Int, scale: RenderScale) -> Int {
        switch RenderPipeline.plan(rawWidth: rawWidth, rawHeight: rawHeight, scale: scale) {
        case .fullResolution(_, let size): max(size.width, size.height)
        case .binned(let quads): max(rawWidth, rawHeight) / (2 * quads)
        }
    }

    /// The largest texture side `device` can make: what `scale` is capped to.
    public static func maxTextureSide(_ device: MTLDevice) -> Int {
        device.supportsFamily(.apple3) || device.supportsFamily(.mac2) ? 16_384 : 8_192
    }

    private static func uncappedScale(rawWidth: Int, rawHeight: Int, crop: CropParameters,
                                      maxLongEdge: Int?) -> RenderScale {
        guard let target = maxLongEdge, target > 0 else { return .full }
        // The cropped long edge a render of `width` x `height` gives, as the
        // exporter measures it (quarter turns don't change it).
        func croppedLongEdge(_ width: Int, _ height: Int) -> Int {
            let size = CropFrame(sensorSize: CGSize(width: width, height: height), crop: crop).canvasSize
            return Int(max(size.width, size.height).rounded())
        }
        // A binned render is the sensor over twice the quads, rounded down.
        var quads = croppedLongEdge(rawWidth, rawHeight) / (2 * target)
        while quads >= 1, croppedLongEdge(rawWidth / (2 * quads), rawHeight / (2 * quads)) < target {
            quads -= 1
        }
        return quads >= 1 ? .binned(quads: quads) : .full
    }

    /// The camera's orientation plus the user's quarter turns.
    public static func rotation(for summary: RawSummary, userRotation: Int) -> ImageRotation {
        ImageRotation(libRawFlip: summary.orientation).rotated(by: userRotation)
    }
}
