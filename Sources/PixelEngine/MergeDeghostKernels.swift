import Foundation
import Metal
import MetalPerformanceShaders
import simd
import RawCore

// The GPU half of Photo Merge's deghosting: the kernels in
// Shaders/MergeDeghost.metal, encoded for MergeKit, which decides when to
// deghost and how strongly (MergeKit/Deghost), and the CPU step between
// them that turns movement into moving areas. The kernels' file explains
// the method step by step.

/// How eagerly deghosting calls something movement. `DeghostAmount` in
/// MergeKit turns the dialog's None/Low/Medium/High into one of these.
///
/// The radii and the feather are in quarter-size pixels of a frame whose
/// quarter-size long edge is `HDRGhostDetector.scaleLongEdge` (a 16 MP
/// frame); larger frames scale them up in proportion, because the same
/// walking person covers more pixels in them.
public struct HDRDeghostSettings: Sendable, Equatable {
    /// A block disagrees with the local reference when their brightness
    /// intervals (noise allowance included) are more than this many stops apart.
    public var gapStops: Float
    /// The patch test's window: (2 x radius + 1)² quarter-size blocks.
    public var patchRadius: Int
    /// How many disagreeing blocks the window needs before its centre counts.
    public var patchCount: Int
    /// How far the moving areas are widened, so they cover a moving
    /// object's blurred edges and the parts of it that matched the
    /// background too.
    public var dilateRadius: Int
    /// The mask's feathering, a Gaussian's sigma.
    public var featherSigma: Float
    /// A block also disagrees when either of its colour ratios (red or blue
    /// over green, exposure divided out) is more than this many stops from
    /// the local reference's, beyond their noise.
    public var colourStops: Float
    /// Gaps in the movement up to about twice this wide are filled before
    /// the moving areas are found (a morphological closing), so a person
    /// whose shirt matched the wall behind them in places is still one area.
    public var closeRadius: Int

    public init(gapStops: Float, patchRadius: Int, patchCount: Int, dilateRadius: Int, featherSigma: Float,
                colourStops: Float = 0.35, closeRadius: Int = 0) {
        self.gapStops = gapStops
        self.patchRadius = patchRadius
        self.patchCount = patchCount
        self.dilateRadius = dilateRadius
        self.featherSigma = featherSigma
        self.colourStops = colourStops
        self.closeRadius = closeRadius
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

/// One frame as deghosting measured it (`mergeDeghostMeasure`), kept on the
/// CPU between the measuring pass and the masking pass, so GPU memory
/// doesn't grow with the number of frames: 9 bytes per block, 12 MB for a
/// 21 MP frame.
public struct HDRGhostMeasurement: Sendable {
    public let width: Int
    public let height: Int
    /// Each block's lowest and highest possible log2 brightness, as pairs
    /// of half floats, row by row.
    let intervals: [Float16]
    /// Each block's colour ratios, log2(red / green) and log2(blue / green),
    /// as pairs of half floats.
    let colours: [Float16]
    /// Each block's colour allowance in 32nds of a stop; 255 where its
    /// colour can't be trusted.
    let allowances: [UInt8]
}

/// Finds each frame's ghosts, in three passes over the bracket at quarter size.
///
/// 1. `measure` every frame, in any order, once each: its brightness and
///    colour, and whether it sees each block better than the frames before
///    it (which builds the map of local references).
/// 2. `finishMeasuring()`, then `findMovement` for every frame, the
///    reference included: where it disagrees with the local references,
///    added to one map of movement. No frame is compared with itself: a
///    block whose local reference is the frame itself is skipped.
/// 3. `mask` for every frame, the reference included: every moving area,
///    except those (or the parts of them) the frame is the source of. The
///    first call finds the areas and their sources (`findAreas`).
///
/// GPU memory is a handful of quarter-size textures, whatever the number of
/// frames: about 100 MB for a 21 MP bracket. On the CPU each frame also
/// leaves 2 bytes per block (how usable and how well exposed it is) until
/// the areas are found.
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
    /// The local reference's colour per block, as `mergeDeghostMeasure` wrote it.
    private let bestColour: MTLTexture
    private var measuringDone = false
    private var framesCompared = 0
    /// Per measured frame, by index: how usable each block is (0...255, as
    /// the merge will weight it), how well exposed, and its exposure.
    private var usableMaps: [Int: [UInt8]] = [:]
    private var exposedMaps: [Int: [UInt8]] = [:]
    private var relativeEVs: [Int: Double] = [:]
    /// The feathered moving areas and each block's source frame (negative
    /// outside the areas), made by the first `mask`.
    private var areas: (feathered: MTLTexture, source: MTLTexture, sigma: Float)?
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
    /// How usable the darkest frame counts as, at least, when choosing
    /// sources. The merge never fades the darkest frame out near clipping
    /// and keeps a weight floor for it, so where every frame is clipped it
    /// is what the merge shows anyway, and choosing a clipped brighter frame
    /// instead would leave the block to that floor all the same.
    static let darkestUsableFloor: Float = 0.25
    /// The quarter-size long edge the settings' radii are given for.
    public static let scaleLongEdge = 1000
    /// A moving area needs at least this many blocks of movement (before
    /// closing and widening), or it's taken for noise and dropped.
    static let minimumMovingBlocks = 4
    /// The mean usability (usable x exposed, over the area) the reference
    /// frame is given extra when choosing an area's source.
    static let areaReferenceBonus: Double = 0.25
    /// What each clipped block (`sourceUsableMinimum`) of an area costs a
    /// frame when choosing the area's source, on top of the usability it
    /// lacks. A clipped block has to come from another frame, shot at
    /// another moment, which is what showed as a translucent patch on the
    /// Market Mires vendor's chin; a dark block only brings noise.
    static let clippedAreaCost: Double = 1
    /// An area covering more than this share of the frame (or of a 16 MP
    /// frame, for smaller ones) is no single
    /// moving thing but moving texture (a sea of waves, a tree in wind): its
    /// blocks choose their source by the same rule, each over the square
    /// window around it `largeAreaWindow` of the long edge wide, rather than
    /// all together. One source for the whole of Crete's sea was its darkest
    /// frame (the only one whose glitter wasn't clipped), which left the
    /// water in the shade noisy and blue; judged window by window, the shade
    /// takes a brighter frame and the glitter the darkest, handing over
    /// where the water changes rather than along a grid.
    static let largeAreaShare = 0.05
    static let largeAreaWindow = 1.0 / 16
    /// A block of an area whose source frame is less usable than this there
    /// (clipped, as the merge weights it) is taken from another frame.
    static let sourceUsableMinimum: UInt8 = 128

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
        bestColour = try HDRMergeKernels.makeTexture(gpu, width: mapWidth, height: mapHeight, format: .rgba32Float)
    }

