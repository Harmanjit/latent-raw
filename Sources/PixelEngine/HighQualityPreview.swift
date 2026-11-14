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

    /// The resampled size: the render's aspect, the long edge `longEdge`
    /// or the render's own, whichever is smaller, and at least a pixel.
    public static func targetSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height, 1)
        let scale = min(1, Double(max(longEdge, 1)) / Double(longest))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}
