import Foundation
import Metal
import MetalPerformanceShaders
import simd
import RawCore

// The GPU half of Photo Merge's deghosting: the kernels in
// Shaders/MergeDeghost.metal, encoded for MergeKit, which decides when to
// deghost and how strongly (MergeKit/Deghost). The kernels' file explains
// the method step by step.

/// How eagerly deghosting calls something movement. `DeghostAmount` in
/// MergeKit turns the dialog's None/Low/Medium/High into one of these.
public struct HDRDeghostSettings: Sendable, Equatable {
    /// A block disagrees with the local reference when their brightness
    /// intervals (noise allowance included) are more than this many stops apart.
    public var gapStops: Float
    /// The patch test's window: (2 x radius + 1)² quarter-size blocks.
    public var patchRadius: Int
    /// How many disagreeing blocks the window needs before its centre counts.
    public var patchCount: Int
    /// How far a found patch is widened, in quarter-size pixels, so the
    /// mask covers a moving object's blurred edges too.
    public var dilateRadius: Int
    /// The mask's feathering, a Gaussian's sigma in quarter-size pixels.
    public var featherSigma: Float

    public init(gapStops: Float, patchRadius: Int, patchCount: Int, dilateRadius: Int, featherSigma: Float) {
        self.gapStops = gapStops
        self.patchRadius = patchRadius
        self.patchCount = patchCount
        self.dilateRadius = dilateRadius
        self.featherSigma = featherSigma
    }
}

/// One frame's deghosting mask at quarter size (`HDRMergeKernels.maskSpan`
/// photosites per pixel): 0 where the frame counts as usual, 255 where it
/// shows something that moved and is left out of the merge.
public struct HDRGhostMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// One byte per pixel, row by row.
    public let weights: [UInt8]

    public init(width: Int, height: Int, weights: [UInt8]) {
        self.width = width
        self.height = height
        self.weights = weights
    }

    /// The share of the frame left out by at least half, 0...1.
    public var maskedFraction: Double {
        guard !weights.isEmpty else { return 0 }
        return Double(weights.lazy.filter { $0 >= 128 }.count) / Double(weights.count)
    }
}

/// One frame as deghosting measured it (`mergeDeghostMeasure`): each
/// quarter-size block's lowest and highest possible log2 brightness, as
/// pairs of half floats, row by row. Kept on the CPU between the
/// measuring pass and the masking pass, so GPU memory doesn't grow with
/// the number of frames: 4 bytes per block, 1.3 MB for a 21 MP frame.
public struct HDRGhostMeasurement: Sendable {
    public let width: Int
    public let height: Int
    let intervals: [Float16]
}

/// Finds each frame's ghosts, in two passes over the bracket at quarter size.
///
/// 1. `measure` every frame, in any order, once each: its brightness
///    intervals, and whether it sees each block better than the frames
///    before it (which builds the map of local references).
/// 2. `finishMeasuring()`, then `findMovement` for every frame but the
///    reference: where it disagrees with the local references, added to one
///    map of movement.
/// 3. `mask` for every frame but the reference: the movement map, except
///    where that frame is itself the local reference.
///
/// GPU memory is a handful of quarter-size textures, whatever the number of
/// frames: under 80 MB for a 21 MP bracket.
///
/// Not Sendable: one merge, used from one task.
public final class HDRGhostDetector {
    public let width: Int
    public let height: Int
    public let mapWidth: Int
    public let mapHeight: Int
    private let gpu: GPUContext
    private let feather: HDRClipFeather
    private let referenceIndex: Int
    private let referenceEV: Double
    /// The local reference per block: interval, priority, frame index.
    private let best: MTLTexture
    private var measuringDone = false
    private var framesCompared = 0
    /// The movement map widened and feathered, made by the first `mask`.
    private var movementFeathered: MTLTexture?
    private var scratch: [String: MTLTexture] = [:]
    private var framesMeasured = 0