    /// How much the settings' radii and feather are scaled for this frame size.
    var radiusScale: Float {
        max(1, Float(max(mapWidth, mapHeight)) / Float(Self.scaleLongEdge))
    }

    /// Measures frame `index` of the bracket (brightest first) and adds it
    /// to the choice of local references. Waits for the GPU.
    ///
    /// - Parameters:
    ///   - movingToReference: with alignment, where this frame's pixels
    ///     belong on the reference frame (full-resolution pixels, as
    ///     `MergeWarpKernels` takes it); the measurement is moved there before
    ///     anything compares it. Nil or the identity leaves it where it is.
    ///   - isDarkest: whether this is the darkest frame of the merge, which
    ///     the merge doesn't fade out near clipping (`darkestUsableFloor`).
    public func measure(_ file: RawFile, index: Int, levels: HDRFrameLevels,
                        relativeEV: Double, movingToReference: simd_double3x3? = nil,
                        isDarkest: Bool = false) throws -> HDRGhostMeasurement {
        guard !measuringDone else { throw RenderError.commandBufferFailed }
        guard case .bayer(let order) = file.summary.cfaPattern, let plane = file.sensorPlane,
              let buffer = gpu.makeSharedBuffer(wrapping: plane) else { throw HDRMergeKernelError.notABayerFrame }
        guard file.summary.rawWidth == width, file.summary.rawHeight == height else {
            throw HDRMergeKernelError.sizeMismatch(expected: "\(width) x \(height)",
                                                   actual: "\(file.summary.rawWidth) x \(file.summary.rawHeight)")
        }
        let interval = try scratchTexture(.rgba32Float, "interval", storage: .shared)
        let colour = try scratchTexture(.rgba32Float, "colour", storage: .shared)
        let usable = try scratchTexture(.r16Float, "usable", storage: .shared)
        let eroded = try scratchTexture(.r16Float, "usableEroded")
        let feathered = try scratchTexture(.r16Float, "usableFeathered", storage: .shared)
        guard var commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        // 1. The blocks' brightness intervals, colours and how usable each is.
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
        encoder.setTexture(colour, index: 2)
        HDRMergeKernels.dispatch(encoder, pso: measure, width: mapWidth, height: mapHeight)
        encoder.endEncoding()

        // With alignment, the measurement moved onto the reference frame
        // (`warpMeasurement`), in its own command buffers.
        var usableHere = usable
        if let movingToReference, !MergeWarpKernels.isIdentity(movingToReference) {
            try HDRMergeKernels.run(commands)
            usableHere = try warpMeasurement(interval: interval, colour: colour, usable: usable,
                                             movingToReference: movingToReference)
            guard let next = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
            commands = next
        }

        // 2. Feathered as the merge will feather the frame (not at all for
        // the darkest), then offered as the local reference.
        let judged: MTLTexture
        if isDarkest {
            try HDRMergeKernels.run(commands)
            judged = try flooredUsable(usableHere, into: feathered)
            guard let next = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
            commands = next
        } else {
            HDRMergeKernels.encodeFeather(commands, gpu: gpu, feather: feather, source: usableHere, eroded: eroded,
                                          feathered: feathered)
            judged = feathered
        }
        let choose = try gpu.lazyPipeline(.mergeDeghostChooseReference)
        guard let chooser = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        chooser.setComputePipelineState(choose)
        chooser.setTexture(interval, index: 0)
        chooser.setTexture(judged, index: 1)
        chooser.setTexture(best, index: 2)
        chooser.setTexture(colour, index: 3)
        chooser.setTexture(bestColour, index: 4)
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

        // Kept on the CPU: low and high as half floats, the colour as half
        // floats and a byte, and how usable and exposed each block is.
        let count = mapWidth * mapHeight
        let region = MTLRegionMake2D(0, 0, mapWidth, mapHeight)
        var intervalReadback = [Float](repeating: 0, count: count * 4)
        var colourReadback = [Float](repeating: 0, count: count * 4)
        var usableReadback = [Float16](repeating: 0, count: count)
        interval.getBytes(&intervalReadback, bytesPerRow: mapWidth * 16, from: region, mipmapLevel: 0)
        colour.getBytes(&colourReadback, bytesPerRow: mapWidth * 16, from: region, mipmapLevel: 0)
        judged.getBytes(&usableReadback, bytesPerRow: mapWidth * 2, from: region, mipmapLevel: 0)
        // Converted row by row on every core: 1.3 million blocks for a 21 MP frame.
        let untrusted = Self.colourUntrusted
        let (intervalValues, colourValues, usableHalves) = (intervalReadback, colourReadback, usableReadback)
        let intervals = Self.filled(count * 2, Float16(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows {
                out[i * 2] = Float16(intervalValues[i * 4])
                out[i * 2 + 1] = Float16(intervalValues[i * 4 + 1])
            }
        }
        let colours = Self.filled(count * 2, Float16(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows {
                out[i * 2] = Float16(colourValues[i * 4])
                out[i * 2 + 1] = Float16(colourValues[i * 4 + 1])
            }
        }
        let allowances = Self.filled(count, UInt8(255), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows where colourValues[i * 4 + 2] < untrusted {
                out[i] = UInt8(min(254, (colourValues[i * 4 + 2] * 32).rounded(.up)))
            }
        }
        let exposed = Self.filled(count, UInt8(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows { out[i] = Self.byte(intervalValues[i * 4 + 2]) }
        }
        let usableBytes = Self.filled(count, UInt8(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows { out[i] = Self.byte(Float(usableHalves[i])) }
        }
        usableMaps[index] = usableBytes
        exposedMaps[index] = exposed
        relativeEVs[index] = relativeEV
        return HDRGhostMeasurement(width: mapWidth, height: mapHeight, intervals: intervals, colours: colours,
                                   allowances: allowances)
    }

    /// An array of `count` values starting at `initial`, which `fill` sets
    /// for the blocks of a band of rows at a time, on several threads at
    /// once. `fill` must only write the blocks it is given.
    static func filled<T: Sendable>(_ count: Int, _ initial: T, width: Int, height: Int,
                                    _ fill: @Sendable (UnsafeMutableBufferPointer<T>, Range<Int>) -> Void) -> [T] {
        var values = [T](repeating: initial, count: count)
        let bands = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 2))
        values.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let first = height * band / bands, last = height * (band + 1) / bands
                fill(buffer, (first * width)..<min(count, last * width))
            }
        }
        return values
    }

