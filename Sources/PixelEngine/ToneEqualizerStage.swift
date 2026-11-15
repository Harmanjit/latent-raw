import Foundation
import CoreGraphics
import Metal
import simd
import LensKit

// The tone equalizer's render stage (ToneEqualizer.swift, Shaders/
// ToneEqualizer.metal), between the lens corrections and the colour kernel.
//
// The mask is made once per set of inputs and kept on the session: the
// demosaiced, healed, lens-corrected image of the WHOLE frame, shrunk to a
// grid whose long side is `gridLongSide` cells, its log luminance
// guided-filtered there. A render of the whole image (the preview, an
// export) makes it from its own pixels; a render of part of it (a 100 %
// tile, the magnifier) first makes it from a small whole-image render in
// the analysis pool when the session has none for these settings. Either
// way every render samples one whole-image mask, so a tile and an export
// show what the preview showed. Exposure is left out of the mask (a shift
// in log space passes straight through the filter) and added per render,
// so an exposure drag never remakes it.

/// What a render asks of the tone equalizer, or nil when it asks nothing.
enum ToneEqualizerStage {
    /// The mask grid's long side, in cells.
    static let gridLongSide = 512
    /// How large a whole-image render a tile's mask is made from.
    static let sourceLongSide = 1024

    struct Request {
        let equalizer: ToneEqualizer
        /// The bands change the picture.
        let applies: Bool
        /// Show Mask is on.
        let wantsMaskView: Bool

        init?(parameters: EditParameters, output: RenderOutput, cameraRGBOnly: Bool) {
            guard !cameraRGBOnly else { return nil }
            let equalizer = parameters.toneEqualizer
            let applies = equalizer.isActive
            guard applies || output.toneEqualizerAnalysis || output.toneEqualizerMaskView else { return nil }
            self.equalizer = equalizer
            self.applies = applies
            self.wantsMaskView = output.toneEqualizerMaskView
        }
    }

    /// Everything the mask depends on. Deliberately not the region, the
    /// scale or exposure, so a tile reuses the preview's mask and a band or
    /// exposure drag reuses it too.
    struct MaskKey: Equatable {
        var multipliers: SIMD4<Float>
        var yRow: SIMD3<Float>
        var smoothing: Float
        var edgeRefinement: Float
        // What stages 3 to 7 read.
        var aiDenoise: Float
        var aiDenoiseModel: String?
        var denoise: SIMD2<Float>
        var noiseDetail: NoiseReductionDetail
        var heals: [HealPatch]
        var redEyes: [RedEyeSpot]
        var flatField: FlatFieldCorrection?
        var lensSwitches: [Bool]
        var lensValues: [Float]
        var autoCA: AutoChromaticAberration?
        var lens: LensCorrection?
        var perspective: PerspectiveCorrection

        init(session: ImageSession, parameters p: EditParameters, cameraToWorking: simd_float3x3,
             multipliers: SIMD4<Float>) {
            self.multipliers = multipliers
            yRow = ToneEqualizerStage.luminanceRow(cameraToWorking)
            smoothing = p.toneEqualizer.smoothingAmount
            edgeRefinement = p.toneEqualizer.edgeRefinementAmount
            aiDenoise = p.aiDenoise
            aiDenoiseModel = session.aiDenoiseModel
            denoise = SIMD2(p.denoiseLuminance, p.denoiseColor)
            noiseDetail = p.noiseDetail
            heals = p.allHealPatches
            redEyes = p.redEyes
            flatField = p.flatField
            lensSwitches = [p.lensDistortion, p.lensTCA, p.lensVignetting]
            lensValues = [p.manualDistortion, p.manualVignetting, p.manualVignettingMidpoint]
            autoCA = p.autoCA
            lens = session.lensCorrection(for: p)
            perspective = p.perspective
        }
    }

    /// The Rec.2020 luminance row carried back through the camera matrix:
    /// camera RGB to working-space Y in one dot product.
    static func luminanceRow(_ cameraToWorking: simd_float3x3) -> SIMD3<Float> {
        simd_transpose(cameraToWorking) * SIMD3<Float>(0.2627, 0.6780, 0.0593)
    }

    static func gridSize(sensorWidth: Int, sensorHeight: Int) -> (width: Int, height: Int) {
        let w = max(sensorWidth, 1), h = max(sensorHeight, 1)
        if w >= h {
            return (gridLongSide, max(8, Int((Float(gridLongSide) * Float(h) / Float(w)).rounded())))
        }
        return (max(8, Int((Float(gridLongSide) * Float(w) / Float(h)).rounded())), gridLongSide)
    }

