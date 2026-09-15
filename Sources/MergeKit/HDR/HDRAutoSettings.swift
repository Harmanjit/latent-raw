// Auto Settings, Lightroom's checkbox in the HDR dialog: the merged photo
// opens with Develop's Auto Adjust already applied.

import Foundation
import PixelEngine
import RawCore

/// What Develop › Auto Adjust (⌘U) makes of a merge result, as an edit.
///
/// **Exactly ⌘U.** The DNG is opened as Develop opens it (the file, an
/// `ImageSession`, the camera's own white balance as the starting point)
/// and `AutoAdjust.suggest` is asked about it, with the same starting
/// parameters, and its exposure, contrast and white balance applied the
/// way the editor applies them. So a merge made with Auto Settings looks
/// the same as the merge made without it and then auto adjusted by hand.
///
/// The app stores the edit through the catalog's normal edit path, so it
/// lands in the result's sidecar beside the merge recipe, and Develop's
/// history starts at "Original" with the auto settings one step on: undo
/// goes back to the merge as it came out.
public enum HDRAutoSettings {
    public struct Edit: Sendable {
        /// The edit stack as the catalog stores it (with the lens profile's
        /// provenance, as Develop saves it); nil when Auto Adjust leaves the
        /// photo at its defaults, so there is nothing to store.
        public let editStackJSON: String?
        public let suggestion: AutoAdjust.Suggestion
    }

    /// Auto Adjust's edit for the photo at `url` (a merged DNG), opened
    /// with no edit.
    public static func edit(forPhotoAt url: URL, gpu: GPUContext) throws -> Edit {
        let file = try RawFile(path: url.path)
        let session = try ImageSession(file: file, gpu: gpu)
        // Develop's defaults for a freshly opened photo (EditorModel+Opening).
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let suggestion = try AutoAdjust.suggest(for: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu,
                                                current: defaults)
        // As EditorModel.autoAdjust applies it.
        var parameters = defaults
        parameters.exposureEV = suggestion.exposureEV
        parameters.contrast = suggestion.contrast
        if let whiteBalance = suggestion.whiteBalance { parameters.whiteBalance = whiteBalance }
        guard !EditStack.isDefault(parameters, relativeTo: defaults) else {
            return Edit(editStackJSON: nil, suggestion: suggestion)
        }
        var stack = EditStack(parameters: parameters)
        if let lens = session.lensCorrection {
            stack.setLensProvenance(profile: lens.profileName, databaseVersion: lens.databaseVersion)
        }
        return Edit(editStackJSON: try stack.encodeJSON(), suggestion: suggestion)
    }
}
