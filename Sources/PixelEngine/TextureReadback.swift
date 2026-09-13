import Foundation
import Metal

/// Copies a GPU texture's pixels back to the CPU.
///
/// Pipeline textures are private-storage (DESIGN.md §7.2) so the GPU can
/// apply lossless compression to them, and private storage isn't
/// CPU-readable at all — reading one directly faults inside the driver
/// rather than returning an error. So: blit into a shared-storage copy
/// first, then read that.
///
/// Used by the exporter and by tests that compare renders numerically.
public enum TextureReadback {
    /// The pixels of an `rgba16Float` texture, row-major, four halfs each.
    public static func float16Pixels(of texture: MTLTexture, gpu: GPUContext) throws -> [Float16] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width,
            height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let readable = gpu.device.makeTexture(descriptor: descriptor),
              let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else {
            throw ExportError.readbackFailed
        }

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                   sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                   sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                   to: readable, destinationSlice: 0, destinationLevel: 0,
                   destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }

        var pixels = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        readable.getBytes(&pixels,
                           bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.size,
                           from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                           mipmapLevel: 0)
        return pixels
    }
}