    static func dispatch(_ encoder: MTLComputeCommandEncoder, pso: MTLComputePipelineState, width: Int, height: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    private static func pass(_ commandBuffer: MTLCommandBuffer, _ pso: MTLComputePipelineState,
                             _ textures: [MTLTexture], width: Int, height: Int,
                             _ bind: (MTLComputeCommandEncoder) -> Void = { _ in }) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        bind(encoder)
        dispatch(encoder, pso: pso, width: width, height: height)
        encoder.endEncoding()
    }

    // MARK: - The mask

    private struct PrepareParams {
        var yRow: SIMD4<Float>
        var sourceRect: SIMD4<Float>
        var sensorSize: SIMD4<Float>
    }

    /// Encodes the whole-image mask from `source` (covering the sensor from
    /// `sourceOrigin`, `binSpan` sensor pixels per pixel) into the store.
    static func encodeMask(source: MTLTexture, sourceOrigin: CGPoint, binSpan: Float, sensorSize: SIMD2<Float>,
                           yRow: SIMD3<Float>, equalizer: ToneEqualizer, store: ToneEqualizerMaskStore,
                           gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        let grid = gridSize(sensorWidth: Int(sensorSize.x), sensorHeight: Int(sensorSize.y))
        let t = try store.textures(gpu: gpu, width: grid.width, height: grid.height)
        var params = PrepareParams(yRow: SIMD4(yRow, 0),
                                   sourceRect: SIMD4(Float(sourceOrigin.x), Float(sourceOrigin.y), max(binSpan, 1), 0),
                                   sensorSize: SIMD4(sensorSize.x, sensorSize.y, 0, 0))
        try pass(commandBuffer, try gpu.lazyPipeline(.toneEqPrepare), [source, t.pair],
                 width: grid.width, height: grid.height) { e in
            e.setBytes(&params, length: MemoryLayout<PrepareParams>.stride, index: 0)
        }
        let sigma = equalizer.smoothingFraction * Float(gridLongSide)
        try blur(t.pair, into: t.means, scratch: t.scratchH, alternate: t.scratchAlt, sigma: sigma,
                 gpu: gpu, commandBuffer: commandBuffer)
        var epsilon = equalizer.epsilon
        try pass(commandBuffer, try gpu.lazyPipeline(.toneEqCoefficients), [t.means, t.rawCoefficients],
                 width: grid.width, height: grid.height) { e in
            e.setBytes(&epsilon, length: 4, index: 0)
        }
        try blur(t.rawCoefficients, into: t.coefficients, scratch: t.scratchH, alternate: t.scratchAlt, sigma: sigma,
                 gpu: gpu, commandBuffer: commandBuffer)
        try pass(commandBuffer, try gpu.lazyPipeline(.toneEqGridMask), [t.pair, t.coefficients, t.gridMask],
                 width: grid.width, height: grid.height)
        store.pendingReadback = true
    }

    /// A Gaussian of `sigma` grid cells as repeated passes of the presence
    /// stage's separable blur (its kernel stops at 65 taps), `source` to
    /// `destination`, never writing the texture it reads.
    private static func blur(_ source: MTLTexture, into destination: MTLTexture, scratch: MTLTexture,
                             alternate: MTLTexture, sigma: Float, gpu: GPUContext,
                             commandBuffer: MTLCommandBuffer) throws {
        let passes = max(1, Int(ceil((sigma / 10) * (sigma / 10))))
        var weights = RenderPipeline.wideGaussianWeights(sigma: sigma / sqrt(Float(passes)))
        var taps = Int32(weights.count)
        var current = source
        for k in 0..<passes {
            // The last pass lands in `destination`; earlier ones alternate
            // with `alternate` so no pass reads what it writes.
            let fromEnd = passes - 1 - k
            let target = fromEnd % 2 == 0 ? destination : alternate
            try pass(commandBuffer, gpu.lcBlurHPSO, [current, scratch], width: source.width, height: source.height) { e in
                e.setBytes(&weights, length: weights.count * 4, index: 0)
                e.setBytes(&taps, length: 4, index: 1)
            }
            try pass(commandBuffer, gpu.lcBlurVPSO, [scratch, target], width: source.width, height: source.height) { e in
                e.setBytes(&weights, length: weights.count * 4, index: 0)
                e.setBytes(&taps, length: 4, index: 1)
            }
            current = target
        }
    }

    // MARK: - Applying it

    private struct ApplyParams {
        var yRow: SIMD4<Float>
        var placement: SIMD4<Float>
        var sensorSize: SIMD4<Float>
        var clipLevel: SIMD4<Float>
        var table: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }

    struct Placement {
        var tileOrigin: SIMD2<Float>
        var binSpan: Float
        var sensorSize: SIMD2<Float>
    }

