import Foundation
import Metal
import simd
import Synchronization

/// View › Show Raw Clipping: a mask of the pixels where a sensor channel
/// reached its clip level, from the camera-space image the colour stage
/// reads (after the demosaic, white balance, healing and lens corrections,
/// before highlight reconstruction), so it lines up with the render it
/// rides along with. Only the viewport asks for it
/// (`RenderOutput.rawClipMask`); the presenter draws it in magenta
/// (`PresentOverlays.rawClipping`), apart from the clipping overlay's
/// output clipping. Never part of a file.
extension RenderPipeline {
    func encodeRawClipMask(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture,
                           multipliers: SIMD4<Float>, preview: Bool) throws {
        let mask = try session.texture(width: input.width, height: input.height, pixelFormat: .r8Unorm,
                                       role: preview ? .rawClipPreview : .rawClip)
        try RawClipping.encodeMask(input: input, output: mask,
                                   clipLevel: session.highlightClipLevel(multipliers: multipliers),
                                   gpu: gpu, commandBuffer: cmdBuffer)
        session.noteRawClipMask(mask, preview: preview)
    }
}

/// The raw clipping mask's kernel (`rawClipMask` in Present.metal), on its
/// own so tests can run it on a synthetic texture.
public enum RawClipping {
    /// Pipelines by context. Built on first use, like the context's own
    /// lazy kernels, so a session that never shows raw clipping never
    /// compiles it.
    private static let pipelines = Mutex<[ObjectIdentifier: MTLComputePipelineState]>([:])

    static func pipeline(_ gpu: GPUContext) throws -> MTLComputePipelineState {
        try pipelines.withLock { built in
            if let existing = built[ObjectIdentifier(gpu)] { return existing }
            guard let function = gpu.library.makeFunction(name: "rawClipMask") else {
                throw GPUContextError.missingShaderFunction("rawClipMask")
            }
            let pso = try gpu.device.makeComputePipelineState(function: function)
            built[ObjectIdentifier(gpu)] = pso
            return pso
        }
    }

    /// Writes 1 into `output` (same size, single channel) wherever a
    /// channel of `input` reaches `clipLevel`, else 0.
    static func encodeMask(input: MTLTexture, output: MTLTexture, clipLevel: SIMD3<Float>,
                           gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height else {
            throw RenderError.commandBufferFailed
        }
        let pso = try pipeline(gpu)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        var level = SIMD4<Float>(clipLevel, 1)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&level, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (output.width + tw - 1) / tw,
                                             height: (output.height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }
}
