import Foundation
import CoreGraphics
import RawCore
import PixelEngine

extension ExportWorker {
    /// One image with its edit, rendered for a screen rather than a file:
    /// the steps of `export` up to the pixels (open the raw, rebuild the
    /// edit over its defaults with `ExportPlan`, regenerate model masks,
    /// render, rotate, crop and resize with the exporter's passes), sized
    /// to fit `screen` pixels, and kept on the GPU. For the slideshow.
    ///
    /// Two differences from a file, both for the time a slide has:
    ///
    /// - **No neural denoise.** It runs on the full frame for seconds; a
    ///   slide is binned to screen size, which averages most noise away.
    ///   The edit's classic noise reduction still applies.
    /// - **Display P3, SDR.** The output space is the one wide-gamut Mac
    ///   screens show; no gain map or metadata.
    ///
    /// Checks for cancellation between the steps, so a slide the show has
    /// moved past stops early; the render itself runs to the end once begun.
    public static func renderForScreen(sourceURL: URL, editStackJSON: String?, userRotation: Int,
                                       screen: CGSize, gpu: GPUContext) async throws -> SlideTexture {
        let file = try RawFile(path: sourceURL.path)
        try Task.checkCancellation()
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let parameters: EditParameters
        do {
            parameters = try ExportPlan.parameters(editStackJSON: editStackJSON, session: session,
                                                   colorSpace: .displayP3)
        } catch {
            throw ExportWorkerError.unreadableEdit(error)
        }
        try Task.checkCancellation()
        _ = try await regenerateMasks(parameters.locals, session: session, pipeline: pipeline, gpu: gpu)
        try Task.checkCancellation()

        let summary = file.summary
        let rotation = ExportPlan.rotation(for: summary, userRotation: userRotation)
        let sensor = CGSize(width: summary.rawWidth, height: summary.rawHeight)
        let canvas = CropFrame(sensorSize: sensor, crop: parameters.crop, rotation: rotation).canvasSize
        let plan = SlideshowGeometry.renderPlan(sensor: sensor, canvas: canvas, screen: screen)
        let scale = ExportPlan.scale(for: summary, maxLongEdge: plan.sensorLongEdge)
        let texture = try pipeline.render(session, scale: scale, parameters: parameters,
                                          output: .file(.displayP3))
        return try Exporter(gpu: gpu).screenTexture(from: texture, rotation: rotation, crop: parameters.crop,
                                                    maxLongEdge: plan.slideLongEdge)
    }
}
