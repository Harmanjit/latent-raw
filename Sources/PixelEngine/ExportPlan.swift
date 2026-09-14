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
    /// filter), never below it; full resolution otherwise.
    public static func scale(for summary: RawSummary, maxLongEdge: Int?) -> RenderScale {
        guard let target = maxLongEdge, target > 0 else { return .full }
        let quads = max(summary.rawWidth, summary.rawHeight) / (2 * target)
        return quads >= 1 ? .binned(quads: quads) : .full
    }

    /// The camera's orientation plus the user's quarter turns.
    public static func rotation(for summary: RawSummary, userRotation: Int) -> ImageRotation {
        ImageRotation(libRawFlip: summary.orientation).rotated(by: userRotation)
    }
}