    /// Priority the reference frame gets over the others when choosing
    /// local references: it wins wherever it is at least half usable.
    static let referenceBonus: Float = 0.5
    /// Priority a frame loses per stop of exposure from the reference, so
    /// that among equally good frames the nearest to the reference wins.
    static let penaltyPerStop: Float = 0.01
    /// A block below this many counts above black is crushed: read noise
    /// swamps it.
    static let crushedCounts: Float = 24
    /// Read noise assumed for the noise allowance, in counts. Most raws
    /// have 2 to 5 at low ISO; a little too much only widens the allowance.
    static let readNoiseCounts: Float = 4

    /// - Parameters:
    ///   - width, height: the frames' raw size.
    ///   - feather: the merge's clip feathering, applied when judging how
    ///     usable a block is, so a local reference is a frame the merge will
    ///     actually weight there.
    ///   - referenceIndex, referenceEV: the merge's reference frame and its
    ///     stops relative to the brightest.
    public init(gpu: GPUContext, width: Int, height: Int, feather: HDRClipFeather,
                referenceIndex: Int, referenceEV: Double) throws {
        guard width > 0, height > 0 else { throw RenderError.gpuBufferAllocationFailed }
        self.gpu = gpu
        self.width = width
        self.height = height
        (mapWidth, mapHeight) = HDRMergeKernels.maskSize(width: width, height: height)
        self.feather = feather
        self.referenceIndex = referenceIndex
        self.referenceEV = referenceEV
        best = try HDRMergeKernels.makeTexture(gpu, width: mapWidth, height: mapHeight, format: .rgba32Float)
    }

