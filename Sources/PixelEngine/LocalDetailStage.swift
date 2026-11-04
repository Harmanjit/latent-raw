import Foundation
import Metal
import simd

/// Mirror of `LocalDetailParams` in LocalDetail.metal.
struct LocalDetailGPU: Equatable {
    var effects: SIMD4<Float>   // texture, clarity, dehaze, sharpness
    var detail: SIMD4<Float>    // noise, defringe, mask slot, curve/colour/grain flags
    // The tone curve, Point Colour and grain (LocalToneColour.swift).
    var grain = SIMD4<Float>(repeating: 0)        // amount, size (sensor px), roughness, swatch count
    var pointTarget0 = SIMD4<Float>(repeating: 0), pointTarget1 = SIMD4<Float>(repeating: 0)
    var pointTarget2 = SIMD4<Float>(repeating: 0), pointTarget3 = SIMD4<Float>(repeating: 0)
    var pointShift0 = SIMD4<Float>(repeating: 0), pointShift1 = SIMD4<Float>(repeating: 0)
    var pointShift2 = SIMD4<Float>(repeating: 0), pointShift3 = SIMD4<Float>(repeating: 0)
}

/// Texture, clarity, dehaze, sharpness, noise and defringe inside masks
/// (Shaders/LocalDetail.metal): after the global presence stage and
/// before global sharpening, on the display-referred image. The colour
/// kernel writes each such mask into a channel of two RGBA textures as it
/// builds the masks (so ranges see the picture before any local changed
/// it, as the other sliders do); this stage reads them back.
///
/// Its blurs are presence's (`lcPrepare`, `lcDownsample`, `lcBlurH/V`) in
/// the stage's own texture roles, so it never overwrites what the global
/// stage is still reading. Skipped outright unless a visible mask uses
/// one of these sliders.
enum LocalDetailStage {
    /// One entry per mask that wants the stage, in the slot order
    /// `LocalsGPUPlan` assigned.
    static func params(for locals: [LocalAdjustment], shortSide: Float = 0) -> [LocalDetailGPU] {
        let plan = LocalsGPUPlan(locals: locals, slices: [:])
        return plan.detailSlots.sorted { $0.value < $1.value }.map { index, slot in
            let l = locals[index]
            var gpu = LocalDetailGPU(effects: SIMD4(l.texture, l.clarity, l.dehaze, l.sharpness),
                                     detail: SIMD4(max(l.noise, 0), max(l.defringe, 0), Float(slot),
                                                   Float(l.toneColourFlags)))
            let swatches = l.activePointColours.map(\.sanitized)
            gpu.grain = SIMD4(LocalToneColour.grain(l.grain, shortSide: shortSide), Float(swatches.count))
            var targets = [SIMD4<Float>](repeating: .zero, count: 4), shifts = targets
            for (k, c) in swatches.prefix(4).enumerated() {
                targets[k] = SIMD4(c.hue, c.saturation, c.value, c.range)
                shifts[k] = SIMD4(c.hueShift, c.saturationShift, c.luminanceShift, c.variance)
            }
            gpu.pointTarget0 = targets[0]; gpu.pointTarget1 = targets[1]
            gpu.pointTarget2 = targets[2]; gpu.pointTarget3 = targets[3]
            gpu.pointShift0 = shifts[0]; gpu.pointShift1 = shifts[1]
            gpu.pointShift2 = shifts[2]; gpu.pointShift3 = shifts[3]
            return gpu
        }
    }

    /// Whether any mask in the stage needs the blurs: the curve, Point
    /// Colour and grain read only the pixel itself.
    static func needsBlurs(_ locals: [LocalAdjustment]) -> Bool {
        locals.contains { l in
            l.wantsDetailStage && (l.texture != 0 || l.clarity != 0 || l.dehaze != 0 || l.sharpness != 0
                || l.noise > 0 || l.defringe > 0)
        }
    }

    struct Blurs {
        /// Render px: ~1 and ~4 sensor px, and 1.2% of the short side.
        var small: Float, medium: Float, large: Float
    }

