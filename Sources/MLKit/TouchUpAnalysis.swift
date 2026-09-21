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
    }

    /// Defaults + as-shot WB, no locals/red-eye/dust/touch-up, the edit's
    /// geometry copied, .binned(quads: max(1, longEdge / 4000)),
    /// .file(.sRGB), in the .analysis pool (released after). Wave 1
    /// (W1-E) fills this in.
    public static func render(session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                              parameters: EditParameters, rotation: ImageRotation) throws -> Render {
        throw NotYetImplemented("The touch-up analysis render")
    }
}
