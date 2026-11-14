import Foundation
import Metal

// The LMMSE demosaic (Shaders/LMMSE.metal): `DemosaicMethod.lmmse`, the
// choice for high-ISO files. RCD stays the default.

extension RenderPipeline {
    /// The LMMSE passes on any CFA texture, with the textures they write
    /// handed out by `texture` (the session's pool, or a test's own). Like
    /// `encodeRCD`, every pass goes into the one command buffer, and the
    /// last two ping-pong between two RGB textures.
    func encodeLMMSE(cmdBuffer: MTLCommandBuffer, cfa: MTLTexture, order: UInt8,
                     texture: (MTLPixelFormat, ImageSession.TextureRole) throws -> MTLTexture) throws -> MTLTexture {
        let w = cfa.width, h = cfa.height
        // Float32: the variances are differences of squares of small
        // differences, which half precision would round to nothing.
        let diff = try texture(.rg32Float, .lmmseDiff)
        let smooth = try texture(.rg32Float, .lmmseSmooth)
        let rgbA = try texture(.rgba16Float, .cameraRGB)
        let rgbB = try texture(.rgba16Float, .lmmseScratch)

        func pass(_ kernel: GPUContext.LazyKernel, textures: [MTLTexture], passOrder: Bool) throws {
            let pso = try gpu.lazyPipeline(kernel)
            guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
                throw RenderError.commandBufferFailed
            }
            encoder.setComputePipelineState(pso)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            if passOrder {
                var order_ = order
                encoder.setBytes(&order_, length: 1, index: 0)
            }
            let tw = pso.threadExecutionWidth
            let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
            encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            encoder.endEncoding()
        }

        // 1. Horizontal and vertical estimates of green minus colour.
        try pass(.lmmseDifferences, textures: [cfa, diff], passOrder: true)
        // 2. Their low-passed signal.
        try pass(.lmmseSmooth, textures: [diff, smooth], passOrder: false)
        // 3. Green everywhere, by the fused LMMSE estimate.
        try pass(.lmmseGreen, textures: [cfa, diff, smooth, rgbA], passOrder: true)
        // 4. Red at blue sites and blue at red sites.
        try pass(.lmmseRedBlueAtOpposite, textures: [rgbA, rgbB], passOrder: true)
        // 5. Red and blue at green sites.
        try pass(.lmmseRedBlueAtGreen, textures: [rgbB, rgbA], passOrder: true)
        return rgbA
    }

    /// LMMSE into the session's pooled textures.
    func demosaicLMMSE(session: ImageSession, cmdBuffer: MTLCommandBuffer, cfa: MTLTexture,
                       order: UInt8) throws -> MTLTexture {
        try encodeLMMSE(cmdBuffer: cmdBuffer, cfa: cfa, order: order) { format, role in
            try session.texture(width: cfa.width, height: cfa.height, pixelFormat: format, role: role)
        }
    }
}