    static func encode(input: MTLTexture, output: MTLTexture, maskA: MTLTexture, maskB: MTLTexture,
                       params: [LocalDetailGPU], blurs: Blurs, isLinear: Bool, headroom: Float,
                       curveTable: [Float]? = nil, frame: LocalDetailFrameGPU = .init(tileOrigin: .zero, binSpan: 1, seed: 0),
                       needsBlurs: Bool = true,
                       session: ImageSession, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height, !params.isEmpty else {
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
            let tw = pso.threadExecutionWidth
            let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
            encoder.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            encoder.endEncoding()
        }

        let pair = try session.texture(width: w, height: h, pixelFormat: .rg16Float, role: .localDetailPair)
        var linear: UInt32 = isLinear ? 1 : 0
        var room = headroom
        try pass(gpu.lcPreparePSO, [input, pair], width: w, height: h) { e in
            e.setBytes(&linear, length: 4, index: 0)
            e.setBytes(&room, length: 4, index: 1)
        }

        func blurred(sigma: Float, role: ImageSession.TextureRole,
                     scratch: ImageSession.TextureRole) throws -> MTLTexture {
            var factor = 1
            while sigma / Float(factor) > 10, factor < 16 { factor *= 2 }
            var source = pair
            var bw = w, bh = h
            if factor > 1 {
                bw = max(1, w / factor); bh = max(1, h / factor)
                let shrunk = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: scratch)
                var f = Int32(factor)
                try pass(gpu.lcDownsamplePSO, [pair, shrunk], width: bw, height: bh) { e in
                    e.setBytes(&f, length: 4, index: 0)
                }
                source = shrunk
            }
            var weights = RenderPipeline.wideGaussianWeights(sigma: sigma / Float(factor))
            var taps = Int32(weights.count)
            let tmp = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: .localDetailScratch)
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
        // Only the curve, Point Colour or grain: no blur is read, so the
        // unblurred pair stands in for all three.
        let small = needsBlurs ? try blurred(sigma: blurs.small, role: .localDetailSmall, scratch: .localDetailDownA) : pair
        let medium = needsBlurs ? try blurred(sigma: blurs.medium, role: .localDetailMedium, scratch: .localDetailDownB) : pair
        let large = needsBlurs ? try blurred(sigma: blurs.large, role: .localDetailLarge, scratch: .localDetailDownC) : pair
        // Metal wants the curve buffer bound even when no mask reads it.
        let table = curveTable ?? [Float](repeating: 0, count: 4)
        guard let curves = gpu.device.makeBuffer(bytes: table, length: table.count * 4, options: .storageModeShared) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        var frame = frame

        let pso = try gpu.lazyPipeline(.localDetailApply)
        var packed = params
        var count = Int32(params.count)
        try pass(pso, [input, pair, small, medium, large, maskA, maskB, output], width: w, height: h) { e in
            e.setBytes(&packed, length: packed.count * MemoryLayout<LocalDetailGPU>.stride, index: 0)
            e.setBytes(&count, length: 4, index: 1)
            e.setBytes(&linear, length: 4, index: 2)
            e.setBytes(&room, length: 4, index: 3)
            e.setBuffer(curves, offset: 0, index: 4)
            e.setBytes(&frame, length: MemoryLayout<LocalDetailFrameGPU>.stride, index: 5)
        }
    }
}

