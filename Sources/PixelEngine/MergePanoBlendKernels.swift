import Foundation
import Metal
import simd

// The GPU half of Photo Merge's panorama stitcher: the kernels in
// Shaders/MergePanoBlend.metal, encoded for MergeKit/Pano/Blend, which
// plans the stitch (which frames, which tiles, how many bands) and owns
// the projection maths these kernels are fed. The kernels' file explains
// each step.

/// Encodes the panorama stitcher's kernels.
///
/// One instance serves one stitch, on one thread: it builds each kernel's
/// pipeline the first time it is used (most apps never stitch a panorama,
/// so none of this is built at launch) and counts the textures it makes,
/// so the stitcher can report what it holds.
///
/// **Places.** Most kernels work on patches of one pyramid level of the
/// panorama. A `Place` says where a texture's pixel (0, 0) sits in that
/// level's global pixel grid and how much of the texture is in use, so
/// one texture can be reused for patches of different sizes and the
/// kernels can line tiles up with each other and with whole-panorama
/// textures. Level k's pixel j covers level-0 output pixels
/// j * 2^k ..< (j + 1) * 2^k.
public final class MergePanoBlendKernels {
    public let gpu: GPUContext
    private var pipelines: [String: MTLComputePipelineState] = [:]

    /// Bytes of the textures this instance made that are still alive and
    /// still hold their memory.
    ///
    /// Textures marked empty (how the stitcher gives a frame's memory back;
    /// Metal keeps the objects alive for a while after their last command
    /// buffer) don't count: their memory is gone.
    public var liveTextureBytes: Int {
        // The table's list of objects is autoreleased and holds each texture:
        // without a pool of its own, asking would keep them all alive.
        autoreleasepool {
            liveTextures.allObjects.reduce(0) { total, object in
                let texture = object as! MTLTexture
                // .keepCurrent asks without changing anything.
                return texture.setPurgeableState(.keepCurrent) == .empty ? total : total + texture.allocatedSize
            }
        }
    }
    private let liveTextures = NSHashTable<AnyObject>.weakObjects()

    public init(gpu: GPUContext) {
        self.gpu = gpu
    }

    // MARK: - Types

    /// How a panorama is flattened; the values the kernels switch on.
    public enum Projection: Int32, Sendable {
        case perspective = 0
        case cylindrical = 1
        case spherical = 2
    }

    /// One frame's placement on the panorama, in the form the kernels use.
    /// MergeKit builds it from a `PanoramaCamera` in double precision;
    /// `mergePanoBlendMap` in the kernels' file explains the fields.
    public struct FrameMapping: Sendable, Equatable {
        /// The mapping near one block of output pixels.
        public struct Block: Sendable, Equatable {
            /// Turns a pixel's local direction into its ray in camera axes,
            /// scaled like `anchorRay`.
            public var matrix: simd_double3x3
            /// The anchor's ray in camera axes, scaled so its z is 1.
            public var anchorRay: SIMD3<Double>
            /// The cosine and sine of the anchor's tilt ((1, 0) for Perspective).
            public var tilt: SIMD2<Double>
            /// The block's centre pixel, level-0 output pixels.
            public var anchor: SIMD2<Int>
            /// False when the anchor is behind the camera: the block maps nowhere.
            public var isValid: Bool

            public init(matrix: simd_double3x3, anchorRay: SIMD3<Double>, tilt: SIMD2<Double>, anchor: SIMD2<Int>,
                        isValid: Bool) {
                self.matrix = matrix; self.anchorRay = anchorRay; self.tilt = tilt; self.anchor = anchor
                self.isValid = isValid
            }
        }

        /// Blocks are 2^blockShift output pixels square.
        public static let blockShift = 9

        /// The first block, in blocks (level-0 output pixel >> blockShift).
        public var firstBlock: SIMD2<Int>
        public var blocksAcross: Int
        public var blocksDown: Int
        /// Row by row.
        public var blocks: [Block]
        /// Local coordinate change per level-0 output pixel.
        public var unitsPerPixel: SIMD2<Double>
        /// Focal length and principal point, full-resolution pixels.
        public var focalLength: Double
        public var principalPoint: SIMD2<Double>
        /// Prepared frame pixels per full-resolution pixel (1 / decode span).
        public var sampleScale: Double
        public var gain: Double
        public var projection: Projection
        /// The frame's position in the layout: its label in the seam map.
        public var position: Int

