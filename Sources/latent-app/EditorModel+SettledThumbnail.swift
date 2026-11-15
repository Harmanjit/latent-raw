import Foundation
import CoreGraphics
import PixelEngine

extension EditorModel {
    /// Renders the thumbnail of the edit that just settled from the open
    /// session and hands it to `onSettledThumbnail`, so the thumbnail pass
    /// the save starts writes it instead of decoding the raw again in a
    /// fresh session: 268 ms of a 310 ms edited thumbnail (plan #28).
    ///
    /// Runs on the main actor, like every render of the session: a binned
    /// render at thumbnail size and its readback, a few milliseconds, once
    /// per settled edit (a second after the last change). Its textures come
    /// from the analysis pool and are released straight after, so the
    /// preview, tile and their demosaic cache are left as they were. Any
    /// failure is silent: the pass then renders it the usual way.
    /// Moving this off the main actor is part of the render rewrite.
    func offerSettledThumbnail(imageID: Int64, editStackJSON: String) {
        guard let onSettledThumbnail, let session, let pipeline, let gpu = gpuContext,
              catalogImageID == imageID else { return }
        let image: CGImage
        do {
            image = try session.withTexturePool(.analysis) {
                defer { session.releasePooledTextures(in: .analysis) }
                return try PipelineThumbnailRenderer.render(session, pipeline: pipeline, gpu: gpu,
                                                            editStackJSON: editStackJSON)
            }
        } catch {
            return
        }
        onSettledThumbnail(imageID, editStackJSON, image)
    }
}
