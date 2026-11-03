import Foundation
import Metal
import simd
import LensKit

/// Mirrors of the parameter structs in Shaders/DetailEffects.metal. The
/// field order (and so the layout) must match the shader's exactly.
struct DfxDenoiseParamsGPU {
    var contrast: Float
    var smoothness: Float
    var reach: Float
    var noiseScale: Float
}

struct DfxSharpenParamsGPU {
    var amount: Float
    var threshold: Float
    var detail: Float
    var masking: Float
    var binSpan: Float
    var inputIsLinear: UInt32
    var showMask: UInt32
    var padding: UInt32 = 0
}

struct DfxEffectsParamsGPU {
    var tileOrigin: SIMD2<Float>
    var cropCentre: SIMD2<Float>
    var cropHalfSize: SIMD2<Float>
    var binSpan: Float
    var headroom: Float
    var inputIsLinear: UInt32
    var vignetteOn: UInt32
    var vignetteStyle: UInt32
    var vignetteAmount: Float
    var vignetteMidpoint: Float
    var vignetteRoundness: Float
    var vignetteFeather: Float
    var vignetteHighlights: Float
    var cropCos: Float
    var cropSin: Float
    var cropAspect: Float
    var grainOn: UInt32
    var grainAmount: Float
    var grainCell: Float
    var grainRoughness: Float
    var grainSeed: UInt32
}

extension AutoChromaticAberration {
    /// As a Lensfun linear TCA model: red and blue read at a radius scaled
    /// by 1 + the measured excess, everywhere in the frame.
    var tcaModel: TCAModel {
        TCAModel(red: SIMD3(0, 0, 1 + red), blue: SIMD3(0, 0, 1 + blue))
    }
}

extension RenderPipeline {
    /// Sensor pixels the noise reduction Smoothness average reaches.
    static let colourSmoothnessReach: Float = 8

    /// Noise reduction's second pass (Contrast, Smoothness).
    func refineDenoise(session: ImageSession, cmdBuffer: MTLCommandBuffer, original: MTLTexture,
                       denoised: MTLTexture, parameters p: EditParameters, binSpan: Float) throws -> MTLTexture {
        let output = try session.texture(width: denoised.width, height: denoised.height,
                                         pixelFormat: .rgba16Float, role: .denoiseRefined)
        let pso = try gpu.lazyPipeline(.dfxDenoiseRefine)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        var params = DfxDenoiseParamsGPU(contrast: p.noiseDetail.luminanceContrast,
                                         smoothness: p.noiseDetail.colourSmoothness,
                                         reach: max(1, Self.colourSmoothnessReach / binSpan),
                                         noiseScale: 1 / binSpan)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(original, index: 0)
        encoder.setTexture(denoised, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<DfxDenoiseParamsGPU>.stride, index: 0)
        Self.dfxDispatch(encoder, pso: pso, width: output.width, height: output.height)
        encoder.endEncoding()
        return output
    }

    /// The last pass of sharpening when Detail or Masking is in use, or the
    /// mask is being previewed: `dfxSharpenApply` in place of `sharpenApply`.
    func encodeRefinedSharpen(cmdBuffer: MTLCommandBuffer, input: MTLTexture, blurred: MTLTexture,
                              output: MTLTexture, parameters p: EditParameters,
                              renderOutput: RenderOutput, binSpan: Float) throws {
        let pso = try gpu.lazyPipeline(.dfxSharpenApply)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        var params = DfxSharpenParamsGPU(amount: p.sharpenAmount, threshold: p.sharpenThreshold,
                                         detail: p.sharpenDetail, masking: p.sharpenMasking, binSpan: binSpan,
                                         inputIsLinear: renderOutput.encoded ? 0 : 1,
                                         showMask: renderOutput.sharpenMaskPreview ? 1 : 0)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(blurred, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<DfxSharpenParamsGPU>.stride, index: 0)
        Self.dfxDispatch(encoder, pso: pso, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    /// Post-crop vignetting and grain, on the display-referred image.
    func applyEffects(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture,
                      outputRole: ImageSession.TextureRole, parameters p: EditParameters,
                      output: RenderOutput, renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let result = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: outputRole)
        let summary = session.file.summary
        var params = Self.effectsParams(parameters: p, sensorSize: SIMD2(Float(summary.rawWidth), Float(summary.rawHeight)),
                                        tileOrigin: SIMD2(Float(renderInfo.sensorRect.origin.x),
                                                          Float(renderInfo.sensorRect.origin.y)),
                                        binSpan: binSpan, output: output,
                                        seed: Grain.seed(cameraModel: summary.cameraModel,
                                                         captureTime: summary.captureTime.timeIntervalSince1970,
                                                         width: summary.rawWidth, height: summary.rawHeight))
        try Self.encodeEffects(input: input, output: result, params: &params, gpu: gpu, commandBuffer: cmdBuffer)
        return result
    }

    /// The shader's parameters for an edit, on its own so the tests can
    /// run the kernel over a synthetic texture.
    static func effectsParams(parameters p: EditParameters, sensorSize: SIMD2<Float>, tileOrigin: SIMD2<Float>,
                              binSpan: Float, output: RenderOutput, seed: UInt32) -> DfxEffectsParamsGPU {
        let v = p.postCropVignette, g = p.grain
        let crop = p.crop
        let centre = crop.centre * sensorSize
        let half = crop.size * sensorSize * 0.5
        let radians = Float(crop.radians)
        return DfxEffectsParamsGPU(
            tileOrigin: tileOrigin, cropCentre: centre, cropHalfSize: half,
            binSpan: binSpan, headroom: output.headroom, inputIsLinear: output.encoded ? 0 : 1,
            vignetteOn: v.isActive ? 1 : 0, vignetteStyle: v.style == .colourPriority ? 1 : 0,
            vignetteAmount: v.amount, vignetteMidpoint: v.midpoint, vignetteRoundness: v.roundness,
            vignetteFeather: v.feather, vignetteHighlights: v.highlights,
            cropCos: cos(radians), cropSin: sin(radians),
            cropAspect: half.y > 0 ? half.x / half.y : 1,
            grainOn: g.isActive ? 1 : 0, grainAmount: g.amount,
            grainCell: g.cellSensorPixels(shortSide: min(sensorSize.x, sensorSize.y)),
            grainRoughness: g.roughness, grainSeed: seed)
    }

    static func encodeEffects(input: MTLTexture, output: MTLTexture, params: inout DfxEffectsParamsGPU,
                              gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        let pso = try gpu.lazyPipeline(.dfxEffectsApply)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<DfxEffectsParamsGPU>.stride, index: 0)
        dfxDispatch(encoder, pso: pso, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    static func dfxDispatch(_ encoder: MTLComputeCommandEncoder, pso: MTLComputePipelineState,
                            width: Int, height: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
