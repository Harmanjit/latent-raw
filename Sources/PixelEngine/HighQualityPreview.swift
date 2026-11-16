import Foundation
import Metal
import CoreGraphics

/// View › High Quality Preview: the fitted view drawn from a full-resolution
/// render, demosaiced as an export is, then shrunk with the export's Lanczos
/// filter in linear light (`ExportResampler`), instead of from the binned
/// preview. Sharper and truer to the export at fit, at the cost of a full
/// render (a few hundred megabytes of textures, briefly) each time the edit
/// settles, which is why it is opt-in.
public enum HighQualityPreview {
    /// The whole frame at full resolution, resampled so its long edge is
    /// `longEdge` pixels (never enlarged), as a layer covering the sensor.
    /// The full-size textures are rendered in the session's analysis pool
    /// and given back before returning, so the editor's preview and tile
    /// textures are left alone and nothing large stays behind.
    public static func render(_ session: ImageSession, pipeline: RenderPipeline,
                              parameters: EditParameters, output: RenderOutput,
                              longEdge: Int) throws -> PresentLayer {
        var output = output
        output.rawClipMask = false
        return try session.withTexturePool(.analysis) {
            defer { session.releasePooledTextures(in: .analysis) }
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
            let full = try pipeline.render(session, scale: .full, parameters: parameters, output: output, info: &info)
            let size = targetSize(width: full.width, height: full.height, longEdge: longEdge)
            guard let dest = pipeline.gpu.makePrivateTexture(width: size.width, height: size.height,
                                                             pixelFormat: .rgba16Float) else {
                throw RenderError.gpuBufferAllocationFailed
            }
            // The render is linear light already (an EDR display output):
            // no decode on the way in, no encode on the way out.
            try Exporter(gpu: pipeline.gpu).resample(
                full, frame: CropFrame(sensorSize: CGSize(width: full.width, height: full.height)),
                into: dest, sourceIsEncoded: false, encode: false)
            return PresentLayer(texture: dest, coverage: info.sensorRect, headroom: output.headroom)
        }
    }

    /// The resample's buffers, kept on the session between renders with
    /// the `.highQuality` pool and dropped with it.
    final class Scratch {
        var sampled: MTLTexture?
        var rows: MTLTexture?
        var dest: MTLTexture?
    }

    /// The editor's High Quality Preview (docs/Performance-Plan.md fix #20):
    /// the same render and resample as `render`, but the full-resolution
    /// textures stay in the session's `.highQuality` pool between renders
    /// (so the demosaic and its allocations are reused), the resample keeps
    /// its buffers, and while the caller has `ImageSession.defersGPUCompletion`
    /// set nothing waits for the GPU: the layer is ready once the caller's
    /// submission has completed. `avoiding` is the texture on screen, which
    /// the result must not be rendered into. The caller drops the pool
    /// (`releasePooledTextures(in: .highQuality)`) when the preview is no
    /// longer wanted; memory pressure and zoom changes drop it too.
    public static func renderKeepingBuffers(_ session: ImageSession, pipeline: RenderPipeline,
                                            parameters: EditParameters, output: RenderOutput,
                                            longEdge: Int, avoiding: MTLTexture?) throws -> PresentLayer {
        var output = output
        output.rawClipMask = false
        return try session.withTexturePool(.highQuality) {
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
            let full = try pipeline.render(session, scale: .full, parameters: parameters, output: output, info: &info)
            let size = targetSize(width: full.width, height: full.height, longEdge: longEdge)
            let frame = CropFrame(sensorSize: CGSize(width: full.width, height: full.height))
            let sizes = Exporter.resampleScratchSizes(frame: frame, width: size.width)
            let gpu = pipeline.gpu
            let scratch = session.highQualityScratch ?? Scratch()
            session.highQualityScratch = scratch
            func reuse(_ texture: MTLTexture?, _ w: Int, _ h: Int) -> MTLTexture? {
                if let texture, texture.width == w, texture.height == h, texture !== avoiding { return texture }
                return gpu.makePrivateTexture(width: w, height: h, pixelFormat: .rgba16Float)
            }
            guard let sampled = reuse(scratch.sampled, sizes.sampled.0, sizes.sampled.1),
                  let rows = reuse(scratch.rows, sizes.rows.0, sizes.rows.1),
                  let dest = reuse(scratch.dest, size.width, size.height),
                  let cmdBuffer = gpu.commandQueue.makeCommandBuffer() else {
                throw RenderError.gpuBufferAllocationFailed
            }
            scratch.sampled = sampled; scratch.rows = rows; scratch.dest = dest
            // The render is linear light already (an EDR display output):
            // no decode on the way in, no encode on the way out.
            try Exporter(gpu: gpu).encodeResample(full, frame: frame, into: dest, sampled: sampled, rows: rows,
                                                  sourceIsEncoded: false, encode: false, cmdBuffer: cmdBuffer)
            try session.commitRender(cmdBuffer, after: nil)
            return PresentLayer(texture: dest, coverage: info.sensorRect, headroom: output.headroom)
        }
    }

    /// The resampled size: the render's aspect, the long edge `longEdge`
    /// or the render's own, whichever is smaller, and at least a pixel.
    public static func targetSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height, 1)
        let scale = min(1, Double(max(longEdge, 1)) / Double(longest))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}
