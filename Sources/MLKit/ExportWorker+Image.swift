import Foundation
import CoreGraphics
import RawCore
import PixelEngine
import ColorKit

/// A rendered picture handed across threads. CGImage is immutable, but the
/// SDK doesn't say it is Sendable.
public struct RenderedImage: @unchecked Sendable {
    public let cgImage: CGImage

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

extension ExportWorker {
    /// A picture rendered for a page rather than written to a file: Print
    /// and Contact Sheet draw these.
    public struct ImageRequest: Sendable {
        public var sourceURL: URL
        public var editStackJSON: String?
        public var userRotation: Int
        public var colorSpace: ColorKit.OutputSpace
        /// Long edge in pixels; nil for full size. Never enlarged.
        public var maxLongEdge: Int?
        /// 8 or 16.
        public var bitsPerComponent: Int
        /// AI denoise runs on the full frame and takes seconds per image. A
        /// contact sheet's small cells can't show it (thumbnails skip it for
        /// the same reason); a print can.
        public var runsAIDenoise: Bool

        public init(sourceURL: URL, editStackJSON: String?, userRotation: Int, colorSpace: ColorKit.OutputSpace,
                    maxLongEdge: Int?, bitsPerComponent: Int = 16, runsAIDenoise: Bool = true) {
            self.sourceURL = sourceURL
            self.editStackJSON = editStackJSON
            self.userRotation = userRotation
            self.colorSpace = colorSpace
            self.maxLongEdge = maxLongEdge
            self.bitsPerComponent = bitsPerComponent
            self.runsAIDenoise = runsAIDenoise
        }
    }

    /// The same steps as `export` up to the pixels (open the raw, rebuild
    /// the edit over the image's defaults with `ExportPlan`, regenerate
    /// model masks, AI denoise when asked, render binned towards the size,
    /// then rotate, crop and Lanczos-resize on the GPU), returning the image
    /// instead of encoding a file. No metadata: a page carries none.
    public static func renderImage(_ request: ImageRequest, gpu: GPUContext) async throws -> RenderedImage {
        let file = try RawFile(path: request.sourceURL.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)

        let parameters: EditParameters
        do {
            parameters = try ExportPlan.parameters(editStackJSON: request.editStackJSON, session: session,
                                                   colorSpace: request.colorSpace)
        } catch {
            throw ExportWorkerError.unreadableEdit(error)
        }
        _ = try await regenerateMasks(parameters.locals, session: session, pipeline: pipeline, gpu: gpu)
        if request.runsAIDenoise, parameters.aiDenoise > 0, session.supportsAIDenoise, AIDenoiser.isAvailable {
            let denoiser = try await AIDenoiser.load()
            try await AIDenoiseWorker.run(session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser)
        }

        let scale = ExportPlan.scale(for: file.summary, crop: parameters.crop, maxLongEdge: request.maxLongEdge)
        let texture = try pipeline.render(session, scale: scale, parameters: parameters,
                                          output: .file(request.colorSpace))
        let rotation = ExportPlan.rotation(for: file.summary, userRotation: request.userRotation)
        let image = try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: request.colorSpace,
                                                   rotation: rotation, crop: parameters.crop,
                                                   bitsPerComponent: request.bitsPerComponent == 16 ? 16 : 8,
                                                   maxLongEdge: request.maxLongEdge)
        return RenderedImage(image)
    }
}
