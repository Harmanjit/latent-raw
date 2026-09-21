import Foundation
import CoreGraphics
import PixelEngine

/// The render faces are found on (docs/Retouch.md §7): the image's
/// defaults, so a dark edit or a local never hides a face, at a size
/// Vision's 76-point fit works at.
public enum TouchUpAnalysis {
    public struct Render: @unchecked Sendable {
        /// Output grid, unrotated, sRGB.
        public let image: CGImage
        /// Sensor px per analysis px (2 × quads); sensor = (x + 0.5) * span.
        public let span: Int
        public let rotation: ImageRotation

        public init(image: CGImage, span: Int, rotation: ImageRotation) {
            self.image = image
            self.span = span
            self.rotation = rotation
        }

        /// Half-res pixels of the mask set per analysis pixel (the quads).
        var quads: Int { span / 2 }
    }

    /// The long edge the render is binned towards: 2000–4000 px, where a
    /// face has to be about 80 px across for the 76-point fit, and a
    /// 24 MP frame reads back in a few tens of megabytes.
    static let targetLongEdge = 4000

    /// Defaults + as-shot WB, no locals/red-eye/dust/touch-up, the edit's
    /// geometry copied, .binned(quads: max(1, longEdge / 4000)),
    /// .file(.sRGB), in the .analysis pool (released after).
    ///
    /// The geometry is copied because the masks are sampled by output
    /// position: a lens profile or a keystone moves every pixel, so the
    /// landmarks have to be found on the corrected grid. Everything else
    /// is the camera's own look, which is what a face detector was
    /// trained on and what a heavy edit can hide.
    public static func render(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                              parameters: EditParameters, rotation: ImageRotation) throws -> Render {
        let summary = session.file.summary
        let quads = max(1, max(summary.rawWidth, summary.rawHeight) / targetLongEdge)
        let look = analysisParameters(from: parameters, session: session)
        // A pool of its own: at the preview's bin factor the preview's
        // pooled textures, on screen, would take this render's pixels.
        defer { session.releasePooledTextures(in: .analysis) }
        let image = try session.withTexturePool(.analysis) {
            let texture = try pipeline.render(session, scale: .binned(quads: quads), parameters: look,
                                              output: .file(.sRGB))
            return try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB)
        }
        return Render(image: image, span: 2 * quads, rotation: rotation)
    }

    /// The parameters the analysis renders with: `EditParameters()` (no
    /// locals, red eyes, dust or touch-up) with the camera's white balance
    /// and the edit's geometry.
    static func analysisParameters(from parameters: EditParameters, session: ImageSession) -> EditParameters {
        var look = EditParameters()
        look.whiteBalance = session.asShotWhiteBalance
        look.lensDistortion = parameters.lensDistortion
        look.lensTCA = parameters.lensTCA
        look.lensVignetting = parameters.lensVignetting
        look.manualDistortion = parameters.manualDistortion
        look.manualVignetting = parameters.manualVignetting
        look.perspective = parameters.perspective
        look.outputSpace = .sRGB
        return look
    }
}
