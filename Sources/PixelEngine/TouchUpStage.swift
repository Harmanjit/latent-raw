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
/// The ingredients are presence's: perceptual luma from `lcPrepare`,
/// blurred by `lcDownsample` and `lcBlurH`/`lcBlurV` with the same
/// weights, in the stage's own texture roles so a render that wants
/// both stages never has one overwrite the other's blurs.
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
    /// `preview` names the render for the caller's benefit: the blurs are
    /// consumed within this command buffer, so a preview and a full
    /// render share their roles, as presence's do.
    static func encode(input: MTLTexture, output: MTLTexture, masks: MTLTexture, params: Params,
                       session: ImageSession, preview: Bool, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height,
              input.pixelFormat == output.pixelFormat,
              masks.textureType == .type2DArray, masks.arrayLength >= 3 else {
            throw RenderError.commandBufferFailed
        }
        let w = input.width, h = input.height

        func pass(_ pso: MTLComputePipelineState, _ textures: [MTLTexture], width: Int, height: Int,
                  _ bind: (MTLComputeCommandEncoder) -> Void) throws {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RenderError.commandBufferFailed
            }
            encoder.setComputePipelineState(pso)
            for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
            bind(encoder)
            dispatch(encoder, pso, (width, height))
            encoder.endEncoding()
        }

        // 1. Perceptual luma (lcPrepare's pair; its dark channel goes unread).
        let pair = try session.texture(width: w, height: h, pixelFormat: .rg16Float, role: .touchUpPair)
        var isLinear: UInt32 = params.isLinear ? 1 : 0
        var headroom = params.headroom
        try pass(gpu.lcPreparePSO, [input, pair], width: w, height: h) { e in
            e.setBytes(&isLinear, length: 4, index: 0)
            e.setBytes(&headroom, length: 4, index: 1)
        }

        // 2. Blur at a sigma in this render's pixels, on a box-shrunk copy
        //    when the kernel would be too wide (the mid blur at full
        //    resolution is up to 48 sensor px). The apply kernel samples
        //    the result by position, so a shrunk blur needs no upsampling.
        func blurred(sigma: Float, role: ImageSession.TextureRole,
                     scratch: ImageSession.TextureRole) throws -> MTLTexture {
            var factor = 1
            while sigma / Float(factor) > 10, factor < 16 { factor *= 2 }
            var source = pair
            var bw = w, bh = h
            if factor > 1 {
                bw = max(1, w / factor); bh = max(1, h / factor)
                let small = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: scratch)
                var f = Int32(factor)
                try pass(gpu.lcDownsamplePSO, [pair, small], width: bw, height: bh) { e in
                    e.setBytes(&f, length: 4, index: 0)
                }
                source = small
            }
            var weights = RenderPipeline.wideGaussianWeights(sigma: sigma / Float(factor))
            var taps = Int32(weights.count)
            let tmp = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: .touchUpScratch)
            let out = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: role)
            try pass(gpu.lcBlurHPSO, [source, tmp], width: bw, height: bh) { e in
                e.setBytes(&weights, length: weights.count * 4, index: 0)
                e.setBytes(&taps, length: 4, index: 1)
            }
            try pass(gpu.lcBlurVPSO, [tmp, out], width: bw, height: bh) { e in
                e.setBytes(&weights, length: weights.count * 4, index: 0)
                e.setBytes(&taps, length: 4, index: 1)
            }
            return out
        }
        let fine = try blurred(sigma: params.sigmaFine, role: .touchUpFine, scratch: .touchUpDownA)
        let mid = try blurred(sigma: params.sigmaMid, role: .touchUpMid, scratch: .touchUpDownB)

        // 3. Apply.
        let pso = try gpu.lazyPipeline(.touchUpApply)
        var gpuParams = TouchUpParamsGPU(
            sliders: SIMD4(params.skin, params.teeth, params.eyes, params.overlay ? 1 : 0),
            tileOrigin: params.tileOrigin, sensorSize: params.sensorSize, binSpan: params.binSpan,
            isLinear: isLinear, headroom: headroom)
        try pass(pso, [input, output, masks, fine, mid], width: w, height: h) { e in
            e.setBytes(&gpuParams, length: MemoryLayout<TouchUpParamsGPU>.stride, index: 0)
        }
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState,
                                 _ size: (Int, Int)) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (size.0 + tw - 1) / tw, height: (size.1 + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
