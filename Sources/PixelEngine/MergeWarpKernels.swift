import Foundation
import Metal
import simd

// The GPU half of Photo Merge's frame alignment: the kernels in
// Shaders/MergeWarp.metal, encoded for MergeKit. MergeKit/Align measures
// how frames moved (on the CPU); these shrink frames for that measurement
// and move frames by what it found.

/// Frame alignment's GPU kernels.
///
/// **Coordinates.** Homographies here use full-resolution pixel coordinates
/// with a top-left origin: (0, 0) is the image's top-left corner and the
/// centre of pixel (i, j) is (i + 0.5, j + 0.5). A homography `h` maps a
/// point by multiplying (x, y, 1) and dividing by the third component; it
/// maps points of the *moving* frame to where they appear in the
/// *reference* frame, the direction `FrameAligner` reports.
///
/// **Memory.** A warp needs its source and one output texture and nothing
/// else: the kernels read the source directly, with no intermediate
/// copies, and run in bands of rows so no single command buffer covers a
/// whole 45 MP frame (a long GPU command can trip the system's GPU
/// watchdog and stalls the display while it runs).
public enum MergeWarpKernels {
    /// How `warpMask` samples.
    public enum MaskSampling: UInt32, Sendable {
        /// A blend of the four nearest values, for soft masks and weights.
        case bilinear = 0
        /// The largest value among the pixels the colour warp's sample
        /// draws on, for clip masks: an output counts as clipped if any
        /// clipped pixel fed its colour.
        case footprintMaximum = 1
    }

    /// Pixels per command buffer: about 50 ms of GPU work for a warp.
    static let bandPixels = 4_000_000

    /// Whether `h` is exactly the identity (after dividing by its bottom-right
    /// entry): the one case a warp skips resampling.
    public static func isIdentity(_ h: simd_double3x3) -> Bool {
        let scale = h[2][2]
        guard scale != 0, scale.isFinite else { return false }
        return h * (1 / scale) == matrix_identity_double3x3
    }

    // MARK: - Warping

    /// `source` (rgba16Float camera RGB) moved onto the reference frame's
    /// pixel grid by `movingToReference`, with Catmull-Rom sampling.
    ///
    /// Alpha is coverage: 1 where the output pixel came from inside
    /// `source`, 0 (with black colour) where it would come from outside.
    /// Negative values from the cubic's overshoot are clamped to 0.
    ///
    /// **Identity.** When the homography is exactly the identity and the
    /// output is the source's size, the pixels are not resampled at all:
    /// with no `destination` this returns `source` itself, and with one it
    /// copies the pixels into it unchanged, bit for bit. The source's own
    /// alpha is kept in that case, so set it to 1 if coverage matters.
    ///
    /// - Parameters:
    ///   - destination: an rgba16Float texture to write into (the reference
    ///     frame's size), so a merge can reuse one texture for every frame;
    ///     nil makes a private texture the size of `source`.
    /// - Returns: the warped texture. Waits for the GPU.
    public static func warp(_ source: MTLTexture, movingToReference: simd_double3x3,
                            into destination: MTLTexture? = nil, gpu: GPUContext) throws -> MTLTexture {
        if isIdentity(movingToReference), destination == nil { return source }
        let output = try destination ?? makeTexture(gpu, width: source.width, height: source.height,
                                                    format: .rgba16Float)
        if isIdentity(movingToReference), output.width == source.width, output.height == source.height,
           output.pixelFormat == source.pixelFormat {
            try copy(source, to: output, gpu: gpu)
            return output
        }
        let pso = try gpu.lazyPipeline(.mergeWarpRGBA)
        try runBands(gpu, pso: pso, width: output.width, height: output.height) { encoder, rowOffset in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            try setGeometry(encoder, movingToReference: movingToReference, source: source, output: output,
                            rowOffset: rowOffset)
        }
        return output
    }