    /// MergeDeghost.metal's `mergeDeghostColourUntrusted` and `mergeDeghostNoColour`.
    static let colourUntrusted: Float = 4
    static let noColour: Float = 64

    /// 0...1 as a byte.
    static func byte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    /// The darkest frame's usable map, at least `darkestUsableFloor`
    /// everywhere, written into `destination` (shared).
    private func flooredUsable(_ source: MTLTexture, into destination: MTLTexture) throws -> MTLTexture {
        let count = mapWidth * mapHeight
        let region = MTLRegionMake2D(0, 0, mapWidth, mapHeight)
        var values = [Float16](repeating: 0, count: count)
        let readable: MTLTexture
        if source.storageMode == .shared {
            readable = source
        } else {
            readable = try scratchTexture(.r16Float, "usableReadable", storage: .shared)
            guard let commands = gpu.commandQueue.makeCommandBuffer(),
                  let blit = commands.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
            blit.copy(from: source, to: readable)
            blit.endEncoding()
            try HDRMergeKernels.run(commands)
        }
        readable.getBytes(&values, bytesPerRow: mapWidth * 2, from: region, mipmapLevel: 0)
        let floor = Float16(Self.darkestUsableFloor)
        for i in 0..<count { values[i] = max(values[i], floor) }
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            destination.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 2)
        }
        return destination
    }

    /// Largest log2 brightness (either way) a warped interval keeps: far
    /// beyond any real scene (2^64 times the brightest frame's white), small
    /// enough for 32-bit floats to blend to a hundred-thousandth of a stop.
    static let warpLimit: Float = 64

    /// Moves a measured frame onto the reference frame's quarter-size grid:
    /// its `interval` and `colour` in place, and its `usable` map into a new
    /// texture, which it returns.
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
    /// which never disagrees, the colour isn't trusted, and the block isn't
    /// usable, so the frame can't be the local reference there.
    ///
    /// "Unbounded" is 10,000 stops, which a blend would turn into thousands
    /// of stops of nonsense, so the logs are first clamped to plus or minus
    /// `warpLimit`: a blend with an unbounded limit still lands tens of
    /// stops beyond any real brightness, which the comparison treats as
    /// unbounded anyway. Colours blend the same way; an untrusted colour's
    /// allowance (`noColour`) is so large that any blend with it stays
    /// untrusted.
    private func warpMeasurement(interval: MTLTexture, colour: MTLTexture, usable: MTLTexture,
                                 movingToReference: simd_double3x3) throws -> MTLTexture {
        // The same move in quarter-size pixels: a map pixel's centre is its
        // block's centre, so full-resolution coordinates are just divided.
        let span = Double(HDRMergeKernels.maskSpan)
        let toMap = simd_double3x3(diagonal: SIMD3(1 / span, 1 / span, 1))
        let h = toMap * movingToReference * toMap.inverse

        let count = mapWidth * mapHeight
        let region = MTLRegionMake2D(0, 0, mapWidth, mapHeight)
        // "No limit", as MergeDeghost.metal's `mergeDeghostUnbounded` writes it.
        let limit = Self.warpLimit, unbounded: Float = 10000
        var measured = [Float](repeating: 0, count: count * 4)
        interval.getBytes(&measured, bytesPerRow: mapWidth * 16, from: region, mipmapLevel: 0)
        var colours = [Float](repeating: 0, count: count * 4)
        colour.getBytes(&colours, bytesPerRow: mapWidth * 16, from: region, mipmapLevel: 0)
        var usableHalves = [Float16](repeating: 0, count: count)
        usable.getBytes(&usableHalves, bytesPerRow: mapWidth * 2, from: region, mipmapLevel: 0)

        // Seven channels per block, each with what lies outside the frame:
        // low and high (clamped), exposed, the two colour ratios, the colour
        // allowance and usable.
        let channels = 7
        let outside: [Float] = [-limit, limit, 0, 0, 0, Self.noColour, 0]
        let (measuredIn, coloursIn, usableIn) = (measured, colours, usableHalves)
        let source = Self.filled(count * channels, Float(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows {
                out[i * 7] = min(max(measuredIn[i * 4], -limit), limit)
                out[i * 7 + 1] = min(max(measuredIn[i * 4 + 1], -limit), limit)
                out[i * 7 + 2] = measuredIn[i * 4 + 2]
                out[i * 7 + 3] = coloursIn[i * 4]
                out[i * 7 + 4] = coloursIn[i * 4 + 1]
                out[i * 7 + 5] = coloursIn[i * 4 + 2]
                out[i * 7 + 6] = Float(usableIn[i])
            }
        }
        // Bilinear, on the CPU: all seven channels share each block's four
        // neighbours and weights, which is several times quicker than seven
        // round trips through `MergeWarpKernels.warpMask` (whose sampling and
        // edge rules this follows).
        let moved = Self.warpBilinear(source, channels: channels, outside: outside, width: mapWidth,
                                      height: mapHeight, movingToReference: h)
        measured = Self.filled(count * 4, Float(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows {
                let low = moved[i * 7], high = moved[i * 7 + 1]
                out[i * 4] = low <= 0.999 * -limit ? -unbounded : low
                out[i * 4 + 1] = high >= 0.999 * limit ? unbounded : high
                out[i * 4 + 2] = moved[i * 7 + 2]
            }
        }
        colours = Self.filled(count * 4, Float(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows {
                out[i * 4] = moved[i * 7 + 3]
                out[i * 4 + 1] = moved[i * 7 + 4]
                out[i * 4 + 2] = moved[i * 7 + 5]
            }
        }
        usableHalves = Self.filled(count, Float16(0), width: mapWidth, height: mapHeight) { out, rows in
            for i in rows { out[i] = Float16(moved[i * 7 + 6]) }
        }
        measured.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            interval.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 16)
        }
        colours.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            colour.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 16)
        }
        let usableWarped = try scratchTexture(.r16Float, "usableWarped", storage: .shared)
        usableHalves.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            usableWarped.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 2)
        }
        return usableWarped
    }

    /// `source` (`channels` values per pixel, row by row) moved onto the
    /// grid of the frame it is `movingToReference` from, sampled bilinearly
    /// as `mergeWarpMask` does: each output pixel's centre mapped back into
    /// the source, a blend of the four pixels around it (edge pixels
    /// repeated), and `outside` where it lands beyond the source.
    static func warpBilinear(_ source: [Float], channels: Int, outside: [Float], width: Int, height: Int,
                             movingToReference: simd_double3x3) -> [Float] {
        let back = movingToReference.inverse
        var output = [Float](repeating: 0, count: source.count)
        output.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let out = out
            source.withUnsafeBufferPointer { src in
                nonisolated(unsafe) let src = src
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let o = (y * width + x) * channels
                        let p = back * SIMD3(Double(x) + 0.5, Double(y) + 0.5, 1)
                        let px = p.x / p.z, py = p.y / p.z
                        guard p.z > 1e-6, px >= 0, py >= 0, px <= Double(width), py <= Double(height) else {
                            for c in 0..<channels { out[o + c] = outside[c] }
                            continue
                        }
                        let ix = px - 0.5, iy = py - 0.5
                        let bx = Int(ix.rounded(.down)), by = Int(iy.rounded(.down))
                        let tx = Float(ix - Double(bx)), ty = Float(iy - Double(by))
                        let xa = min(max(bx, 0), width - 1), xb = min(max(bx + 1, 0), width - 1)
                        let ya = min(max(by, 0), height - 1), yb = min(max(by + 1, 0), height - 1)
                        let a = (ya * width + xa) * channels, b = (ya * width + xb) * channels
                        let c0 = (yb * width + xa) * channels, d = (yb * width + xb) * channels
                        for c in 0..<channels {
                            let top = src[a + c] + (src[b + c] - src[a + c]) * tx
                            let bottom = src[c0 + c] + (src[d + c] - src[c0 + c]) * tx
                            out[o + c] = top + (bottom - top) * ty
                        }
                    }
                }
            }
        }
        return output
    }

    /// Ends the measuring pass and frees its textures.
    public func finishMeasuring() {
        scratch.removeAll()
        measuringDone = true
    }

    /// Where frame `index` disagrees with the local references, from its
    /// measurement, added to the map of movement. Call `finishMeasuring()`
    /// first, and this for every frame before any `mask`, the reference
    /// frame too: it disagrees only where some other frame sees the block
    /// better. Returns the share of the frame found moving, 0...1. Waits
    /// for the GPU.
    public func findMovement(_ measurement: HDRGhostMeasurement, index: Int,
                             settings: HDRDeghostSettings) throws -> Double {
        guard measuringDone, framesMeasured > 0, areas == nil else {
            throw RenderError.commandBufferFailed
        }
        guard measurement.width == mapWidth, measurement.height == mapHeight else {
            throw HDRMergeKernelError.sizeMismatch(expected: "\(mapWidth) x \(mapHeight) mask",
                                                   actual: "\(measurement.width) x \(measurement.height)")
        }
        let count = mapWidth * mapHeight
        let region = MTLRegionMake2D(0, 0, mapWidth, mapHeight)
        let interval = try scratchTexture(.rg16Float, "maskInterval", storage: .shared)
        measurement.intervals.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            interval.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 4)
        }
        let colour = try scratchTexture(.rgba16Float, "maskColour", storage: .shared)
        var colours = [Float16](repeating: 0, count: count * 4)
        for i in 0..<count {
            colours[i * 4] = measurement.colours[i * 2]
            colours[i * 4 + 1] = measurement.colours[i * 2 + 1]
            let allowance = measurement.allowances[i]
            colours[i * 4 + 2] = allowance == 255 ? Float16(Self.noColour) : Float16(Float(allowance) / 32)
        }
        colours.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            colour.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 8)
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
        comparer.setTexture(colour, index: 3)
        comparer.setTexture(bestColour, index: 4)
        var frameIndex = Float(index)
        var gap = settings.gapStops, colourGap = settings.colourStops
        comparer.setBytes(&frameIndex, length: 4, index: 0)
        comparer.setBytes(&gap, length: 4, index: 1)
        comparer.setBytes(&colourGap, length: 4, index: 2)
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
        var found = [UInt8](repeating: 0, count: count)
        seeds.getBytes(&found, bytesPerRow: mapWidth, from: region, mipmapLevel: 0)
        return Double(found.lazy.filter { $0 >= 128 }.count) / Double(max(1, found.count))
    }

    /// Frame `index`'s ghost mask: every moving area, feathered, except
    /// where this frame is the area's source. Call after `findMovement` for
    /// every frame; the reference frame has a mask too. Waits for the GPU.
    public func mask(index: Int, settings: HDRDeghostSettings) throws -> HDRGhostMask {
        guard measuringDone else { throw RenderError.commandBufferFailed }
        let found = try areas ?? findAreas(settings: settings)
        areas = found
        let owned = try scratchTexture(.r16Float, "owned")
        let ownedFeathered = try scratchTexture(.r16Float, "ownedFeathered")
        let result = try scratchTexture(.r8Unorm, "mask", storage: .shared)
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        // 1. Where this frame is the source, feathered like the areas.
        let ownership = try gpu.lazyPipeline(.mergeDeghostOwnership)
        guard let owner = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        owner.setComputePipelineState(ownership)
        owner.setTexture(found.source, index: 0)
        owner.setTexture(owned, index: 1)
        var frameIndex = Float(index)
        owner.setBytes(&frameIndex, length: 4, index: 0)
        HDRMergeKernels.dispatch(owner, pso: ownership, width: mapWidth, height: mapHeight)
        owner.endEncoding()
        HDRMergeKernels.encodeBlur(commands, gpu: gpu, sigma: found.sigma, source: owned, destination: ownedFeathered)

        // 2. The mask: the areas, except where the frame is their source.
        let combine = try gpu.lazyPipeline(.mergeDeghostCombine)
        guard let combiner = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        combiner.setComputePipelineState(combine)
        combiner.setTexture(found.feathered, index: 0)
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

    /// Turns the movement every frame showed into moving areas, and gives
    /// each area its source frame. Once per merge, from the first `mask`.
    ///
    /// 1. On the GPU, the movement map is closed (widened, then narrowed
    ///    again by the same amount: gaps and holes up to twice
    ///    `closeRadius` fill in, the outline stays) and widened by
    ///    `dilateRadius`.
    /// 2. On the CPU, the areas are its connected parts (`HDRGhostAreas`).
    ///    Each gets one source frame for all of it, and blocks where that
    ///    frame is clipped get another.
    /// 3. The areas are feathered by `featherSigma`, and the source map is
    ///    uploaded for `mergeDeghostOwnership`.
    private func findAreas(settings: HDRDeghostSettings) throws -> (feathered: MTLTexture, source: MTLTexture,
                                                                    sigma: Float) {
        let count = mapWidth * mapHeight
        let region = MTLRegionMake2D(0, 0, mapWidth, mapHeight)
        let scale = radiusScale
        let closeRadius = Int((Float(max(0, settings.closeRadius)) * scale).rounded())
        let dilateRadius = Int((Float(max(0, settings.dilateRadius)) * scale).rounded())
        let sigma = settings.featherSigma * scale

        var movement = [Float16](repeating: 0, count: count)
        var widened = [Float16](repeating: 0, count: count)
        if framesCompared > 0 {
            let source = try scratchTexture(.r16Float, "movement")
            let closedUp = try scratchTexture(.r16Float, "movementClosedUp")
            let closed = try scratchTexture(.r16Float, "movementClosed")
            let grown = try scratchTexture(.r16Float, "movementGrown", storage: .shared)
            let original = try scratchTexture(.r16Float, "movementOriginal", storage: .shared)
            guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
            guard let blit = commands.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
            blit.copy(from: source, to: original)
            blit.endEncoding()
            let closeSize = 2 * closeRadius + 1, dilateSize = 2 * dilateRadius + 1
            let up = MPSImageAreaMax(device: gpu.device, kernelWidth: closeSize, kernelHeight: closeSize)
            up.edgeMode = .clamp
            up.encode(commandBuffer: commands, sourceTexture: source, destinationTexture: closedUp)
            let down = MPSImageAreaMin(device: gpu.device, kernelWidth: closeSize, kernelHeight: closeSize)
            down.edgeMode = .clamp
            down.encode(commandBuffer: commands, sourceTexture: closedUp, destinationTexture: closed)
            let grow = MPSImageAreaMax(device: gpu.device, kernelWidth: dilateSize, kernelHeight: dilateSize)
            grow.edgeMode = .clamp
            grow.encode(commandBuffer: commands, sourceTexture: closed, destinationTexture: grown)
            try HDRMergeKernels.run(commands)
            original.getBytes(&movement, bytesPerRow: mapWidth * 2, from: region, mipmapLevel: 0)
            grown.getBytes(&widened, bytesPerRow: mapWidth * 2, from: region, mipmapLevel: 0)
        }

        var candidates: [HDRGhostAreas.Frame] = []
        for index in usableMaps.keys.sorted() {
            guard let usable = usableMaps[index], let exposed = exposedMaps[index],
                  let relativeEV = relativeEVs[index] else { continue }
            candidates.append(HDRGhostAreas.Frame(index: index, relativeEV: relativeEV, usable: usable, exposed: exposed))
        }
        let areas = HDRGhostAreas(width: mapWidth, height: mapHeight, moving: movement.map { $0 >= 0.5 },
                                  widened: widened.map { $0 >= 0.5 }, frames: candidates,
                                  referenceIndex: referenceIndex)
        candidates.removeAll()
        usableMaps.removeAll()
        exposedMaps.removeAll()

        let inside = try scratchTexture(.r16Float, "areas", storage: .shared)
        let sources = try scratchTexture(.r32Float, "sources", storage: .shared)
        let feathered = try scratchTexture(.r16Float, "areasFeathered")
        let flags = areas.sources.map { Float16($0 < 0 ? 0 : 1) }
        flags.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            inside.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 2)
        }
        let indices = areas.sources.map { Float($0) }
        indices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            sources.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: mapWidth * 4)
        }
        guard let commands = gpu.commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        HDRMergeKernels.encodeBlur(commands, gpu: gpu, sigma: sigma, source: inside, destination: feathered)
        try HDRMergeKernels.run(commands)
        return (feathered, sources, sigma)
    }

    private func scratchTexture(_ format: MTLPixelFormat, _ purpose: String,
                                storage: MTLStorageMode = .private) throws -> MTLTexture {
        let key = "\(purpose)-\(format.rawValue)-\(storage.rawValue)"
        if let texture = scratch[key] { return texture }
        let texture = try HDRMergeKernels.makeTexture(gpu, width: mapWidth, height: mapHeight, format: format,
                                                      storage: storage)
        scratch[key] = texture
        return texture
    }
}