        public init(firstBlock: SIMD2<Int>, blocksAcross: Int, blocksDown: Int, blocks: [Block],
                    unitsPerPixel: SIMD2<Double>, focalLength: Double, principalPoint: SIMD2<Double>,
                    sampleScale: Double, gain: Double, projection: Projection, position: Int) {
            precondition(blocks.count == blocksAcross * blocksDown, "one block per place")
            self.firstBlock = firstBlock; self.blocksAcross = blocksAcross; self.blocksDown = blocksDown
            self.blocks = blocks; self.unitsPerPixel = unitsPerPixel; self.focalLength = focalLength
            self.principalPoint = principalPoint; self.sampleScale = sampleScale; self.gain = gain
            self.projection = projection; self.position = position
        }
    }

    /// A rectangle in the global pixel grid of one pyramid level.
    public struct Place: Sendable, Equatable, CustomStringConvertible {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public var maxX: Int { x + width }
        public var maxY: Int { y + height }
        public var isEmpty: Bool { width <= 0 || height <= 0 }
        public var description: String { "\(width)x\(height) at (\(x), \(y))" }

        var uniform: SIMD4<Int32> { SIMD4(Int32(x), Int32(y), Int32(width), Int32(height)) }
    }

    /// A patch of one level's grid: where it is, and the panorama's size
    /// and step at that level.
    public struct Grid: Sendable, Equatable {
        public var place: Place
        /// The panorama's size in this level's pixels.
        public var canvasWidth: Int
        public var canvasHeight: Int
        /// Level-0 output pixels per pixel of this level (2^level).
        public var step: Int

        public init(place: Place, canvasWidth: Int, canvasHeight: Int, step: Int) {
            self.place = place; self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight; self.step = step
        }
    }

    // The kernels' uniform layouts. Only 4-component vectors and a 4 x 4
    // matrix, whose size and alignment Swift and Metal agree on (16 and 64
    // bytes, aligned to 4), so the structs match field for field.
    struct FrameUniforms {
        var unitsPerPixel: SIMD4<Float>
        var camera: SIMD4<Float>
        var frame: SIMD4<Float>
        var blocks: SIMD4<Int32>
        var info: SIMD4<Int32>
    }

    struct BlockUniforms {
        var matrix: simd_float4x4
        var tilt: SIMD4<Float>
        var anchor: SIMD4<Int32>
    }

    struct GridUniforms {
        var origin: SIMD4<Int32>
        var canvas: SIMD4<Int32>
    }

    struct LevelUniforms {
        var fine: SIMD4<Int32>
        var coarse: SIMD4<Int32>
        var accumulator: SIMD4<Int32>
    }

    // MARK: - Textures

    /// A texture for the stitch, refusing any side beyond the GPU's limit
    /// (the stitcher's plan never asks for one; this makes a mistake an
    /// error rather than a Metal crash).
    public func makeTexture(width: Int, height: Int, format: MTLPixelFormat, shared: Bool = false,
                            mipmapped: Bool = false, arrayLength: Int = 1) throws -> MTLTexture {
        let limit = Self.maximumTextureSide(gpu.device)
        guard width > 0, height > 0, width <= limit, height <= limit, arrayLength >= 1 else {
            throw RenderError.gpuBufferAllocationFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: mipmapped)
        if arrayLength > 1 {
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = arrayLength
        }
        descriptor.storageMode = shared ? .shared : .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        liveTextures.add(texture)
        return texture
    }

    /// The largest texture side the device supports: 16,384 px on Apple
    /// silicon (Metal's feature tables), 8,192 on older GPUs.
    public static func maximumTextureSide(_ device: MTLDevice) -> Int {
        device.supportsFamily(.apple3) || device.supportsFamily(.mac2) ? 16_384 : 8_192
    }

