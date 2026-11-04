import Foundation
import Metal
import simd

/// The Colour Mixer's Option-drag preview: while Option is held on an HSL
/// slider, the viewport shows only the colours that slider's band moves,
/// the rest in grey (`RenderOutput.hueIsolation`, `hueIsolate` in
/// Present.metal). A display pass after every stage, never part of a file.
extension RenderPipeline {
    /// Laid out as the kernel's `HueIsolationParams`.
    struct HueIsolationGPU {
        var toWorking: simd_float3x3
        var band: UInt32
    }

    func applyHueIsolation(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture, band: Int,
                           outputRole: ImageSession.TextureRole) throws -> MTLTexture {
        let result = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: outputRole)
        try Self.encodeHueIsolation(input: input, output: result, band: band, gpu: gpu, commandBuffer: cmdBuffer)
        return result
    }

    /// Encodes `hueIsolate` from `input` into `output` (same size). On its
    /// own so the tests can run it on a synthetic texture.
    static func encodeHueIsolation(input: MTLTexture, output: MTLTexture, band: Int,
                                   gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height else {
            throw RenderError.commandBufferFailed
        }
        let pso = try gpu.lazyPipeline(.hueIsolate)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        var params = HueIsolationGPU(toWorking: PixelReadout.displayP3ToWorking,
                                     band: UInt32(min(max(band, 0), 7)))
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<HueIsolationGPU>.stride, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + tw - 1) / tw, height: (input.height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }
}