/// The moving areas of a bracket and the frame each block of them comes
/// from, worked out on the CPU from quarter-size maps (`HDRGhostDetector`
/// uses it; separate so the rules can be tested without a GPU).
///
/// **One source per area.** An area is a connected part of the widened
/// movement (4-connected: blocks touching only at a corner are separate).
/// Its source is the frame with the best score over it: the mean of how
/// usable times how well exposed each block is (as the local references
/// judge it), less `HDRGhostDetector.clippedAreaCost` for each clipped
/// block's share, plus `HDRGhostDetector.areaReferenceBonus` for the
/// reference frame and less a hundredth per stop for every other frame. So
/// the reference wherever it sees the area reasonably well, and otherwise
/// the frame that sees most of it without clipping.
///
/// **Large areas** (`HDRGhostDetector.largeAreaShare`) score every block
/// over the window around it instead (`HDRGhostDetector.largeAreaWindow`).
///
/// **Where the source is clipped** (usable under
/// `HDRGhostDetector.sourceUsableMinimum`), the merge will give it no
/// weight, so another frame has to fill in: the nearest darker frame that
/// isn't clipped there, or the darkest. Never a brighter frame: one that
/// isn't clipped where the source is shows something that moved, which on
/// glittering water came out as grey squares. Dark blocks aren't handed
/// over: the source is noisy there, but a noisy block is better than one
/// from another moment.
///
/// Areas with fewer than `HDRGhostDetector.minimumMovingBlocks` blocks of
/// movement in them are dropped as noise.
struct HDRGhostAreas {
    struct Frame {
        let index: Int
        let relativeEV: Double
        /// 0...255 per block.
        let usable: [UInt8]
        let exposed: [UInt8]
    }