extension RenderPipeline {
    /// Binds everything the colour kernel reads about the locals: the
    /// packed locals (16, 17), their components (27), the overlay style
    /// (28, 29) and the detail-stage masks it writes (30; textures 4, 5).
    /// With no mask wanting the detail stage nothing is written, and 1×1
    /// stand-ins fill the texture slots Metal requires bound.
    func encodeLocals(_ encoder: MTLComputeCommandEncoder, session: ImageSession,
                      locals: [LocalAdjustment], slices: [UUID: Int32],
                      width: Int, height: Int, output: RenderOutput) throws {
        let plan = LocalsGPUPlan(locals: locals, slices: slices)
        var packed = plan.locals
        if packed.isEmpty { packed = [LocalAdjustGPU(LocalAdjustment(name: "", shape: .whole), brushSlice: 0)] }
        var localCount = Int32(locals.count)
        var components = plan.components.isEmpty ? [MaskComponentGPU()] : plan.components
        encoder.setBytes(&packed, length: packed.count * MemoryLayout<LocalAdjustGPU>.stride, index: 16)
        encoder.setBytes(&localCount, length: 4, index: 17)
        encoder.setBytes(&components, length: components.count * MemoryLayout<MaskComponentGPU>.stride, index: 27)

        let style = output.maskOverlayStyle
        let write: UInt32 = plan.detailSlots.isEmpty ? 0 : 1
        var overlay = MaskOverlayParamsGPU(style: SIMD4<Float>(style.colour, min(max(style.opacity, 0), 1)),
                                           flags: SIMD4<UInt32>(UInt32(style.mode.rawValue), write, 0, 0))
        encoder.setBytes(&overlay, length: MemoryLayout<MaskOverlayParamsGPU>.stride, index: 28)

        let size = write == 0 ? (1, 1) : (width, height)
        let maskA = try session.texture(width: size.0, height: size.1, pixelFormat: .rgba16Float, role: .localMaskA)
        let maskB = try session.texture(width: size.0, height: size.1, pixelFormat: .rgba16Float, role: .localMaskB)
        encoder.setTexture(maskA, index: 4)
        encoder.setTexture(maskB, index: 5)
    }

    /// Whether the local detail stage has anything to do.
    static func wantsLocalDetail(_ parameters: EditParameters) -> Bool {
        parameters.locals.prefix(LocalAdjustment.maximumCount).contains(where: \.wantsDetailStage)
    }

    /// The local detail stage on `input` (the display-referred image after
    /// global presence), reading the masks the colour kernel wrote.
    func applyLocalDetail(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture,
                          preview: Bool, parameters: EditParameters, output: RenderOutput,
                          binSpan: Float, tileOrigin: SIMD2<Float> = .zero) throws -> MTLTexture {
        let locals = Array(parameters.locals.prefix(LocalAdjustment.maximumCount))
        let summary = session.file.summary
        let shortSide = Float(min(summary.rawWidth, summary.rawHeight))
        let params = LocalDetailStage.params(for: locals, shortSide: shortSide)
        let slots = LocalsGPUPlan(locals: locals, slices: [:]).detailSlots
        // A pattern of its own, so local grain doesn't line up with the global grain's.
        let seed = Grain.seed(cameraModel: summary.cameraModel, captureTime: summary.captureTime.timeIntervalSince1970,
                              width: summary.rawWidth, height: summary.rawHeight) ^ 0x9E37_79B9
        let w = input.width, h = input.height
        let maskA = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: .localMaskA)
        let maskB = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: .localMaskB)
        let result = try session.texture(width: w, height: h, pixelFormat: .rgba16Float,
                                         role: preview ? .localDetailPreview : .localDetail)
        try LocalDetailStage.encode(input: input, output: result, maskA: maskA, maskB: maskB, params: params,
                                    blurs: .init(small: 1.0 / binSpan, medium: 4.0 / binSpan,
                                                 large: 0.012 * shortSide / binSpan),
                                    isLinear: !output.encoded, headroom: output.headroom,
                                    curveTable: LocalToneColour.curveTable(for: locals, slots: slots),
                                    frame: LocalDetailFrameGPU(tileOrigin: tileOrigin, binSpan: binSpan, seed: seed),
                                    needsBlurs: LocalDetailStage.needsBlurs(locals),
                                    session: session, gpu: gpu, commandBuffer: cmdBuffer)
        return result
    }
}

/// `MaskOverlayParams` in ColorPipeline.metal. Layout must match it exactly.
struct MaskOverlayParamsGPU {
    var style: SIMD4<Float>
    var flags: SIMD4<UInt32>
}
