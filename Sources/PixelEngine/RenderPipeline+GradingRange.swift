import Foundation
import Metal
import simd

/// Colour Grading's Option-drag preview: while Option is held on a wheel's
/// luminance slider, the viewport shows that range's weight in grey, white
/// where the range acts fully and black where it doesn't
/// (`RenderOutput.gradingRangePreview`, `gradingRangeView` in
/// Present.metal). A display pass after every stage, like the Colour
/// Mixer's hue isolation, never part of a file.
extension RenderPipeline {
    /// Laid out as the kernel's `GradingRangeParams`.
    struct GradingRangeGPU {
        var toWorking: simd_float3x3
        /// Range (0 shadows, 1 midtones, 2 highlights), Balance, Blending,
        /// headroom.
        var info: SIMD4<Float>
    }

    func applyGradingRangePreview(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture, range: Int,
                                  parameters: EditParameters, headroom: Float,
                                  outputRole: ImageSession.TextureRole) throws -> MTLTexture {
        let result = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: outputRole)
        try Self.encodeGradingRangePreview(input: input, output: result, range: range,
                                           balance: parameters.splitToning.balance,
                                           blending: parameters.colour.grading.blending, headroom: headroom,
                                           gpu: gpu, commandBuffer: cmdBuffer)
        return result
    }

    /// Encodes `gradingRangeView` from `input` into `output` (same size).
    /// On its own so the tests can run it on a synthetic texture.
    static func encodeGradingRangePreview(input: MTLTexture, output: MTLTexture, range: Int, balance: Float,
                                          blending: Float, headroom: Float,
                                          gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height else {
            throw RenderError.commandBufferFailed
        }
        let pso = try gpu.lazyPipeline(.gradingRangeView)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        var params = GradingRangeGPU(toWorking: PixelReadout.displayP3ToWorking,
                                     info: SIMD4(Float(min(max(range, 0), 2)), balance, blending, max(headroom, 1)))
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<GradingRangeGPU>.stride, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + tw - 1) / tw, height: (input.height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }
}