    /// The gain pass over this render's camera RGB. Returns the image and,
    /// when `maskOutput` is given, writes the mask there too.
    static func encodeApply(input: MTLTexture, output: MTLTexture, coefficients: MTLTexture, maskOutput: MTLTexture,
                            writesMask: Bool, equalizer: ToneEqualizer, yRow: SIMD3<Float>, exposureEV: Float,
                            placement: Placement, clipLevel: SIMD3<Float>, highlightThreshold: Float,
                            highlightStrength: Float, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        var table = equalizer.gainTable()
        var params = ApplyParams(
            yRow: SIMD4(yRow, exposureEV),
            placement: SIMD4(placement.tileOrigin.x, placement.tileOrigin.y, placement.binSpan, 0),
            sensorSize: SIMD4(placement.sensorSize.x, placement.sensorSize.y,
                              equalizer.exposureCompensation, equalizer.contrastFactor),
            clipLevel: SIMD4(clipLevel, highlightThreshold),
            table: SIMD4(highlightStrength, ToneEqualizer.lutRange.lowerBound, ToneEqualizer.lutRange.upperBound,
                         Float(table.count)),
            flags: SIMD4(writesMask ? 1 : 0, 0, 0, 0))
        try pass(commandBuffer, try gpu.lazyPipeline(.toneEqApply), [input, output, coefficients, maskOutput],
                 width: input.width, height: input.height) { e in
            e.setBytes(&params, length: MemoryLayout<ApplyParams>.stride, index: 0)
            e.setBytes(&table, length: table.count * 4, index: 1)
        }
    }

    /// Show Mask: `mask` in grey, the size of `like`, in its place.
    static func encodeMaskView(mask: MTLTexture, like: MTLTexture, output: RenderOutput, session: ImageSession,
                               preview: Bool, gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let result = try session.texture(width: like.width, height: like.height, pixelFormat: .rgba16Float,
                                         role: preview ? .toneEqualizerViewPreview : .toneEqualizerView)
        var linear: UInt32 = output.encoded ? 0 : 1
        try pass(commandBuffer, try gpu.lazyPipeline(.toneEqMaskView), [mask, result],
                 width: like.width, height: like.height) { e in
            e.setBytes(&linear, length: 4, index: 0)
        }
        return result
    }
}

// MARK: - The session's mask

/// The whole-image mask for one session, its scratch textures and the copy
/// the panel reads. Its own textures, not the session's pools, so neither a
/// pool release nor another render can overwrite the mask a tile samples.
final class ToneEqualizerMaskStore {
    struct Textures {
        let pair, scratchH, scratchAlt, means, rawCoefficients, coefficients, gridMask: MTLTexture
    }

    /// What the mask in `textures` was made from; nil before the first.
    var key: ToneEqualizerStage.MaskKey?
    private(set) var current: Textures?
    /// The grid mask waits to be copied back once the render completes.
    var pendingReadback = false
    /// The exposure the latest render added to the mask.
    var exposureEV: Float = 0
    private(set) var values: (width: Int, height: Int, values: [Float])?
    /// Counts the read-backs, carried on the snapshot as its `generation`.
    private(set) var generation = 0

    var coefficients: MTLTexture? { key == nil ? nil : current?.coefficients }

    func textures(gpu: GPUContext, width: Int, height: Int) throws -> Textures {
        if let current, current.pair.width == width, current.pair.height == height { return current }
        func make(_ format: MTLPixelFormat, shared: Bool = false) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = shared ? .shared : .private
            guard let t = gpu.device.makeTexture(descriptor: d) else { throw RenderError.gpuBufferAllocationFailed }
            return t
        }
        let made = Textures(pair: try make(.rg32Float), scratchH: try make(.rg32Float), scratchAlt: try make(.rg32Float),
                            means: try make(.rg32Float), rawCoefficients: try make(.rg32Float),
                            coefficients: try make(.rg32Float), gridMask: try make(.r32Float, shared: true))
        current = made
        key = nil
        return made
    }

    /// After the command buffer that made the mask has completed: copies
    /// the grid mask back for the panel.
    func renderDidComplete() {
        guard pendingReadback, let mask = current?.gridMask else { return }
        pendingReadback = false
        let w = mask.width, h = mask.height
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            mask.getBytes(base, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        values = (w, h, out)
        generation &+= 1
    }

    var snapshot: ToneEqualizerMaskSnapshot? {
        guard let values, key != nil else { return nil }
        return ToneEqualizerMaskSnapshot(width: values.width, height: values.height, values: values.values,
                                         exposureEV: exposureEV, generation: generation)
    }
}

