import Foundation
import PixelEngine
import RawCore

extension EditorModel {
    /// True while the open image is a JPEG, HEIC, TIFF, PNG, WebP or AVIF
    /// rather than a raw. The Develop panels hide what only a raw has:
    /// lens profiles, demosaicing, highlight reconstruction and the neural
    /// denoiser (see `ImageSession.isRenderedImage`).
    var isRenderedImage: Bool { session?.isRenderedImage ?? false }
}

extension EditorModel {
    /// The status line for an opened JPEG, TIFF and the like: its format
    /// and depth first, since that is what decides how far it can be
    /// pushed, then the camera when the file names one.
    static func renderedImageStatus(_ info: RenderedImageInfo, summary: RawSummary) -> String {
        var parts = ["\(info.format) · \(info.bitsPerComponent)-bit"]
        let camera = [summary.cameraMake, summary.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
        if !camera.isEmpty { parts.append(camera) }
        parts.append("\(summary.rawWidth)×\(summary.rawHeight)")
        return parts.joined(separator: " · ")
    }
}
