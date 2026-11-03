import Foundation
import Metal
import simd

/// Mirror of `LensBlurParamsGPU` in LensBlur.metal.
struct LensBlurParamsGPU {
    var tileOrigin: SIMD2<Float>
    var sensorSize: SIMD2<Float>
    var binSpan: Float
    var factor: Float
    var maxRadius: Float
    var focusFar: Float
    var focusNear: Float
    var fullBlurDepth: Float
    var boost: Float
    var isLinear: UInt32
    var headroom: Float
    var shape: UInt32
    var tapCount: UInt32
    var padding: Float = 0
}

/// Encodes Lens Blur (Shaders/LensBlur.metal) onto a command buffer: the
/// shrunk copy, the gather and the composite, on the display-referred
/// image straight after the colour stage. Separate from RenderPipeline so
/// tests can run it on a synthetic texture and depth map, as they do
/// TouchUpStage.
enum LensBlurStage {
    /// Where the render sits on the sensor and how it is encoded: what
    /// the kernels need to find a pixel's depth and its linear light.
    struct Geometry: Equatable {
        var tileOrigin: SIMD2<Float>
        var sensorSize: SIMD2<Float>
        var binSpan: Float
        var isLinear: Bool
        var headroom: Float
    }

    /// The largest blur, in shrunk pixels, the gather is asked for: its
    /// taps sit on eight rings out to this radius, two pixels apart, so
    /// the shrunk copy is made small enough that the blur fits.
    static let gatherRadius: Float = 16

    /// How many render pixels make one shrunk pixel for a largest blur of
    /// `radius` render pixels.
    static func reduction(forRadius radius: Float) -> Int {
        guard radius.isFinite, radius > gatherRadius else { return 1 }
        return min(Int((radius / gatherRadius).rounded(.up)), 64)
    }

    /// The gather's taps on the unit disc: the centre, then eight rings
    /// with six more taps each than the last, so the disc is covered
    /// evenly (217 taps, 1.7 KB, under setBytes' 4 KB). Each ring is
    /// turned a little against the last so no spoke of taps lines up.
    static let taps: [SIMD2<Float>] = {
        var taps: [SIMD2<Float>] = [.zero]
        let rings = 8
        for ring in 1...rings {
            let count = 6 * ring
            let radius = Float(ring) / Float(rings)
            for i in 0..<count {
                let angle = (Float(i) + 0.5 * Float(ring % 2)) / Float(count) * 2 * .pi + Float(ring) * 0.37
                taps.append(SIMD2(cos(angle), sin(angle)) * radius)
            }
        }
        return taps
    }()

    static func params(blur: LensBlur, geometry g: Geometry, factor: Int, maxRadiusRender: Float) -> LensBlurParamsGPU {
        let b = blur.sanitized
        return LensBlurParamsGPU(
            tileOrigin: g.tileOrigin, sensorSize: g.sensorSize, binSpan: g.binSpan, factor: Float(factor),
            maxRadius: maxRadiusRender / Float(factor), focusFar: b.focusFar, focusNear: b.focusNear,
            fullBlurDepth: LensBlur.fullBlurDepth, boost: b.boost / 100, isLinear: g.isLinear ? 1 : 0,
            headroom: g.headroom, shape: b.bokeh.gpuIndex, tapCount: UInt32(taps.count))
    }

