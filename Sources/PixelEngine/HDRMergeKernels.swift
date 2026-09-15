import Foundation
import Metal
import simd
import RawCore

// The GPU half of Photo Merge's HDR merge: the kernels in
// Shaders/MergeHDR.metal, encoded for MergeKit, which decides what to
// merge and with which exposures (MergeKit/HDR/HDRMerger.swift). They live
// here rather than in MergeKit because the sensor buffer, the lazily built
// pipelines and the RCD passes they reuse are PixelEngine's own.

/// How to read one Bayer frame's photosites for a merge.
///
/// **Normalised units**, the merge's own: a photosite's raw value minus its
/// colour's black level, divided by white minus the lowest black level.
/// Dividing every colour by the same range keeps the camera's colour
/// balance (a separate range per colour would tint the result by a
/// fraction of a percent), while subtracting each colour's own black keeps
/// shadows neutral when one colour's black sits a few counts higher.
public struct HDRFrameLevels: Sendable, Equatable {
    /// Black level of each colour, in sensor counts: red, green, blue and
    /// the Bayer quad's second green (`RawSummary.channelBlackLevels`).
    public var channelBlack: SIMD4<Float>
    /// The sensor's nominal white (`RawSummary.whiteLevel`).
    public var white: Float
    /// The raw value at and above which a photosite counts as clipped.
    public var clipRaw: Float

    public init(channelBlack: SIMD4<Float>, white: Float, clipRaw: Float) {
        self.channelBlack = channelBlack
        self.white = white
        self.clipRaw = clipRaw
    }

    /// What (raw - black) is multiplied by to reach normalised units.
    public var scale: Float {
        let range = white - channelBlack.min()
        return range > 0 ? 1 / range : 0
    }

    /// The normalised value at which each colour clips: red, green (the
    /// lower of the two greens), blue.
    public var channelClip: SIMD3<Float> {
        let clip = (SIMD4<Float>(repeating: clipRaw) - channelBlack) * scale
        return SIMD3(clip.x, min(clip.y, clip.w), clip.z)
    }
}

/// Errors from the merge kernels.
public enum HDRMergeKernelError: Error, CustomStringConvertible, Equatable {
    /// Only a Bayer raw with its sensor plane loaded can be merged.
    case notABayerFrame
    /// The frame isn't the size the merge was set up for.
    case sizeMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .notABayerFrame: "not a Bayer raw with its sensor data loaded"
        case .sizeMismatch(let expected, let actual): "expected a \(expected) frame, got \(actual)"
        }
    }
}

/// One-off merge kernels: the analysis frames and the preview's reduction.
public enum HDRMergeKernels {
    /// A reduced frame read back to the CPU: `width x height` pixels of four
    /// Float32 each, row by row. Red, green and blue are the block's mean in
    /// normalised units at unit white balance (black subtracted, not
    /// clamped); alpha is the share of its photosites that were clipped.
    public struct AnalysisImage: Sendable {
        public let width: Int
        public let height: Int
        /// Photosites per side of each pixel's block.
        public let span: Int
        public let pixels: [Float]
    }