    /// A one-channel mask (r8Unorm, r16Float or r32Float) moved the same
    /// way as `warp` moves colours. Outside the source the mask reads
    /// `outside`. The identity copies (or returns) the mask unchanged.
    ///
    /// - Parameters:
    ///   - destination: a one-channel texture of the reference's size;
    ///     nil makes a private one like `source`.
    public static func warpMask(_ source: MTLTexture, movingToReference: simd_double3x3,
                                sampling: MaskSampling, outside: Float = 0,
                                into destination: MTLTexture? = nil, gpu: GPUContext) throws -> MTLTexture {
        if isIdentity(movingToReference), destination == nil { return source }
        let output = try destination ?? makeTexture(gpu, width: source.width, height: source.height,
                                                    format: source.pixelFormat)
        if isIdentity(movingToReference), output.width == source.width, output.height == source.height,
           output.pixelFormat == source.pixelFormat {
            try copy(source, to: output, gpu: gpu)
            return output
        }
        let pso = try gpu.lazyPipeline(.mergeWarpMask)
        try runBands(gpu, pso: pso, width: output.width, height: output.height) { encoder, rowOffset in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            try setGeometry(encoder, movingToReference: movingToReference, source: source, output: output,
                            rowOffset: rowOffset)
            var mode = sampling.rawValue, outsideValue = outside
            encoder.setBytes(&mode, length: 4, index: 3)
            encoder.setBytes(&outsideValue, length: 4, index: 4)
        }
        return output
    }

    /// The GPU memory a warp of a `width x height` rgba16Float frame adds:
    /// its output texture, 8 bytes a pixel. Nothing else is allocated.
    public static func extraBytes(width: Int, height: Int) -> Int {
        width * height * 8
    }

    // MARK: - Reduction for alignment

    /// What `alignmentReduction` hands back: `width x height` pixels, row
    /// by row.
    public struct AlignmentReduction: Sendable {
        public let width: Int
        public let height: Int
        /// Gaussian-weighted mean of (R + 2G + B) / 4.
        public let luminance: [Float]
        /// Gaussian-weighted share of clipped pixels, 0...1.
        public let clippedShare: [Float]
    }

    /// `texture` (rgba16Float or rgba32Float camera RGB) shrunk to
    /// `width x height` for the aligner, with a Gaussian prefilter of half
    /// an output pixel (see `mergeAlignReduce`). Waits for the GPU.
    ///
    /// - Parameters:
    ///   - clipMask: optional one-channel texture of `texture`'s size; any
    ///     value above 0 marks a clipped pixel.
    ///   - channelScale: multiplies each channel first (for example the
    ///     inverse of a white balance still applied to the pixels).
    ///   - channelClip: per channel (after `channelScale`), the value from
    ///     which a pixel counts as clipped.
    public static func alignmentReduction(of texture: MTLTexture, clipMask: MTLTexture? = nil,
                                          channelScale: SIMD3<Float> = SIMD3(repeating: 1),
                                          channelClip: SIMD3<Float>, width: Int, height: Int,
                                          gpu: GPUContext) throws -> AlignmentReduction {
        guard width > 0, height > 0, width <= texture.width, height <= texture.height else {
            throw RenderError.gpuBufferAllocationFailed
        }
        let pso = try gpu.lazyPipeline(.mergeAlignReduce)
        let out = try makeTexture(gpu, width: width, height: height, format: .rg32Float, storage: .shared)
        var factor = SIMD2<Float>(Float(width) / Float(texture.width), Float(height) / Float(texture.height))
        // Half an output pixel, in source pixels; at most 5 so the kernel's
        // window fits its 32 taps (reductions beyond 10x alias a little).
        var sigma = SIMD2<Float>(min(0.5 / factor.x, 5), min(0.5 / factor.y, 5))
        var scale = SIMD4<Float>(channelScale, 1)
        var clip = SIMD4<Float>(channelClip, .greatestFiniteMagnitude)
        var hasMask: UInt32 = clipMask == nil ? 0 : 1
        // The reduction's taps are many more per output pixel than a
        // warp's, so its bands are shorter.
        try runBands(gpu, pso: pso, width: width, height: height, pixelsPerBand: bandPixels / 16) { encoder, rowOffset in
            encoder.setTexture(texture, index: 0)
            // An unused mask slot still needs a texture bound.
            encoder.setTexture(clipMask ?? texture, index: 1)
            encoder.setTexture(out, index: 2)
            encoder.setBytes(&factor, length: 8, index: 0)
            encoder.setBytes(&sigma, length: 8, index: 1)
            encoder.setBytes(&scale, length: 16, index: 2)
            encoder.setBytes(&clip, length: 16, index: 3)
            encoder.setBytes(&hasMask, length: 4, index: 4)
            var offset = rowOffset
            encoder.setBytes(&offset, length: 4, index: 5)
        }
        var pixels = [Float](repeating: 0, count: width * height * 2)
        out.getBytes(&pixels, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var luminance = [Float](repeating: 0, count: width * height)
        var clipped = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            luminance[i] = pixels[2 * i]
            clipped[i] = pixels[2 * i + 1]
        }
        return AlignmentReduction(width: width, height: height, luminance: luminance, clippedShare: clipped)
    }

