import Foundation
import Metal
import simd

extension Exporter {
    /// A scene-linear render (`RenderOutput.sceneLinear`) cropped,
    /// straightened and turned upright at full size, as an rgba16Float
    /// texture: what DNG export writes (ExportWorker+DNG.swift).
    ///
    /// One bilinear sampling pass, the same map an ordinary export's pack
    /// uses, but nothing is clamped to 1 or encoded: highlights above
    /// white stay as they are, for the DNG to keep. Values below zero are
    /// cut to zero, which a raw file can't hold. Waits for the GPU.
    public func sceneLinearTexture(from texture: MTLTexture, rotation: ImageRotation,
                                   crop: CropParameters) throws -> MTLTexture {
        let frame = CropFrame(sensorSize: CGSize(width: texture.width, height: texture.height),
                              crop: crop, rotation: rotation)
        let (w, h) = Self.outputSize(frame: frame, maxLongEdge: nil)
        guard let dest = gpu.makePrivateTexture(width: w, height: h, pixelFormat: .rgba16Float),
              let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { throw ExportError.readbackFailed }
        let pso = gpu.exportSampleLinearPSO
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(dest, index: 1)
        var map = frame.normalizedSamplingMap()
        var decode: UInt32 = 0
        encoder.setBytes(&map, length: MemoryLayout<simd_float3x2>.size, index: 0)
        encoder.setBytes(&decode, length: 4, index: 1)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }
        return dest
    }
}

extension ExportPlan {
    /// The part of an edit a DNG export bakes into its pixels: everything
    /// that works on the scene's light before the tone curve. White balance,
    /// exposure, highlight recovery, noise reduction (classic and AI), lens
    /// and perspective corrections, spot healing, dust, red eye, touch-up
    /// blemishes, masks and crop. The rest is the look (contrast and the
    /// tone curve, Highlights to Blacks, colour grading, vibrance, texture,
    /// clarity, dehaze, defringe, skin smoothing, sharpening): it works on
    /// display-referred values, which a raw file doesn't hold, so it is left
    /// for the DNG's own edit.
    ///
    /// Built up from `defaults` field by field rather than by resetting the
    /// look on a copy of the edit, so a module added later stays out of the
    /// DNG until someone decides it belongs in it.
    public static func sceneReferred(_ edit: EditParameters, defaults: EditParameters) -> EditParameters {
        var p = defaults
        p.whiteBalance = edit.whiteBalance
        p.exposureEV = edit.exposureEV
        p.highlightRecovery = edit.highlightRecovery
        p.highlightThreshold = edit.highlightThreshold
        p.demosaic = edit.demosaic
        p.denoiseLuminance = edit.denoiseLuminance
        p.denoiseColor = edit.denoiseColor
        p.aiDenoise = edit.aiDenoise
        p.lensDistortion = edit.lensDistortion
        p.lensTCA = edit.lensTCA
        p.lensVignetting = edit.lensVignetting
        p.manualDistortion = edit.manualDistortion
        p.manualVignetting = edit.manualVignetting
        p.perspective = edit.perspective
        p.heals = edit.heals
        p.redEyes = edit.redEyes
        p.dust = edit.dust
        // Its blemish patches heal like spots; its skin, teeth and eye
        // sliders only run with masks, which a DNG render never builds.
        p.touchUp = edit.touchUp
        // Masks' range limits read the tone curve's contrast and grey point,
        // so they select what they selected in the edit.
        p.locals = edit.locals
        p.contrast = edit.contrast
        p.greyPoint = edit.greyPoint
        p.crop = edit.crop
        return p
    }
}