    /// Per block, the frame index it comes from inside a moving area; -1 outside.
    let sources: [Int32]
    /// How many areas were kept.
    let areaCount: Int

    init(width: Int, height: Int, moving: [Bool], widened: [Bool], frames: [Frame], referenceIndex: Int) {
        let count = width * height
        var sources = [Int32](repeating: -1, count: count)
        guard !frames.isEmpty, count > 0, moving.count == count, widened.count == count else {
            self.sources = sources
            areaCount = 0
            return
        }
        let referenceEV = frames.first { $0.index == referenceIndex }?.relativeEV ?? frames[0].relativeEV
        /// A frame's score for one block, before the bonus or penalty.
        func blockScore(_ frame: Frame, _ i: Int) -> Double {
            Double(frame.usable[i]) * Double(frame.exposed[i]) / 65025
                - (frame.usable[i] < HDRGhostDetector.sourceUsableMinimum ? HDRGhostDetector.clippedAreaCost : 0)
        }
        func bias(_ frame: Frame) -> Double {
            frame.index == referenceIndex ? HDRGhostDetector.areaReferenceBonus
                : -Double(HDRGhostDetector.penaltyPerStop) * abs(frame.relativeEV - referenceEV)
        }

        let areas = Self.label(width: width, height: height, widened).filter { area in
            area.lazy.filter { moving[$0] }.count >= HDRGhostDetector.minimumMovingBlocks
        }
        var chosen = [Int32](repeating: -1, count: count)
        var large: [Bool]?
        // A share of the frame, but never of less than a 16 MP frame's map:
        // in a small frame a person can fill a large share.
        let scaleSide = Double(HDRGhostDetector.scaleLongEdge)
        let largeAreaBlocks = HDRGhostDetector.largeAreaShare * max(Double(count), scaleSide * scaleSide * 2 / 3)
        for area in areas {
            if Double(area.count) > largeAreaBlocks {
                if large == nil { large = [Bool](repeating: false, count: count) }
                for i in area { large?[i] = true }
                continue
            }
            var best = (score: -Double.infinity, index: frames[0].index)
            for frame in frames {
                var total = 0.0
                for i in area { total += blockScore(frame, i) }
                let score = total / Double(area.count) + bias(frame)
                if score > best.score { best = (score, frame.index) }
            }
            for i in area { chosen[i] = Int32(best.index) }
        }
        // Large areas: each block's best frame over the window around it.
        if let large {
            let radius = max(1, Int(Double(max(width, height)) * HDRGhostDetector.largeAreaWindow / 2))
            var bestScores = [Double](repeating: -Double.infinity, count: count)
            for frame in frames {
                let scores = (0..<count).map { large[$0] ? blockScore(frame, $0) : 0 }
                let weights = large.map { $0 ? 1.0 : 0.0 }
                let summed = Self.boxSum(scores, width: width, height: height, radius: radius)
                let counted = Self.boxSum(weights, width: width, height: height, radius: radius)
                let extra = bias(frame)
                for i in 0..<count where large[i] {
                    let score = summed[i] / max(counted[i], 1) + extra
                    if score > bestScores[i] {
                        bestScores[i] = score
                        chosen[i] = Int32(frame.index)
                    }
                }
            }
        }

        // Clipped blocks handed to the nearest darker frame that isn't.
        let byIndex = Dictionary(uniqueKeysWithValues: frames.map { ($0.index, $0) })
        let darkest = frames.min { $0.relativeEV < $1.relativeEV } ?? frames[0]
        for i in 0..<count where chosen[i] >= 0 {
            guard let source = byIndex[Int(chosen[i])] else { continue }
            if source.usable[i] >= HDRGhostDetector.sourceUsableMinimum {
                sources[i] = chosen[i]
                continue
            }
            // Where every darker frame is clipped too, the darkest: the
            // merge's weight floor shows it there anyway.
            var fill = darkest
            var nearest = -Double.infinity
            for frame in frames where frame.relativeEV < source.relativeEV && frame.relativeEV > nearest
                && frame.usable[i] >= HDRGhostDetector.sourceUsableMinimum {
                fill = frame
                nearest = frame.relativeEV
            }
            sources[i] = Int32(fill.index)
        }
        self.sources = sources
        areaCount = areas.count
    }

