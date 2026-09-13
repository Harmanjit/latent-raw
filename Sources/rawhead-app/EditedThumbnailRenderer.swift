import Foundation
import CoreGraphics
import RawCore
import PixelEngine
import Catalog

/// Makes thumbnails for edited images by running the real pipeline at
/// thumbnail resolution (DESIGN.md §10). Binning picks a size just under
/// 512px on the long edge, so no demosaic runs at all; the cost is
/// dominated by LibRaw's unpack (~200ms), which is why this happens in
/// the background after an edit settles.
///
/// Sendable because GPUContext is; each call builds its own RawFile and
/// ImageSession and lets them go, so nothing is shared with the editor.
struct PipelineThumbnailRenderer: EditedThumbnailRenderer {
    let gpu: GPUContext

    func renderThumbnail(rawFileAt url: URL, editStackJSON: String) throws -> CGImage {
        let file = try RawFile(path: url.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let parameters = (try? EditStack.decode(json: editStackJSON))?
            .parameters(defaults: defaults) ?? defaults

        // Bin so the long edge lands at or under the thumbnail size.
        let longEdge = max(file.summary.rawWidth, file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / Double(2 * Thumbnailer.size)).rounded(.up)))
        let texture = try pipeline.render(session, scale: .binned(quads: quads),
                                          parameters: parameters, output: .file(.sRGB))

        // Camera orientation only; the user's manual turns are applied at
        // display time, like the embedded-preview thumbnails.
        let rotation = ImageRotation(libRawFlip: file.summary.orientation)
        return try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB, rotation: rotation)
    }
}
