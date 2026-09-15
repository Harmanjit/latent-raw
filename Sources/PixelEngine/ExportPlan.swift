import Foundation
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
    /// from the edit (an edit stack doesn't store one).
    public static func parameters(editStackJSON: String?, session: ImageSession,
                                  colorSpace: ColorKit.OutputSpace) throws -> EditParameters {
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        var parameters = defaults
        if let json = editStackJSON {
            parameters = try EditStack.decode(json: json).parameters(defaults: defaults)
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
    public static func scale(for summary: RawSummary, crop: CropParameters = .none,
                             maxLongEdge: Int?) -> RenderScale {
        scale(rawWidth: summary.rawWidth, rawHeight: summary.rawHeight, crop: crop, maxLongEdge: maxLongEdge)
    }

    static func scale(rawWidth: Int, rawHeight: Int, crop: CropParameters, maxLongEdge: Int?) -> RenderScale {
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