    /// Measures frame `index` of the bracket (brightest first) and adds it
    /// to the choice of local references. Waits for the GPU.
    ///
    /// - Parameter movingToReference: with alignment, where this frame's
    ///   pixels belong on the reference frame (full-resolution pixels, as
    ///   `MergeWarpKernels` takes it); the measurement is moved there before
    ///   anything compares it. Nil or the identity leaves it where it is.
    public func measure(_ file: RawFile, index: Int, levels: HDRFrameLevels,
                        relativeEV: Double, movingToReference: simd_double3x3? = nil) throws -> HDRGhostMeasurement {
        guard !measuringDone else { throw RenderError.commandBufferFailed }
        guard case .bayer(let order) = file.summary.cfaPattern, let plane = file.sensorPlane,
              let buffer = gpu.makeSharedBuffer(wrapping: plane) else { throw HDRMergeKernelError.notABayerFrame }
        guard file.summary.rawWidth == width, file.summary.rawHeight == height else {
            throw HDRMergeKernelError.sizeMismatch(expected: "\(width) x \(height)",
                                                   actual: "\(file.summary.rawWidth) x \(file.summary.rawHeight)")
        }
        let interval = try scratchTexture(.rgba32Float, "interval", storage: .shared)
        let usable = try scratchTexture(.r16Float, "usable")
        let eroded = try scratchTexture(.r16Float, "usableEroded")
        let feathered = try scratchTexture(.r16Float, "usableFeathered")
        guard var commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        // 1. The blocks' brightness intervals and how usable each is.
        let measure = try gpu.lazyPipeline(.mergeDeghostMeasure)
        guard let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(measure)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        var rawWidth = UInt32(width), rawHeight = UInt32(height)
        var black = levels.channelBlack, invRange = levels.scale, clipRaw = levels.clipRaw
        var pattern = order, span = UInt32(HDRMergeKernels.maskSpan)
        var clip = SIMD4<Float>(levels.channelClip, 1)
        var radianceScale = Float(pow(2, -relativeEV))
        var crushed = Self.crushedCounts, readNoise = Self.readNoiseCounts
        encoder.setBytes(&rawWidth, length: 4, index: 1)
        encoder.setBytes(&rawHeight, length: 4, index: 2)
        encoder.setBytes(&black, length: 16, index: 3)
        encoder.setBytes(&invRange, length: 4, index: 4)
        encoder.setBytes(&clipRaw, length: 4, index: 5)
        encoder.setBytes(&pattern, length: 1, index: 6)
        encoder.setBytes(&span, length: 4, index: 7)
        encoder.setBytes(&clip, length: 16, index: 8)
        encoder.setBytes(&radianceScale, length: 4, index: 9)
        encoder.setBytes(&crushed, length: 4, index: 10)
        encoder.setBytes(&readNoise, length: 4, index: 11)
        encoder.setTexture(interval, index: 0)
        encoder.setTexture(usable, index: 1)
        HDRMergeKernels.dispatch(encoder, pso: measure, width: mapWidth, height: mapHeight)
        encoder.endEncoding()

        // With alignment, the measurement moved onto the reference frame
        // (`warpMeasurement`), in its own command buffers.
        var usableHere = usable
        if let movingToReference, !MergeWarpKernels.isIdentity(movingToReference) {
            try HDRMergeKernels.run(commands)
            usableHere = try warpMeasurement(interval: interval, usable: usable, movingToReference: movingToReference)
            guard let next = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
            commands = next
        }

        // 2. Feathered as the merge will feather the frame, then offered as
        // the local reference.
        HDRMergeKernels.encodeFeather(commands, gpu: gpu, feather: feather, source: usableHere, eroded: eroded,
                                      feathered: feathered)
        let choose = try gpu.lazyPipeline(.mergeDeghostChooseReference)
        guard let chooser = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        chooser.setComputePipelineState(choose)
        chooser.setTexture(interval, index: 0)
        chooser.setTexture(feathered, index: 1)
        chooser.setTexture(best, index: 2)
        var frameIndex = Float(index)
        var bonus: Float = index == referenceIndex ? Self.referenceBonus : 0
        var penalty = Self.penaltyPerStop * Float(abs(relativeEV - referenceEV))
        var isFirst = UInt32(framesMeasured == 0 ? 1 : 0)
        chooser.setBytes(&frameIndex, length: 4, index: 0)
        chooser.setBytes(&bonus, length: 4, index: 1)
        chooser.setBytes(&penalty, length: 4, index: 2)
        chooser.setBytes(&isFirst, length: 4, index: 3)
        HDRMergeKernels.dispatch(chooser, pso: choose, width: mapWidth, height: mapHeight)
        chooser.endEncoding()

        try HDRMergeKernels.run(commands)
        framesMeasured += 1

        // Only low and high are kept, as half floats.
        let count = mapWidth * mapHeight
        var full = [Float](repeating: 0, count: count * 4)
        interval.getBytes(&full, bytesPerRow: mapWidth * 16, from: MTLRegionMake2D(0, 0, mapWidth, mapHeight),
                          mipmapLevel: 0)
        var intervals = [Float16](repeating: 0, count: count * 2)
        for i in 0..<count {
            intervals[i * 2] = Float16(full[i * 4])
            intervals[i * 2 + 1] = Float16(full[i * 4 + 1])
        }
        return HDRGhostMeasurement(width: mapWidth, height: mapHeight, intervals: intervals)
    }

    /// Largest log2 brightness a warped interval keeps: far beyond any real
    /// scene (2^64 times the brightest frame's white), close enough to zero
    /// for 32-bit floats to hold to a hundred-thousandth of a stop.
    static let warpLimit: Float = 64