    /// `file`'s sensor plane reduced by `span` on each side (see
    /// `mergeHDRBinnedAnalysis` for why this isn't the pipeline's binned
    /// render). Blocks at the right and bottom edges are cut short.
    public static func analysisImage(of file: RawFile, span: Int, levels: HDRFrameLevels,
                                     gpu: GPUContext) throws -> AnalysisImage {
        guard case .bayer(let order) = file.summary.cfaPattern, let plane = file.sensorPlane,
              let buffer = gpu.makeSharedBuffer(wrapping: plane) else { throw HDRMergeKernelError.notABayerFrame }
        let rawW = file.summary.rawWidth, rawH = file.summary.rawHeight
        let span = max(1, span)
        let w = (rawW + span - 1) / span, h = (rawH + span - 1) / span
        let pso = try gpu.lazyPipeline(.mergeHDRBinnedAnalysis)
        let out = try makeTexture(gpu, width: w, height: h, format: .rgba32Float, storage: .shared)
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var width32 = UInt32(rawW), height32 = UInt32(rawH)
        var black = levels.channelBlack, invRange = levels.scale, clipRaw = levels.clipRaw
        var pattern = order, span32 = UInt32(span)
        encoder.setBytes(&width32, length: 4, index: 1)
        encoder.setBytes(&height32, length: 4, index: 2)
        encoder.setBytes(&black, length: 16, index: 3)
        encoder.setBytes(&invRange, length: 4, index: 4)
        encoder.setBytes(&clipRaw, length: 4, index: 5)
        encoder.setBytes(&pattern, length: 1, index: 6)
        encoder.setBytes(&span32, length: 4, index: 7)
        encoder.setTexture(out, index: 0)
        dispatch(encoder, pso: pso, width: w, height: h)
        encoder.endEncoding()
        try run(commands)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        out.getBytes(&pixels, bytesPerRow: w * 4 * MemoryLayout<Float>.size,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return AnalysisImage(width: w, height: h, span: span, pixels: pixels)
    }

    /// An `rgba16Float` texture box-filtered down by a whole `span` and
    /// multiplied by `scale`, into a shared-storage texture the CPU can
    /// read. Waits for the GPU.
    public static func downsample(_ texture: MTLTexture, span: Int, scale: Float = 1,
                                  gpu: GPUContext) throws -> MTLTexture {
        let span = max(1, span)
        let w = max(1, texture.width / span), h = max(1, texture.height / span)
        let pso = try gpu.lazyPipeline(.mergeHDRDownsample)
        let out = try makeTexture(gpu, width: w, height: h, format: .rgba16Float, storage: .shared)
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(out, index: 1)
        var span32 = UInt32(span), factor = scale
        encoder.setBytes(&span32, length: 4, index: 0)
        encoder.setBytes(&factor, length: 4, index: 1)
        dispatch(encoder, pso: pso, width: w, height: h)
        encoder.endEncoding()
        try run(commands)
        return out
    }

    // MARK: - Helpers

    static func makeTexture(_ gpu: GPUContext, width: Int, height: Int, format: MTLPixelFormat,
                            storage: MTLStorageMode = .private,
                            extraUsage: MTLTextureUsage = []) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = storage
        descriptor.usage = [.shaderRead, .shaderWrite, extraUsage]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        return texture
    }

    static func dispatch(_ encoder: MTLComputeCommandEncoder, pso: MTLComputePipelineState, width: Int, height: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    static func run(_ commands: MTLCommandBuffer) throws {
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { throw RenderError.commandBufferFailed }
    }
}

/// The running sums of an HDR merge, and the textures each frame passes
/// through on its way into them.
///
/// Frames are added one at a time; each call uploads nothing (the sensor
/// plane is wrapped in place), encodes its three stages (prepare, RCD,
/// accumulate) into one command buffer and waits for it, so the caller can let go of the `RawFile` before
/// opening the next. Every texture is made on the first frame and reused
/// by the rest, so GPU memory is the same for 3 frames as for 9:
///
/// | texture | format | 24 MP |
/// |---|---|---|
/// | accumulator (sum of w * radiance, sum of w) | rgba32Float | 387 MB |
/// | CFA plane | r32Float | 97 MB |
/// | clip mask | r8Unorm | 24 MB |
/// | RCD's six intermediates | mixed | 775 MB |
///
/// `releaseScratch()` frees all but the accumulator once the last frame is
/// in, before `resolve()` makes the half-float result (194 MB).
///
/// Not Sendable: one merge, used from one task.
public final class HDRMergeAccumulator {
    public let width: Int
    public let height: Int
    private let gpu: GPUContext
    private let pipeline: RenderPipeline
    private let accumulator: MTLTexture
    /// The per-frame textures, by format and purpose.
    private var scratch: [String: MTLTexture] = [:]
    public private(set) var framesAdded = 0