    /// One slice of a texture array, or one mip level, as a plain 2D texture.
    public func view(_ texture: MTLTexture, slice: Int = 0, level: Int = 0) throws -> MTLTexture {
        guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                                                 levels: level..<(level + 1), slices: slice..<(slice + 1)) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        return view
    }

    /// A texture for a prepared frame: shared, mipmapped, rgba16Float.
    public func makeFrameTexture(width: Int, height: Int) throws -> MTLTexture {
        try makeTexture(width: width, height: height, format: .rgba16Float, shared: true, mipmapped: true)
    }

    /// A prepared frame on the GPU: `pixels` (rgba16Float, straight colour,
    /// alpha 0 outside the image, `width x height` pixels row by row)
    /// copied into a shared mipmapped texture, premultiplied, with every
    /// mip level filled. Waits for the GPU.
    ///
    /// - Parameter reusing: a texture of the same size from an earlier
    ///   frame, refilled instead of a new one being made, so a stitch's
    ///   frame memory doesn't churn.
    public func uploadFrame(_ pixels: UnsafeRawPointer, width: Int, height: Int,
                            reusing: MTLTexture? = nil) throws -> MTLTexture {
        let texture: MTLTexture
        if let reusing, reusing.width == width, reusing.height == height, reusing.pixelFormat == .rgba16Float {
            texture = reusing
            // Undoes an eviction's `setPurgeableState(.empty)`; the contents
            // are about to be overwritten anyway.
            texture.setPurgeableState(.nonVolatile)
        } else {
            texture = try makeFrameTexture(width: width, height: height)
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                        bytesPerRow: width * 8)
        // A pool, so the (autoreleased) command buffer lets go of its views now.
        try autoreleasepool { try fillMips(texture) }
        return texture
    }

    private func fillMips(_ texture: MTLTexture) throws {
        let width = texture.width, height = texture.height
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        let premultiply = try pipeline("mergePanoBlendPremultiply")
        try encode(commands, premultiply, width: width, height: height) { encoder in
            encoder.setTexture(try view(texture), index: 0)
        }
        let down = try pipeline("mergePanoBlendMipDown")
        for level in 1..<max(texture.mipmapLevelCount, 1) {
            let larger = try view(texture, level: level - 1), smaller = try view(texture, level: level)
            try encode(commands, down, width: smaller.width, height: smaller.height) { encoder in
                encoder.setTexture(larger, index: 0)
                encoder.setTexture(smaller, index: 1)
            }
        }
        try Self.run(commands)
    }

    // MARK: - Encoding

    /// Warps `frame` (from `uploadFrame`) onto `grid`, writing straight
    /// colour times the gain and coverage into `destination` (rgba16Float,
    /// at least the grid's size).
    public func encodeWarp(_ commands: MTLCommandBuffer, frame: MTLTexture, mapping: FrameMapping, grid: Grid,
                           into destination: MTLTexture) throws {
        var frameUniforms = Self.uniforms(mapping, frame: frame)
        var gridUniforms = Self.uniforms(grid)
        let blocks = try blockBuffer(mapping)
        try encode(commands, try pipeline("mergePanoBlendWarp"), width: grid.place.width, height: grid.place.height) { e in
            e.setTexture(frame, index: 0)
            e.setTexture(destination, index: 1)
            e.setBytes(&frameUniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            e.setBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
            e.setBuffer(blocks, offset: 0, index: 3)
        }
    }

    /// Offers a warped patch (at `grid`) to the seam labels in `best`
    /// (rgba32Float at `bestPlace`); see `mergePanoBlendLabel`.
    public func encodeLabel(_ commands: MTLCommandBuffer, warped: MTLTexture, mapping: FrameMapping, grid: Grid,
                            best: MTLTexture, bestPlace: Place) throws {
        var frameUniforms = Self.uniforms(mapping, frame: nil)
        var gridUniforms = Self.uniforms(grid)
        var place = bestPlace.uniform
        let blocks = try blockBuffer(mapping)
        try encode(commands, try pipeline("mergePanoBlendLabel"), width: grid.place.width, height: grid.place.height) { e in
            e.setTexture(warped, index: 0)
            e.setTexture(best, index: 1)
            e.setBytes(&frameUniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            e.setBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
            e.setBytes(&place, length: 16, index: 2)
            e.setBuffer(blocks, offset: 0, index: 3)
        }
    }

    /// Sets the first `width x height` pixels of `texture` to `value`.
    public func encodeClear(_ commands: MTLCommandBuffer, _ texture: MTLTexture, width: Int, height: Int,
                            value: SIMD4<Float>) throws {
        var value = value
        var size = SIMD4<Int32>(Int32(width), Int32(height), 0, 0)
        try encode(commands, try pipeline("mergePanoBlendClear"), width: width, height: height) { e in
            e.setTexture(texture, index: 0)
            e.setBytes(&value, length: 16, index: 0)
            e.setBytes(&size, length: 16, index: 1)
        }
    }

    /// A warped patch (at `grid`) into log colour and coverage (`pyramid`,
    /// rgba32Float) and the frame's seam mask (`weight`, r32Float).
    public func encodeLog(_ commands: MTLCommandBuffer, warped: MTLTexture, grid: Grid, best: MTLTexture,
                          bestPlace: Place, pyramid: MTLTexture, weight: MTLTexture, eps: Float,
                          position: Int) throws {
        var gridUniforms = Self.uniforms(grid)
        var place = bestPlace.uniform
        var params = SIMD4<Float>(eps, Float(position), 0, 0)
        try encode(commands, try pipeline("mergePanoBlendLog"), width: grid.place.width, height: grid.place.height) { e in
            e.setTexture(warped, index: 0)
            e.setTexture(best, index: 1)
            e.setTexture(pyramid, index: 2)
            e.setTexture(weight, index: 3)
            e.setBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.stride, index: 0)
            e.setBytes(&place, length: 16, index: 1)
            e.setBytes(&params, length: 16, index: 2)
        }
    }

    /// One reduce step, `source` (at `sourcePlace`) into `destination` (at
    /// `destinationPlace`, one level coarser) through `scratch` (at least
    /// the destination's width by the source's height, same format).
    /// `colour`: normalised convolution of (log colour, coverage);
    /// otherwise a plain reduce (seam weights).
    public func encodeReduce(_ commands: MTLCommandBuffer, source: MTLTexture, sourcePlace: Place,
                             destination: MTLTexture, destinationPlace: Place, scratch: MTLTexture,
                             colour: Bool) throws {
        let middle = Place(x: destinationPlace.x, y: sourcePlace.y, width: destinationPlace.width,
                           height: sourcePlace.height)
        var mode: UInt32 = colour ? 0 : 1
        var from = sourcePlace.uniform, to = middle.uniform
        try encode(commands, try pipeline("mergePanoBlendReduceH"), width: middle.width, height: middle.height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(scratch, index: 1)
            e.setBytes(&from, length: 16, index: 0)
            e.setBytes(&to, length: 16, index: 1)
            e.setBytes(&mode, length: 4, index: 2)
        }
        var from2 = middle.uniform, to2 = destinationPlace.uniform
        try encode(commands, try pipeline("mergePanoBlendReduceV"), width: destinationPlace.width,
                   height: destinationPlace.height) { e in
            e.setTexture(scratch, index: 0)
            e.setTexture(destination, index: 1)
            e.setBytes(&from2, length: 16, index: 0)
            e.setBytes(&to2, length: 16, index: 1)
            e.setBytes(&mode, length: 4, index: 2)
        }
    }

    /// One pyramid level of one frame, filled and added into the blend
    /// (`mergePanoBlendExpandFill`). `coarse` nil means the coarsest level,
    /// filled towards `mean`.
    public func encodeExpandFill(_ commands: MTLCommandBuffer, pyramid: MTLTexture, weight: MTLTexture, place: Place,
                                 coarse: MTLTexture?, coarsePlace: Place, accumulator: MTLTexture,
                                 accumulatorPlace: Place, mean: SIMD3<Float> = .zero) throws {
        var level = LevelUniforms(fine: place.uniform, coarse: coarsePlace.uniform,
                                  accumulator: accumulatorPlace.uniform)
        var params = SIMD4<Float>(mean, 0)
        var mode: UInt32 = coarse == nil ? 1 : 0
        try encode(commands, try pipeline("mergePanoBlendExpandFill"), width: place.width, height: place.height) { e in
            e.setTexture(pyramid, index: 0)
            e.setTexture(weight, index: 1)
            // An unused slot still needs a texture of the right kind bound.
            e.setTexture(coarse ?? weight, index: 2)
            e.setTexture(accumulator, index: 3)
            e.setBytes(&level, length: MemoryLayout<LevelUniforms>.stride, index: 0)
            e.setBytes(&params, length: 16, index: 1)
            e.setBytes(&mode, length: 4, index: 2)
        }
    }

    /// Collapses one level of the blend in place (`mergePanoBlendCollapse`).
    /// `coarse` nil means the coarsest level, where uncovered pixels get `fill`.
    public func encodeCollapse(_ commands: MTLCommandBuffer, accumulator: MTLTexture, place: Place,
                               coarse: MTLTexture?, coarsePlace: Place, fill: SIMD3<Float> = .zero) throws {
        var level = LevelUniforms(fine: place.uniform, coarse: coarsePlace.uniform, accumulator: place.uniform)
        var fillValue = SIMD4<Float>(fill, 0)
        var mode: UInt32 = coarse == nil ? 1 : 0
        // A texture bound read-write can't also be bound for reading, so the
        // coarsest level (which reads nothing coarser) binds a 1-pixel stand-in.
        let coarser = try coarse ?? placeholder()
        try encode(commands, try pipeline("mergePanoBlendCollapse"), width: place.width, height: place.height) { e in
            e.setTexture(accumulator, index: 0)
            e.setTexture(coarser, index: 1)
            e.setBytes(&level, length: MemoryLayout<LevelUniforms>.stride, index: 0)
            e.setBytes(&fillValue, length: 16, index: 1)
            e.setBytes(&mode, length: 4, index: 2)
        }
    }

    /// The collapsed blend back to linear light (`mergePanoBlendFinish`):
    /// the `width x height` pixels at `offset` of `collapsed` and `best`
    /// into the top-left of `output` (rgba16Float).
    public func encodeFinish(_ commands: MTLCommandBuffer, collapsed: MTLTexture, best: MTLTexture,
                             offset: SIMD2<Int>, width: Int, height: Int, output: MTLTexture, eps: Float) throws {
        var region = SIMD4<Int32>(Int32(offset.x), Int32(offset.y), Int32(width), Int32(height))
        var params = SIMD4<Float>(eps, 0, 0, 0)
        try encode(commands, try pipeline("mergePanoBlendFinish"), width: width, height: height) { e in
            e.setTexture(collapsed, index: 0)
            e.setTexture(best, index: 1)
            e.setTexture(output, index: 2)
            e.setBytes(&region, length: 16, index: 0)
            e.setBytes(&params, length: 16, index: 1)
        }
    }

    /// For tests: where each pixel of `grid` lands in the frame, as
    /// (x, y from the principal point in full-resolution pixels, in front of
    /// the camera 1 or 0, footprint in prepared pixels), row by row. Waits
    /// for the GPU.
    public func mapPixels(mapping: FrameMapping, grid: Grid) throws -> [SIMD4<Float>] {
        let width = grid.place.width, height = grid.place.height
        let out = try makeTexture(width: width, height: height, format: .rgba32Float, shared: true)
        var frameUniforms = Self.uniforms(mapping, frame: nil)
        var gridUniforms = Self.uniforms(grid)
        let blocks = try blockBuffer(mapping)
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        try encode(commands, try pipeline("mergePanoBlendMapDebug"), width: width, height: height) { e in
            e.setTexture(out, index: 0)
            e.setBytes(&frameUniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            e.setBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.stride, index: 1)
            e.setBuffer(blocks, offset: 0, index: 3)
        }
        try Self.run(commands)
        var values = [SIMD4<Float>](repeating: .zero, count: width * height)
        values.withUnsafeMutableBytes { bytes in
            out.getBytes(bytes.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        }
        return values
    }

    /// Commits `commands` and waits; throws if the GPU reported an error.
    public static func run(_ commands: MTLCommandBuffer) throws {
        try HDRMergeKernels.run(commands)
    }

    // MARK: - Helpers

    private var placeholderTexture: MTLTexture?
    private var blockBuffers: [Int: (mapping: FrameMapping, buffer: MTLBuffer)] = [:]

    private func placeholder() throws -> MTLTexture {
        if let placeholderTexture { return placeholderTexture }
        let made = try makeTexture(width: 1, height: 1, format: .rgba32Float)
        placeholderTexture = made
        return made
    }

    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        if let built = pipelines[name] { return built }
        guard let function = gpu.library.makeFunction(name: name) else {
            throw GPUContextError.missingShaderFunction(name)
        }
        let built = try gpu.device.makeComputePipelineState(function: function)
        pipelines[name] = built
        return built
    }

    private func encode(_ commands: MTLCommandBuffer, _ pso: MTLComputePipelineState, width: Int, height: Int,
                        _ bind: (MTLComputeCommandEncoder) throws -> Void) throws {
        guard width > 0, height > 0 else { return }
        guard let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        do {
            try bind(encoder)
        } catch {
            encoder.endEncoding()
            throw error
        }
        HDRMergeKernels.dispatch(encoder, pso: pso, width: width, height: height)
        encoder.endEncoding()
    }

    static func uniforms(_ mapping: FrameMapping, frame: MTLTexture?) -> FrameUniforms {
        FrameUniforms(
            unitsPerPixel: SIMD4(Float(mapping.unitsPerPixel.x), Float(mapping.unitsPerPixel.y), 0, 0),
            camera: SIMD4(Float(mapping.focalLength), Float(mapping.principalPoint.x), Float(mapping.principalPoint.y),
                          Float(mapping.sampleScale)),
            frame: SIMD4(Float(frame?.width ?? 0), Float(frame?.height ?? 0), Float(mapping.gain),
                         Float(frame?.mipmapLevelCount ?? 1)),
            blocks: SIMD4(Int32(clamping: mapping.firstBlock.x), Int32(clamping: mapping.firstBlock.y),
                          Int32(clamping: mapping.blocksAcross), Int32(clamping: mapping.blocksDown)),
            info: SIMD4(mapping.projection.rawValue, Int32(clamping: mapping.position),
                        Int32(FrameMapping.blockShift), 0))
    }

    /// The mapping's blocks as a GPU buffer, kept for the mapping's frame so
    /// each tile reuses it.
    private func blockBuffer(_ mapping: FrameMapping) throws -> MTLBuffer {
        if let cached = blockBuffers[mapping.position], cached.mapping == mapping { return cached.buffer }
        func column(_ c: SIMD3<Double>, _ w: Float = 0) -> SIMD4<Float> { SIMD4(Float(c.x), Float(c.y), Float(c.z), w) }
        var uniforms = mapping.blocks.map { block in
            BlockUniforms(matrix: simd_float4x4(column(block.matrix.columns.0), column(block.matrix.columns.1),
                                                column(block.matrix.columns.2),
                                                column(block.anchorRay, block.isValid ? 1 : 0)),
                          tilt: SIMD4(Float(block.tilt.x), Float(block.tilt.y),
                                      Float(mapping.focalLength * block.anchorRay.x),
                                      Float(mapping.focalLength * block.anchorRay.y)),
                          anchor: SIMD4(Int32(clamping: block.anchor.x), Int32(clamping: block.anchor.y), 0, 0))
        }
        // Metal can't bind an empty buffer; a frame without blocks gets one
        // invalid block, which its own block count never reaches.
        if uniforms.isEmpty {
            uniforms = [BlockUniforms(matrix: simd_float4x4(), tilt: .zero, anchor: .zero)]
        }
        guard let buffer = uniforms.withUnsafeBytes({ bytes in
            gpu.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw RenderError.gpuBufferAllocationFailed }
        blockBuffers[mapping.position] = (mapping, buffer)
        return buffer
    }

    static func uniforms(_ grid: Grid) -> GridUniforms {
        GridUniforms(origin: grid.place.uniform,
                     canvas: SIMD4(Int32(grid.canvasWidth), Int32(grid.canvasHeight), Int32(grid.step), 0))
    }
}