    // MARK: - Helpers

    /// Binds the homography (as reference -> moving, relative to each
    /// image's centre, in the top-left of a 4 x 4) and the row offset.
    private static func setGeometry(_ encoder: MTLComputeCommandEncoder, movingToReference: simd_double3x3,
                                    source: MTLTexture, output: MTLTexture, rowOffset: UInt32) throws {
        let outputCentre = SIMD2<Double>(Double(output.width), Double(output.height)) / 2
        let sourceCentre = SIMD2<Double>(Double(source.width), Double(source.height)) / 2
        func translation(_ t: SIMD2<Double>) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(1, 0, t.x), SIMD3(0, 1, t.y), SIMD3(0, 0, 1)])
        }
        let determinant = movingToReference.determinant
        guard determinant.isFinite, abs(determinant) > 1e-12 else { throw RenderError.commandBufferFailed }
        // Output pixel (centred) -> reference pixel -> moving pixel -> centred.
        var m = translation(-sourceCentre) * movingToReference.inverse * translation(outputCentre)
        m = m * (1 / m[2][2])
        var matrix = simd_float4x4(SIMD4<Float>(Float(m[0][0]), Float(m[0][1]), Float(m[0][2]), 0),
                                   SIMD4<Float>(Float(m[1][0]), Float(m[1][1]), Float(m[1][2]), 0),
                                   SIMD4<Float>(Float(m[2][0]), Float(m[2][1]), Float(m[2][2]), 0),
                                   SIMD4<Float>(0, 0, 0, 1))
        var centres = SIMD4<Float>(Float(outputCentre.x), Float(outputCentre.y),
                                   Float(sourceCentre.x), Float(sourceCentre.y))
        var offset = rowOffset
        encoder.setBytes(&matrix, length: MemoryLayout<simd_float4x4>.size, index: 0)
        encoder.setBytes(&centres, length: 16, index: 1)
        encoder.setBytes(&offset, length: 4, index: 2)
    }

    /// Runs `pso` over a `width x height` output in bands of rows, one
    /// command buffer each, waiting for each band before encoding the next.
    private static func runBands(_ gpu: GPUContext, pso: MTLComputePipelineState, width: Int, height: Int,
                                 pixelsPerBand: Int = bandPixels,
                                 encode: (MTLComputeCommandEncoder, UInt32) throws -> Void) throws {
        let rows = max(1, pixelsPerBand / max(width, 1))
        var y = 0
        while y < height {
            let bandHeight = min(rows, height - y)
            guard let commands = gpu.commandQueue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            encoder.setComputePipelineState(pso)
            try encode(encoder, UInt32(y))
            HDRMergeKernels.dispatch(encoder, pso: pso, width: width, height: bandHeight)
            encoder.endEncoding()
            try HDRMergeKernels.run(commands)
            y += bandHeight
        }
    }

    /// A bit-exact copy of `source` into `destination` (same size and format).
    private static func copy(_ source: MTLTexture, to destination: MTLTexture, gpu: GPUContext) throws {
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try HDRMergeKernels.run(commands)
    }

    static func makeTexture(_ gpu: GPUContext, width: Int, height: Int, format: MTLPixelFormat,
                            storage: MTLStorageMode = .private) throws -> MTLTexture {
        try HDRMergeKernels.makeTexture(gpu, width: width, height: height, format: format, storage: storage)
    }
}