extension ImageSession {
    /// The tone equalizer's mask as the latest render that used it left
    /// it, for the panel's histogram, the readout and the on-image tool;
    /// nil until a render has made one.
    public var toneEqualizerMask: ToneEqualizerMaskSnapshot? { toneEqualizerStore.snapshot }
}

extension RenderPipeline {
    /// A render of part of the image: makes the session's whole-image mask
    /// first, from a small whole-image render of its own, unless the
    /// session already has one for these settings.
    func prepareToneEqualizerMask(session: ImageSession, parameters: EditParameters,
                                  request: ToneEqualizerStage.Request, cameraToWorking: simd_float3x3,
                                  multipliers: SIMD4<Float>) throws {
        let key = ToneEqualizerStage.MaskKey(session: session, parameters: parameters,
                                             cameraToWorking: cameraToWorking, multipliers: multipliers)
        let store = session.toneEqualizerStore
        guard store.key != key else { return }
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        let source = try session.withTexturePool(.analysis) {
            try withUnsafeMutablePointer(to: &info) { pointer in
                try renderStages(session, scale: .fitting(maxDimension: ToneEqualizerStage.sourceLongSide),
                                 parameters: parameters, output: .sceneLinear, cameraRGBOnly: false,
                                 stopAfterLens: true, info: pointer)
            }
        }
        guard let commandBuffer = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        let summary = session.file.summary
        try ToneEqualizerStage.encodeMask(source: source, sourceOrigin: info.sensorRect.origin,
                                          binSpan: info.isFullResolution ? 1 : Float(info.binQuads * 2),
                                          sensorSize: SIMD2(Float(summary.rawWidth), Float(summary.rawHeight)),
                                          yRow: key.yRow, equalizer: request.equalizer, store: store,
                                          gpu: gpu, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error { throw RenderError.commandBufferFailed }
        store.key = key
        store.renderDidComplete()
    }

    /// Stage 7b. Makes the mask from `input` when this render covers the
    /// whole image and the session has none for these settings, then
    /// applies the gain (when a band is moved) and writes the mask view
    /// (when Show Mask is on).
    func applyToneEqualizer(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture,
                            request: ToneEqualizerStage.Request, parameters: EditParameters,
                            cameraToWorking: simd_float3x3, multipliers: SIMD4<Float>,
                            profile: ProfileRenderState?, renderInfo: RenderInfo, binSpan: Float,
                            preview: Bool) throws -> (image: MTLTexture, maskView: MTLTexture?) {
        let summary = session.file.summary
        let sensorSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        let key = ToneEqualizerStage.MaskKey(session: session, parameters: parameters,
                                             cameraToWorking: cameraToWorking, multipliers: multipliers)
        let store = session.toneEqualizerStore
        if store.key != key {
            // Only a whole-image render gets here without a mask: a region
            // render made its own first (`prepareToneEqualizerMask`).
            try ToneEqualizerStage.encodeMask(source: input, sourceOrigin: renderInfo.sensorRect.origin,
                                              binSpan: binSpan, sensorSize: sensorSize, yRow: key.yRow,
                                              equalizer: request.equalizer, store: store, gpu: gpu,
                                              commandBuffer: cmdBuffer)
            store.key = key
        }
        let exposureEV = parameters.exposureEV + (profile?.exposureOffset ?? 0)
        store.exposureEV = exposureEV
        guard request.applies || request.wantsMaskView, let coefficients = store.coefficients else {
            return (input, nil)
        }
        let output = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .toneEqualizedPreview : .toneEqualized)
        let mask = request.wantsMaskView
            ? try session.texture(width: input.width, height: input.height, pixelFormat: .r16Float,
                                  role: .toneEqualizerMask)
            : try session.texture(width: 1, height: 1, pixelFormat: .r16Float, role: .toneEqualizerMask)
        // The mask view alone leaves the picture as it is: no gain.
        let equalizer = request.applies ? request.equalizer
            : ToneEqualizer(maskExposure: request.equalizer.maskExposure, maskContrast: request.equalizer.maskContrast)
        try ToneEqualizerStage.encodeApply(
            input: input, output: output, coefficients: coefficients, maskOutput: mask,
            writesMask: request.wantsMaskView, equalizer: equalizer, yRow: key.yRow, exposureEV: exposureEV,
            placement: .init(tileOrigin: SIMD2(Float(renderInfo.sensorRect.origin.x),
                                               Float(renderInfo.sensorRect.origin.y)),
                             binSpan: binSpan, sensorSize: sensorSize),
            clipLevel: session.highlightClipLevel(multipliers: multipliers),
            highlightThreshold: parameters.highlightThreshold, highlightStrength: parameters.highlightRecovery,
            gpu: gpu, commandBuffer: cmdBuffer)
        return (request.applies ? output : input, request.wantsMaskView ? mask : nil)
    }
}