    /// The 4-connected parts of `inside`, each as its block indices.
    static func label(width: Int, height: Int, _ inside: [Bool]) -> [[Int]] {
        let count = width * height
        var seen = [Bool](repeating: false, count: count)
        var areas: [[Int]] = []
        var stack: [Int] = []
        for start in 0..<count where inside[start] && !seen[start] {
            var area: [Int] = []
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                area.append(i)
                let x = i % width
                if x > 0, inside[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < width - 1, inside[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if i >= width, inside[i - width], !seen[i - width] { seen[i - width] = true; stack.append(i - width) }
                if i + width < count, inside[i + width], !seen[i + width] {
                    seen[i + width] = true
                    stack.append(i + width)
                }
            }
            areas.append(area)
        }
        return areas
    }

    /// The sum of `values` over the (2 x radius + 1)² window around each
    /// block, clamped to the map: a running sum along rows, then along columns.
    static func boxSum(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        var rows = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            var prefix = [Double](repeating: 0, count: width + 1)
            for x in 0..<width { prefix[x + 1] = prefix[x] + values[y * width + x] }
            for x in 0..<width {
                rows[y * width + x] = prefix[min(width, x + radius + 1)] - prefix[max(0, x - radius)]
            }
        }
        var result = [Double](repeating: 0, count: values.count)
        var prefix = [Double](repeating: 0, count: height + 1)
        for x in 0..<width {
            for y in 0..<height { prefix[y + 1] = prefix[y] + rows[y * width + x] }
            for y in 0..<height {
                result[y * width + x] = prefix[min(height, y + radius + 1)] - prefix[max(0, y - radius)]
            }
        }
        return result
    }
}
