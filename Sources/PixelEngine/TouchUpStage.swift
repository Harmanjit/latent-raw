import Foundation
import Metal
import simd

/// Mirror of `TouchUpParamsGPU` in TouchUp.metal.
struct TouchUpParamsGPU {
    var sliders: SIMD4<Float>      // skin, teeth, eyes, overlay (0 or 1)
    var tileOrigin: SIMD2<Float>
    var sensorSize: SIMD2<Float>
    var binSpan: Float
    var isLinear: UInt32
    var headroom: Float
    var padding: Float = 0
}

/// Encodes the touch-up stage (Shaders/TouchUp.metal) onto a command
/// buffer: skin smoothing, teeth whitening and brighter eyes over the
/// session's region masks, display-referred, between the output
/// transform and presence (docs/Retouch.md §7). Separate from
/// RenderPipeline so tests can run it on a synthetic texture, like
/// HealStage.
///
/// Wave 0: only `touchUpApply` is encoded, and it copies the input
/// through. Wave 1 (touch-up kernel) adds the luma preparation and the
/// two blurs and the real per-pixel work.
enum TouchUpStage {
    struct Params: Equatable {
        /// 0…1 (the sliders / 100).
        var skin: Float, teeth: Float, eyes: Float
        /// Render px (sensor px ÷ binSpan).
        var sigmaFine: Float, sigmaMid: Float
        var isLinear: Bool, headroom: Float
        var tileOrigin: SIMD2<Float>, binSpan: Float, sensorSize: SIMD2<Float>
        var overlay: Bool
    }

    /// Encodes lcPrepare, the two luma blurs (lcDownsample/lcBlurH/lcBlurV
    /// with wideGaussianWeights) into the touchUp* roles and touchUpApply;
    /// `masks` is the session's 3-slice r8Unorm array (skin, teeth, eyes).
    static func encode(input: MTLTexture, output: MTLTexture, masks: MTLTexture, params: Params,
                       session: ImageSession, preview: Bool, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height,
              input.pixelFormat == output.pixelFormat else {
            throw RenderError.commandBufferFailed
        }
        let pso = try gpu.lazyPipeline(.touchUpApply)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        var gpuParams = TouchUpParamsGPU(
            sliders: SIMD4(params.skin, params.teeth, params.eyes, params.overlay ? 1 : 0),
            tileOrigin: params.tileOrigin, sensorSize: params.sensorSize, binSpan: params.binSpan,
            isLinear: params.isLinear ? 1 : 0, headroom: params.headroom)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(masks, index: 2)
        encoder.setBytes(&gpuParams, length: MemoryLayout<TouchUpParamsGPU>.stride, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + tw - 1) / tw, height: (input.height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }
}