    /// Blurs `input` by `blur` over `depth` (the session's r8Unorm depth
    /// map) and returns the result, a texture of the session's in the
    /// lensBlur role (lensBlurPreview for the binned preview, so a tile
    /// never overwrites the preview it is drawn over).
    static func encode(input: MTLTexture, depth: MTLTexture, blur: LensBlur, geometry: Geometry,
                       session: ImageSession, preview: Bool, gpu: GPUContext,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .lensBlurPreview : .lensBlur)
        try encode(input: input, output: output, depth: depth, blur: blur, geometry: geometry,
                   session: session, gpu: gpu, commandBuffer: commandBuffer)
        return output
    }

    /// The same into a texture the caller owns (the tests' entry point).
    static func encode(input: MTLTexture, output: MTLTexture, depth: MTLTexture, blur: LensBlur, geometry g: Geometry,
                       session: ImageSession, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height else {
            throw RenderError.commandBufferFailed
        }
        let w = input.width, h = input.height
        let longEdge = max(g.sensorSize.x, g.sensorSize.y)
        let radius = blur.sanitized.maximumRadius(longEdge: longEdge) / max(g.binSpan, 1e-3)
        let factor = reduction(forRadius: radius)
        let rw = max(1, (w + factor - 1) / factor), rh = max(1, (h + factor - 1) / factor)
        let reduced = try session.texture(width: rw, height: rh, pixelFormat: .rgba16Float, role: .lensBlurReduced)
        let gathered = try session.texture(width: rw, height: rh, pixelFormat: .rgba16Float, role: .lensBlurGathered)
        var p = params(blur: blur, geometry: g, factor: factor, maxRadiusRender: radius)
        var tapList = taps

        try pass(try gpu.lazyPipeline(.lensBlurPrepare), [input, reduced, depth], size: (rw, rh),
                 commandBuffer: commandBuffer) { e in
            e.setBytes(&p, length: MemoryLayout<LensBlurParamsGPU>.stride, index: 0)
        }
        try pass(try gpu.lazyPipeline(.lensBlurGather), [reduced, gathered, depth], size: (rw, rh),
                 commandBuffer: commandBuffer) { e in
            e.setBytes(&p, length: MemoryLayout<LensBlurParamsGPU>.stride, index: 0)
            e.setBytes(&tapList, length: tapList.count * MemoryLayout<SIMD2<Float>>.stride, index: 1)
        }
        try pass(try gpu.lazyPipeline(.lensBlurComposite), [input, output, gathered, depth], size: (w, h),
                 commandBuffer: commandBuffer) { e in
            e.setBytes(&p, length: MemoryLayout<LensBlurParamsGPU>.stride, index: 0)
        }
    }

    /// Show Depth over `input`'s size: the depth map in colour with the
    /// focus range washed light (viewport only).
    static func encodeDepthView(input: MTLTexture, depth: MTLTexture, blur: LensBlur, geometry g: Geometry,
                                session: ImageSession, preview: Bool, gpu: GPUContext,
                                commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .depthViewPreview : .depthView)
        var p = params(blur: blur, geometry: g, factor: 1, maxRadiusRender: 0)
        try pass(try gpu.lazyPipeline(.lensBlurDepthView), [input, output, depth], size: (input.width, input.height),
                 commandBuffer: commandBuffer) { e in
            e.setBytes(&p, length: MemoryLayout<LensBlurParamsGPU>.stride, index: 0)
        }
        return output
    }

    private static func pass(_ pso: MTLComputePipelineState, _ textures: [MTLTexture], size: (Int, Int),
                             commandBuffer: MTLCommandBuffer, _ bind: (MTLComputeCommandEncoder) -> Void) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        bind(encoder)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (size.0 + tw - 1) / tw, height: (size.1 + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
    }
}

extension RenderPipeline {
    /// The render's place on the sensor and its encoding, for the lens
    /// blur stage and Show Depth.
    func lensBlurGeometry(session: ImageSession, output: RenderOutput, renderInfo: RenderInfo,
                          binSpan: Float) -> LensBlurStage.Geometry {
        let summary = session.file.summary
        return LensBlurStage.Geometry(
            tileOrigin: SIMD2(Float(renderInfo.sensorRect.origin.x), Float(renderInfo.sensorRect.origin.y)),
            sensorSize: SIMD2(Float(summary.rawWidth), Float(summary.rawHeight)),
            binSpan: binSpan, isLinear: !output.encoded, headroom: output.headroom)
    }
}