    /// Moves a measured frame onto the reference frame's quarter-size grid:
    /// its `interval` in place, and its `usable` map into a new texture,
    /// which it returns.
    ///
    /// **Blended, like the brightness it describes.** Where a moved block
    /// lands between four blocks, its low and high limits are blends of
    /// theirs (bilinear), as the block's brightness would be. Taking the
    /// widest interval of every block the sample touches instead was tried:
    /// on the Ihrke bracket it found a fortieth of the movement found without
    /// alignment (blending finds about as much), because a sample between
    /// blocks touches four of them each way and the comparison already
    /// allows a block of misalignment on top. Outside the frame
    /// there is nothing to compare: the interval is unbounded both ways,
    /// which never disagrees, and the block isn't usable, so the frame
    /// can't be the local reference there.
    ///
    /// "Unbounded" is 10,000 stops, which a blend would turn into thousands
    /// of stops of nonsense, so the logs are first clamped to plus or minus
    /// `warpLimit`: a blend with an unbounded limit still lands tens of
    /// stops beyond any real brightness, which the comparison treats as
    /// unbounded anyway. Both limits are shifted by `warpLimit` on the way
    /// (0...2 x `warpLimit`), so a mask texture's non-negative range holds them.
    private func warpMeasurement(interval: MTLTexture, usable: MTLTexture,
                                 movingToReference: simd_double3x3) throws -> MTLTexture {
        // The same move in quarter-size pixels: a map pixel's centre is its
        // block's centre, so full-resolution coordinates are just divided.
        let span = Double(HDRMergeKernels.maskSpan)
        let toMap = simd_double3x3(diagonal: SIMD3(1 / span, 1 / span, 1))
        let h = toMap * movingToReference * toMap.inverse

        let count = mapWidth * mapHeight
        // "No limit", as MergeDeghost.metal's `mergeDeghostUnbounded` writes it.
        let limit = Self.warpLimit, unbounded: Float = 10000
        var measured = [Float](repeating: 0, count: count * 4)
        interval.getBytes(&measured, bytesPerRow: mapWidth * 16, from: MTLRegionMake2D(0, 0, mapWidth, mapHeight),
                          mipmapLevel: 0)
        var lows = [Float](repeating: 0, count: count), highs = lows, exposed = lows
        for i in 0..<count {
            lows[i] = min(max(limit + measured[i * 4], 0), 2 * limit)
            highs[i] = min(max(limit + measured[i * 4 + 1], 0), 2 * limit)
            exposed[i] = measured[i * 4 + 2]
        }
        func upload(_ values: [Float], _ purpose: String) throws -> MTLTexture {
            let texture = try scratchTexture(.r32Float, purpose, storage: .shared)
            values.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(region: MTLRegionMake2D(0, 0, mapWidth, mapHeight), mipmapLevel: 0,
                                withBytes: base, bytesPerRow: mapWidth * 4)
            }
            return texture
        }
        func warped(_ source: MTLTexture, _ purpose: String, _ sampling: MergeWarpKernels.MaskSampling,
                    outside: Float) throws -> [Float] {
            let output = try scratchTexture(.r32Float, purpose, storage: .shared)
            _ = try MergeWarpKernels.warpMask(source, movingToReference: h, sampling: sampling, outside: outside,
                                              into: output, gpu: gpu)
            var values = [Float](repeating: 0, count: count)
            output.getBytes(&values, bytesPerRow: mapWidth * 4, from: MTLRegionMake2D(0, 0, mapWidth, mapHeight),
                            mipmapLevel: 0)
            return values
        }
        let movedLows = try warped(try upload(lows, "warpLow"), "warpedLow", .bilinear, outside: 0)
        let movedHighs = try warped(try upload(highs, "warpHigh"), "warpedHigh", .bilinear, outside: 2 * limit)
        let movedExposed = try warped(try upload(exposed, "warpExposed"), "warpedExposed", .bilinear, outside: 0)
        for i in 0..<count {
            let low = movedLows[i] - limit, high = movedHighs[i] - limit
            measured[i * 4] = low <= 0.999 * -limit ? -unbounded : low
            measured[i * 4 + 1] = high >= 0.999 * limit ? unbounded : high
            measured[i * 4 + 2] = movedExposed[i]
        }
        measured.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            interval.replace(region: MTLRegionMake2D(0, 0, mapWidth, mapHeight), mipmapLevel: 0,
                             withBytes: base, bytesPerRow: mapWidth * 16)
        }
        return try MergeWarpKernels.warpMask(usable, movingToReference: h, sampling: .bilinear, outside: 0,
                                             into: try scratchTexture(.r16Float, "usableWarped"), gpu: gpu)
    }

    /// Ends the measuring pass and frees its textures.
    public func finishMeasuring() {
        scratch.removeAll()
        measuringDone = true
    }

    /// Where frame `index` disagrees with the local references, from its
    /// measurement, added to the map of movement. Call `finishMeasuring()`
    /// first, and this for every frame but the reference before any `mask`.
    /// Returns the share of the frame found moving, 0...1. Waits for the GPU.
    public func findMovement(_ measurement: HDRGhostMeasurement, index: Int,
                             settings: HDRDeghostSettings) throws -> Double {
        guard measuringDone, framesMeasured > 0, movementFeathered == nil else {
            throw RenderError.commandBufferFailed
        }
        guard measurement.width == mapWidth, measurement.height == mapHeight else {
            throw HDRMergeKernelError.sizeMismatch(expected: "\(mapWidth) x \(mapHeight) mask",
                                                   actual: "\(measurement.width) x \(measurement.height)")
        }
        let interval = try scratchTexture(.rg16Float, "maskInterval", storage: .shared)
        measurement.intervals.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            interval.replace(region: MTLRegionMake2D(0, 0, mapWidth, mapHeight), mipmapLevel: 0,
                             withBytes: base, bytesPerRow: mapWidth * 4)
        }
        let flags = try scratchTexture(.r16Float, "flags")
        let seeds = try scratchTexture(.r8Unorm, "seeds", storage: .shared)
        let movement = try scratchTexture(.r16Float, "movement")
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        // 1. Blocks that disagree with the local reference.
        let compare = try gpu.lazyPipeline(.mergeDeghostCompare)
        guard let comparer = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        comparer.setComputePipelineState(compare)
        comparer.setTexture(interval, index: 0)
        comparer.setTexture(best, index: 1)
        comparer.setTexture(flags, index: 2)
        var frameIndex = Float(index)
        var gap = settings.gapStops
        comparer.setBytes(&frameIndex, length: 4, index: 0)
        comparer.setBytes(&gap, length: 4, index: 1)
        HDRMergeKernels.dispatch(comparer, pso: compare, width: mapWidth, height: mapHeight)
        comparer.endEncoding()

        // 2. Only whole patches of them, collected into the movement map.
        let patch = try gpu.lazyPipeline(.mergeDeghostPatch)
        guard let patcher = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        patcher.setComputePipelineState(patch)
        patcher.setTexture(flags, index: 0)
        patcher.setTexture(seeds, index: 1)
        patcher.setTexture(movement, index: 2)
        var radius = Int32(settings.patchRadius), minimum = Float(settings.patchCount)
        var isFirst = UInt32(framesCompared == 0 ? 1 : 0)
        patcher.setBytes(&radius, length: 4, index: 0)
        patcher.setBytes(&minimum, length: 4, index: 1)
        patcher.setBytes(&isFirst, length: 4, index: 2)
        HDRMergeKernels.dispatch(patcher, pso: patch, width: mapWidth, height: mapHeight)
        patcher.endEncoding()

        try HDRMergeKernels.run(commands)
        framesCompared += 1
        var found = [UInt8](repeating: 0, count: mapWidth * mapHeight)
        seeds.getBytes(&found, bytesPerRow: mapWidth, from: MTLRegionMake2D(0, 0, mapWidth, mapHeight),
                       mipmapLevel: 0)
        return Double(found.lazy.filter { $0 >= 128 }.count) / Double(max(1, found.count))
    }

    /// Frame `index`'s ghost mask: the movement every frame showed, widened
    /// and feathered, except where this frame is the local reference. Call
    /// after `findMovement` for every frame. Waits for the GPU.
    public func mask(index: Int, settings: HDRDeghostSettings) throws -> HDRGhostMask {
        guard measuringDone else { throw RenderError.commandBufferFailed }
        let owned = try scratchTexture(.r16Float, "owned")
        let ownedFeathered = try scratchTexture(.r16Float, "ownedFeathered")
        let result = try scratchTexture(.r8Unorm, "mask", storage: .shared)
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        // 1. The movement map widened and feathered, once for all frames.
        // No frame found anything (or only the reference was compared): an
        // empty map.
        let movementMap: MTLTexture
        if let existing = movementFeathered {
            movementMap = existing
        } else {
            movementMap = try HDRMergeKernels.makeTexture(gpu, width: mapWidth, height: mapHeight, format: .r16Float)
            let movement = try scratchTexture(.r16Float, "movement")
            if framesCompared == 0 { try clear(movement, commands) }
            let widened = try scratchTexture(.r16Float, "movementWidened")
            let size = 2 * max(0, settings.dilateRadius) + 1
            let dilate = MPSImageAreaMax(device: gpu.device, kernelWidth: size, kernelHeight: size)
            dilate.edgeMode = .clamp
            dilate.encode(commandBuffer: commands, sourceTexture: movement, destinationTexture: widened)
            HDRMergeKernels.encodeBlur(commands, gpu: gpu, sigma: settings.featherSigma, source: widened,
                                       destination: movementMap)
            movementFeathered = movementMap
        }

        // 2. Where this frame is the local reference, feathered alike.
        let ownership = try gpu.lazyPipeline(.mergeDeghostOwnership)
        guard let owner = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        owner.setComputePipelineState(ownership)
        owner.setTexture(best, index: 0)
        owner.setTexture(owned, index: 1)
        var frameIndex = Float(index)
        owner.setBytes(&frameIndex, length: 4, index: 0)
        HDRMergeKernels.dispatch(owner, pso: ownership, width: mapWidth, height: mapHeight)
        owner.endEncoding()
        HDRMergeKernels.encodeBlur(commands, gpu: gpu, sigma: settings.featherSigma, source: owned,
                                   destination: ownedFeathered)

        // 3. The mask: the movement, except where the frame is the local reference.
        let combine = try gpu.lazyPipeline(.mergeDeghostCombine)
        guard let combiner = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        combiner.setComputePipelineState(combine)
        combiner.setTexture(movementMap, index: 0)
        combiner.setTexture(ownedFeathered, index: 1)
        combiner.setTexture(result, index: 2)
        HDRMergeKernels.dispatch(combiner, pso: combine, width: mapWidth, height: mapHeight)
        combiner.endEncoding()

        try HDRMergeKernels.run(commands)
        var weights = [UInt8](repeating: 0, count: mapWidth * mapHeight)
        result.getBytes(&weights, bytesPerRow: mapWidth, from: MTLRegionMake2D(0, 0, mapWidth, mapHeight),
                        mipmapLevel: 0)
        return HDRGhostMask(width: mapWidth, height: mapHeight, weights: weights)
    }

    /// Fills a private one-channel texture with zeros (new textures aren't
    /// promised to start empty): a mask of nothing, from the patch kernel
    /// with nothing disagreeing.
    private func clear(_ texture: MTLTexture, _ commands: MTLCommandBuffer) throws {
        let empty = try scratchTexture(.r16Float, "emptyFlags", storage: .shared)
        let zeros = [Float16](repeating: 0, count: mapWidth * mapHeight)
        zeros.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            empty.replace(region: MTLRegionMake2D(0, 0, mapWidth, mapHeight), mipmapLevel: 0,
                          withBytes: base, bytesPerRow: mapWidth * 2)
        }
        guard let blit = commands.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.copy(from: empty, to: texture)
        blit.endEncoding()
    }

    private func scratchTexture(_ format: MTLPixelFormat, _ purpose: String,
                                storage: MTLStorageMode = .private) throws -> MTLTexture {
        let key = "\(purpose)-\(format.rawValue)"
        if let texture = scratch[key] { return texture }
        let texture = try HDRMergeKernels.makeTexture(gpu, width: mapWidth, height: mapHeight, format: format,
                                                      storage: storage)
        scratch[key] = texture
        return texture
    }
}