    /// Allocates the accumulator, cleared to zero.
    public init(gpu: GPUContext, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw RenderError.gpuBufferAllocationFailed }
        self.gpu = gpu
        self.width = width
        self.height = height
        pipeline = RenderPipeline(gpu: gpu)
        // New textures aren't documented to start at zero, so the sums
        // start from an explicit clear: a render pass that only loads with
        // clear, which is why this texture alone is also a render target.
        accumulator = try HDRMergeKernels.makeTexture(gpu, width: width, height: height, format: .rgba32Float,
                                                      extraUsage: .renderTarget)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = accumulator
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let clear = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.commandBufferFailed
        }
        clear.endEncoding()
        try HDRMergeKernels.run(commands)
    }

    /// GPU memory a merge of this size holds at its peak, in bytes: the
    /// accumulator, the per-frame textures and the frame's sensor plane.
    public static func estimatedPeakBytes(width: Int, height: Int) -> Int {
        let pixels = width * height
        let accumulator = 16, cfa = 4, mask = 1, sensor = 2
        let rcd = 2 + 4 + 8 + 2 + 8 + 8
        return pixels * (accumulator + cfa + mask + sensor + rcd)
    }

    /// Demosaics `file` and adds it to the sums.
    ///
    /// - Parameters:
    ///   - multipliers: the white balance RCD works with (red, green, blue),
    ///     the same for every frame; divided back out before summing.
    ///   - relativeEV: stops of light relative to the brightest frame (0 or less).
    ///   - weightFloor: the least weight any pixel of this frame gets: 1e-4
    ///     for the darkest frame, 0 for the others.
    public func add(_ file: RawFile, levels: HDRFrameLevels, multipliers: SIMD3<Float>,
                    relativeEV: Double, weightFloor: Float) throws {
        guard case .bayer(let order) = file.summary.cfaPattern, let plane = file.sensorPlane,
              let buffer = gpu.makeSharedBuffer(wrapping: plane) else { throw HDRMergeKernelError.notABayerFrame }
        guard file.summary.rawWidth == width, file.summary.rawHeight == height else {
            throw HDRMergeKernelError.sizeMismatch(expected: "\(width) x \(height)",
                                                   actual: "\(file.summary.rawWidth) x \(file.summary.rawHeight)")
        }
        let cfa = try scratchTexture(.r32Float, "cfa")
        let mask = try scratchTexture(.r8Unorm, "clipMask")
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        // 1. Black, normalisation, white balance, clip mask.
        let prepare = try gpu.lazyPipeline(.mergeHDRRawPrepare)
        guard let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(prepare)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var rawWidth = UInt32(width)
        var black = levels.channelBlack, invRange = levels.scale, clipRaw = levels.clipRaw
        var mul = SIMD4<Float>(multipliers, 1)
        var pattern = order
        encoder.setBytes(&rawWidth, length: 4, index: 1)
        encoder.setBytes(&black, length: 16, index: 2)
        encoder.setBytes(&invRange, length: 4, index: 3)
        encoder.setBytes(&clipRaw, length: 4, index: 4)
        encoder.setBytes(&mul, length: 16, index: 5)
        encoder.setBytes(&pattern, length: 1, index: 6)
        encoder.setTexture(cfa, index: 0)
        encoder.setTexture(mask, index: 1)
        HDRMergeKernels.dispatch(encoder, pso: prepare, width: width, height: height)
        encoder.endEncoding()

        // 2. RCD, the pipeline's own passes, into textures kept for the next frame.
        let rgb = try pipeline.encodeRCD(cmdBuffer: commands, cfa: cfa, order: order) { format, role in
            try scratchTexture(format, "rcd-\(role)")
        }

        // 3. Unit white balance, radiance, weight, sums.
        let accumulate = try gpu.lazyPipeline(.mergeHDRAccumulate)
        guard let adder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        adder.setComputePipelineState(accumulate)
        adder.setTexture(rgb, index: 0)
        adder.setTexture(mask, index: 1)
        adder.setTexture(accumulator, index: 2)
        var inverse = SIMD4<Float>(1 / max(multipliers.x, 1e-6), 1 / max(multipliers.y, 1e-6),
                                   1 / max(multipliers.z, 1e-6), 1)
        var clip = SIMD4<Float>(levels.channelClip, 1)
        var radianceScale = Float(pow(2, -relativeEV))
        var weightScale = Float(pow(2, relativeEV))
        var floor = weightFloor
        adder.setBytes(&inverse, length: 16, index: 0)
        adder.setBytes(&clip, length: 16, index: 1)
        adder.setBytes(&radianceScale, length: 4, index: 2)
        adder.setBytes(&weightScale, length: 4, index: 3)
        adder.setBytes(&floor, length: 4, index: 4)
        HDRMergeKernels.dispatch(adder, pso: accumulate, width: width, height: height)
        adder.endEncoding()

        try HDRMergeKernels.run(commands)
        framesAdded += 1
    }

    /// Frees the per-frame textures. Adding another frame makes them again.
    public func releaseScratch() {
        scratch.removeAll()
    }

    /// The merged image so far: an `rgba16Float` private texture of camera
    /// RGB at unit white balance, relative to the brightest frame. Waits for
    /// the GPU.
    public func resolve() throws -> MTLTexture {
        let merged = try HDRMergeKernels.makeTexture(gpu, width: width, height: height, format: .rgba16Float)
        let pso = try gpu.lazyPipeline(.mergeHDRResolve)
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(accumulator, index: 0)
        encoder.setTexture(merged, index: 1)
        HDRMergeKernels.dispatch(encoder, pso: pso, width: width, height: height)
        encoder.endEncoding()
        try HDRMergeKernels.run(commands)
        return merged
    }

    private func scratchTexture(_ format: MTLPixelFormat, _ purpose: String) throws -> MTLTexture {
        let key = "\(purpose)-\(format.rawValue)"
        if let texture = scratch[key] { return texture }
        let texture = try HDRMergeKernels.makeTexture(gpu, width: width, height: height, format: format)
        scratch[key] = texture
        return texture
    }
}
