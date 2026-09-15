import Foundation
import Metal
import simd

/// Mirror of `ExportResampleUniforms` in Export.metal: two floats then two
/// uints, 16 bytes with no padding on either side.
struct ExportResampleUniforms {
    var scale: Float
    var filterScale: Float
    var encode: UInt32
    var unused: UInt32 = 0
}

/// The filter resized exports use, in Swift. The shader has its own copy
/// (`exportFilterAxis` in Export.metal); this one sizes the passes, and
/// the tests build a CPU reference from it to compare the GPU against.
///
/// Lanczos 3, evaluated in linear light. A reduction stretches the filter
/// by the same factor, so a 2x smaller image reads twice as many input
/// pixels per output pixel and nothing finer than the new grid survives
/// to alias.
enum ExportResampler {
    /// Radius of the filter in input pixels at 1:1.
    static let support = 3.0

    /// Most input pixels one output pixel reads along one axis. Exports
    /// bin whole Bayer quads down towards the target first, so the
    /// remaining reduction is normally under 2x (13 taps at most). The
    /// cap only bounds the work of a pass for extreme requests, beyond
    /// which the filter stops widening and very fine detail can alias.
    static let maximumTaps = 64

    static func weight(_ x: Double) -> Double {
        func sinc(_ x: Double) -> Double {
            guard abs(x) >= 1e-6 else { return 1 }
            return sin(.pi * x) / (.pi * x)
        }
        return abs(x) < support ? sinc(x) * sinc(x / support) : 0
    }

    /// The scale the filter is evaluated at for a pass from `from` to `to`
    /// pixels: the reduction itself (never above 1: exports don't
    /// enlarge), raised where the widened filter would need more than
    /// `maximumTaps`.
    static func filterScale(from: Int, to: Int) -> Double {
        let scale = min(Double(to) / Double(from), 1)
        return max(scale, 2 * support / Double(maximumTaps - 2))
    }
}

extension Exporter {
    /// Encodes and runs the resize: `frame`'s map at the canvas size into a
    /// float intermediate, then the filter along rows and along columns
    /// into `dest`, all in one command buffer. `sourceIsEncoded` decodes a
    /// display-encoded render to linear light first; `encode` applies the
    /// sRGB curve on the way into `dest` (a file's pixels) rather than
    /// leaving it linear (a gain map's inputs).
    func resample(_ texture: MTLTexture, frame: CropFrame, into dest: MTLTexture,
                  sourceIsEncoded: Bool, encode: Bool) throws {
        let canvas = Self.outputSize(frame: frame, maxLongEdge: nil)
        let w = dest.width, h = dest.height
        guard let sampled = gpu.makePrivateTexture(width: canvas.0, height: canvas.1, pixelFormat: .rgba16Float),
              let rows = gpu.makePrivateTexture(width: w, height: canvas.1, pixelFormat: .rgba16Float),
              let cmdBuffer = gpu.commandQueue.makeCommandBuffer() else {
            throw ExportError.readbackFailed
        }

        func pass(_ pso: MTLComputePipelineState, _ input: MTLTexture, _ output: MTLTexture,
                  bind: (MTLComputeCommandEncoder) -> Void) throws {
            guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { throw ExportError.readbackFailed }
            encoder.setComputePipelineState(pso)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            bind(encoder)
            let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
            encoder.dispatchThreadgroups(
                MTLSize(width: (output.width + tw - 1) / tw, height: (output.height + th - 1) / th, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            encoder.endEncoding()
        }
        func uniforms(from: Int, to: Int, encode: Bool) -> ExportResampleUniforms {
            ExportResampleUniforms(scale: Float(Double(to) / Double(from)),
                                   filterScale: Float(ExportResampler.filterScale(from: from, to: to)),
                                   encode: encode ? 1 : 0)
        }

        try pass(gpu.exportSampleLinearPSO, texture, sampled) { encoder in
            var map = frame.normalizedSamplingMap()
            var decode: UInt32 = sourceIsEncoded ? 1 : 0
            encoder.setBytes(&map, length: MemoryLayout<simd_float3x2>.size, index: 0)
            encoder.setBytes(&decode, length: 4, index: 1)
        }
        try pass(gpu.exportResampleRowsPSO, sampled, rows) { encoder in
            var u = uniforms(from: canvas.0, to: w, encode: false)
            encoder.setBytes(&u, length: MemoryLayout<ExportResampleUniforms>.size, index: 0)
        }
        try pass(gpu.exportResampleColumnsPSO, rows, dest) { encoder in
            var u = uniforms(from: canvas.1, to: h, encode: encode)
            encoder.setBytes(&u, length: MemoryLayout<ExportResampleUniforms>.size, index: 0)
        }
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }
    }
}
