import Foundation
import Metal
import PixelEngine
import simd

// The panorama stitcher (docs/PhotoMerge.md section 4, stages 7 and 8):
// prepared frames and a layout in, the panorama out a tile at a time,
// never as one full-size texture (a 40,000 px panorama is far past the
// GPU's 16,384 px limit, and even a 16,384 x 6,000 one would be 1.6 GB of
// working textures).
//
// **The method.**
// 1. *Warp.* Every output pixel is traced through the projection into each
//    photo and sampled there (Catmull-Rom on a mip chain, so shrinking
//    averages what a pixel covers). Alpha is the share of the pixel the
//    photo covers.
// 2. *Seams.* Each pixel belongs to the photo whose optical axis points
//    nearest to it, among the photos that cover it: a Voronoi diagram on
//    the sphere. Photos overlap heavily near their centres' midlines, so
//    seams fall where both photos are sharpest and least vignetted.
// 3. *Multi-band blend* (Burt and Adelson, 1983). Each photo is split into
//    a Laplacian pyramid, detail bands from fine to coarse, in log(x + eps).
//    Each band is blended with the seam masks blurred to the band's own
//    scale: fine detail switches sharply at the seam (no ghosting), broad
//    brightness changes blend over hundreds of pixels (no visible step).
//    Pixels a photo doesn't cover are filled from its coarser levels first
//    ("push-pull"), so its border never shows as a dark rim.
//
// **Tiles.** The blend's fine levels are computed per tile with an apron
// (`PanoramaBlendPlan.requiredApron`), and the coarse levels once for the
// whole panorama at 1/8 scale (`tiledLevels`), where the seams are found
// too. Every pixel is computed from its own global coordinates with the
// same arithmetic whichever tile it is in, so tiles of any size give the
// same panorama (tests hold 512 and 4,096 px tiles within 1e-4).

/// Stitches one panorama. Use it from one thread; the stitch waits for the
/// GPU, so run it off the main thread.
///
///     let stitcher = try PanoramaStitcher(layout: layout, outputSize: size, frames: store, gpu: gpu)
///     try stitcher.stitch { tile in ... }              // push: tiles in reading order
///     let pixels = try stitcher.pixelSource()          // pull: for LinearRawDNGWriter
public final class PanoramaStitcher {
    public let layout: PanoramaLayout
    public let outputSize: PanoramaOutputSize
    public let options: PanoramaBlendOptions
    /// Decided by `prepare`.
    public private(set) var plan: PanoramaBlendPlan?
    /// The seams, from `prepare`.
    public private(set) var seamMap: PanoramaSeamMap?
    public private(set) var statistics = PanoramaBlendStatistics()

    typealias Place = MergePanoBlendKernels.Place
    typealias Grid = MergePanoBlendKernels.Grid

    private let source: PanoramaBlendFrameSource
    private let kernels: MergePanoBlendKernels
    private let cache: PanoramaFrameCache
    private let deviceBaseline: Int
    /// log(x + eps): eps = 1e-3 of the clip level.
    private let eps: Float
    private var cameras: [CameraState]
    private var coarseResult: MTLTexture?
    private var coarsePlace = Place(x: 0, y: 0, width: 0, height: 0)
    private var tileTextures: TileTextures?
    private var finished = false

    private struct CameraState {
        let camera: PanoramaCamera
        let frame: PanoramaPreparedFrame
        let mapping: MergePanoBlendKernels.FrameMapping
        var bounds: PixelRegion?
        /// The photo's filled pyramid level `tiledLevels` for the whole
        /// panorama (rgba32Float: log colour, coverage), which each tile's
        /// finest levels are built down from.
        var filledCoarse: MTLTexture?
        var filledCoarsePlace = Place(x: 0, y: 0, width: 0, height: 0)
    }

    /// Makes a stitcher. Nothing heavy happens until `prepare` or `stitch`.
    ///
    /// - Throws: `PanoramaBlendError.missingFrame` if a camera's photo has no
    ///   prepared frame, `.invalidLayout` for an empty output.
    public init(layout: PanoramaLayout, outputSize: PanoramaOutputSize, frames: PanoramaBlendFrameSource,
                options: PanoramaBlendOptions = PanoramaBlendOptions(), gpu: GPUContext) throws {
        guard outputSize.width > 0, outputSize.height > 0, outputSize.scale.isFinite, outputSize.scale > 0 else {
            throw PanoramaBlendError.invalidLayout("output size \(outputSize.width)x\(outputSize.height)")
        }
        guard layout.canvas.projection != .automatic, layout.canvas.pixelsPerRadian > 0 else {
            throw PanoramaBlendError.invalidLayout("the canvas has no projection")
        }
        guard !layout.cameras.isEmpty else { throw PanoramaBlendError.invalidLayout("no photos") }
        guard options.clipLevel.isFinite, options.clipLevel > 0 else {
            throw PanoramaBlendError.invalidLayout("clip level \(options.clipLevel)")
        }
        self.layout = layout
        self.outputSize = outputSize
        self.options = options
        self.source = frames
        kernels = MergePanoBlendKernels(gpu: gpu)
        cache = PanoramaFrameCache(kernels: kernels, source: frames, budget: options.frameCacheBytes)
        deviceBaseline = gpu.device.currentAllocatedSize
        eps = Float(1e-3 * options.clipLevel)
        // Where each photo can reach on the output, with the taps of the
        // coarse warp's wider footprint (which also covers the tiles' finer
        // warps), and its mapping there.
        let tiled = PanoramaBlendPlan.tiledLevels(width: outputSize.width, height: outputSize.height)
        cameras = try layout.cameras.enumerated().map { position, camera in
            guard let frame = frames.preparedFrame(camera.frameIndex) else {
                throw PanoramaBlendError.missingFrame(frameIndex: camera.frameIndex)
            }
            guard frame.width > 0, frame.height > 0, frame.sampleScale.isFinite, frame.sampleScale > 0 else {
                throw PanoramaBlendError.invalidFrame(frameIndex: camera.frameIndex, reason: "size or sample scale")
            }
            let footprint = PanoramaBlendGeometry.largestFootprint(camera: camera, frame: frame, canvas: layout.canvas,
                                                                   scale: outputSize.scale)
            let bounds = PanoramaBlendGeometry.outputBounds(
                camera: camera, frame: frame, canvas: layout.canvas, scale: outputSize.scale,
                outputWidth: outputSize.width, outputHeight: outputSize.height,
                reach: PanoramaBlendGeometry.reach(footprint: footprint * Double(1 << tiled)))
            let mapping = PanoramaBlendGeometry.mapping(camera: camera, position: position, canvas: layout.canvas,
                                                        scale: outputSize.scale, sampleScale: frame.sampleScale,
                                                        bounds: bounds)
            return CameraState(camera: camera, frame: frame, mapping: mapping, bounds: bounds)
        }
    }

    deinit {
        // Scratch files are the frame source's to delete; the stitcher only
        // does so when a stitch ends (`finish`).
        cache.removeAll()
    }

    // MARK: - Public operations

    /// The low-resolution pass: warps every photo onto the panorama at
    /// 1/2^tiledLevels scale, finds the seams, chooses the bands and blends
    /// the coarse levels. `stitch` and `pixelSource` call it if needed.
    @discardableResult
    public func prepare(progress: (PanoramaBlendProgress) -> Void = { _ in },
                        shouldCancel: () -> Bool = { false }) throws -> PanoramaBlendPlan {
        if let plan { return plan }
        guard !finished else { throw PanoramaBlendError.invalidLayout("the stitch has already finished") }
        do {
            return try runPrepare(progress: progress, shouldCancel: shouldCancel)
        } catch {
            finish()
            throw error
        }
    }

    /// Stitches the whole panorama, handing `consume` each tile in reading
    /// order. Checks for cancellation (`Task.isCancelled` or `shouldCancel`)
    /// between tiles and throws `CancellationError`. Ends with `finish()`,
    /// whether it completes, fails or is cancelled.
    public func stitch(progress: (PanoramaBlendProgress) -> Void = { _ in }, shouldCancel: () -> Bool = { false },
                       consume: (PanoramaStitchedTile) throws -> Void) throws {
        defer { finish() }
        let plan = try prepare(progress: progress, shouldCancel: shouldCancel)
        let clock = ContinuousClock(), start = clock.now
        defer { statistics.tileSeconds += Self.seconds(clock.now - start) }
        for row in 0..<plan.tilesDown {
            for column in 0..<plan.tilesAcross {
                try Self.checkCancellation(shouldCancel)
                let tile = plan.tile(column: column, row: row)
                try autoreleasepool {
                    try withTile(tile, plan: plan) { pixels in
                        try consume(PanoramaStitchedTile(region: tile, pixels: pixels))
                    }
                }
                statistics.tilesCompleted += 1
                progress(PanoramaBlendProgress(stage: .tiles, completed: statistics.tilesCompleted,
                                               total: plan.tileCount))
            }
        }
    }

    /// The panorama as a pixel source for `LinearRawDNGWriter`, which asks
    /// for regions in reading order: the source stitches a row of tiles
    /// when a region first needs it, keeps that row's RGB in a scratch file
    /// (the system pages it, so memory stays low), and calls `finish()`
    /// after the bottom-right pixel or when stitching fails. If the writer
    /// stops early on its own (cancelled between regions), call `finish()`.
    public func pixelSource(progress: @escaping (PanoramaBlendProgress) -> Void = { _ in },
                            shouldCancel: @escaping () -> Bool = { false }) throws -> LinearRawPixelSource {
        let plan = try prepare(progress: progress, shouldCancel: shouldCancel)
        let rows: PanoramaTileRowBuffer
        do {
            rows = try PanoramaTileRowBuffer(width: plan.width, rowHeight: plan.tileSize)
        } catch {
            finish()
            throw error
        }
        return LinearRawPixelSource(width: plan.width, height: plan.height) { [self] region, rgb in
            do {
                try fill(region, into: rgb, rows: rows, plan: plan, progress: progress, shouldCancel: shouldCancel)
                if region.y + region.height >= plan.height, region.x + region.width >= plan.width {
                    finish()
                    rows.release()
                }
            } catch {
                finish()
                rows.release()
                throw error
            }
        }
    }

    /// Releases the GPU memory the stitch holds and, if the options say so,
    /// deletes the frame source's scratch files. Safe to call more than
    /// once; the stitcher can't stitch afterwards.
    public func finish() {
        guard !finished else { return }
        finished = true
        cache.removeAll()
        tileTextures = nil
        coarseResult = nil
        for index in cameras.indices { cameras[index].filledCoarse = nil }
        if options.removeScratchWhenFinished { source.removeScratch() }
    }

    // MARK: - The coarse pass

    private func runPrepare(progress: (PanoramaBlendProgress) -> Void, shouldCancel: () -> Bool) throws
        -> PanoramaBlendPlan {
        let clock = ContinuousClock(), start = clock.now
        defer { statistics.prepareSeconds += Self.seconds(clock.now - start) }
        let width = outputSize.width, height = outputSize.height
        let tiled = PanoramaBlendPlan.tiledLevels(width: width, height: height)
        let step = 1 << tiled
        let coarseWidth = Self.ceilDiv(width, step), coarseHeight = Self.ceilDiv(height, step)
        let coarseGrid = Place(x: 0, y: 0, width: coarseWidth, height: coarseHeight)

        // 1. Warp every photo at the coarse level and offer it to the seams.
        let best = try kernels.makeTexture(width: coarseWidth, height: coarseHeight, format: .rgba32Float, shared: true)
        try run { commands in
            try kernels.encodeClear(commands, best, width: coarseWidth, height: coarseHeight, value: SIMD4(-1, -1, 0, 0))
        }
        var warps = [(texture: MTLTexture, place: Place)?](repeating: nil, count: cameras.count)
        for index in cameras.indices {
            try Self.checkCancellation(shouldCancel)
            defer { progress(PanoramaBlendProgress(stage: .seams, completed: index + 1, total: cameras.count)) }
            guard let bounds = cameras[index].bounds else { continue }
            // Four coarse pixels of margin: the coarse pyramid's filters
            // reach that far past the photo's coverage.
            let place = Self.clip(Place(x: bounds.x / step - 4, y: bounds.y / step - 4,
                                        width: Self.ceilDiv(bounds.x + bounds.width, step) + 4 - (bounds.x / step - 4),
                                        height: Self.ceilDiv(bounds.y + bounds.height, step) + 4 - (bounds.y / step - 4)),
                                  to: coarseGrid)
            let frameTexture = try cache.texture(cameras[index].camera.frameIndex, frame: cameras[index].frame)
            let warped = try kernels.makeTexture(width: place.width, height: place.height, format: .rgba16Float,
                                                 shared: true)
            let grid = Grid(place: place, canvasWidth: coarseWidth, canvasHeight: coarseHeight, step: step)
            try run { commands in
                try kernels.encodeWarp(commands, frame: frameTexture, mapping: cameras[index].mapping, grid: grid,
                                       into: warped)
                try kernels.encodeLabel(commands, warped: warped, mapping: cameras[index].mapping, grid: grid,
                                        best: best, bestPlace: coarseGrid)
            }
            warps[index] = (warped, place)
            sampleMemory()
        }

        // 2. The seam map, and the bands it implies.
        let labels = Self.readRGBA32(best, width: coarseWidth, height: coarseHeight)
        let seams = PanoramaSeamMap(width: coarseWidth, height: coarseHeight, step: step,
                                    labels: stride(from: 0, to: labels.count, by: 4).map {
                                        labels[$0] > 0 ? Int16(labels[$0 + 1]) : -1 },
                                    coverage: stride(from: 0, to: labels.count, by: 4).map { min(labels[$0 + 2], 1) })
        seamMap = seams
        let halfOverlap = Self.medianHalfOverlap(seams: seams, warps: warps)
        let bands = options.bands.map { min(max($0, tiled + 1), 16) }
            ?? PanoramaBlendPlan.bands(halfOverlap: halfOverlap, tiledLevels: tiled, width: width, height: height)

        // 3. The coarse levels of the blend, photo by photo, into sums per level.
        let levels = Array(tiled...bands)
        func levelGrid(_ level: Int) -> Place {
            Place(x: 0, y: 0, width: Self.ceilDiv(width, 1 << level), height: Self.ceilDiv(height, 1 << level))
        }
        var sums: [MTLTexture] = []
        for level in levels {
            let grid = levelGrid(level)
            let texture = try kernels.makeTexture(width: grid.width, height: grid.height, format: .rgba32Float,
                                                  shared: true)
            sums.append(texture)
        }
        try run { commands in
            for (offset, level) in levels.enumerated() {
                let grid = levelGrid(level)
                try kernels.encodeClear(commands, sums[offset], width: grid.width, height: grid.height, value: .zero)
            }
        }
        for index in cameras.indices {
            try Self.checkCancellation(shouldCancel)
            guard let warp = warps[index] else { continue }
            let warped = warp.texture, place = warp.place
            // Each coarser level's patch: half the finer one, plus 4 pixels
            // of margin for the filters, inside that level's grid.
            var places = [place]
            for level in levels.dropFirst() {
                let finer = places.last!
                places.append(Self.clip(Place(x: finer.x / 2 - 4, y: finer.y / 2 - 4,
                                              width: Self.ceilDiv(finer.x + finer.width, 2) + 4 - (finer.x / 2 - 4),
                                              height: Self.ceilDiv(finer.y + finer.height, 2) + 4 - (finer.y / 2 - 4)),
                                        to: levelGrid(level)))
            }
            var pyramid: [MTLTexture] = [], weight: [MTLTexture] = []
            for patch in places {
                pyramid.append(try kernels.makeTexture(width: patch.width, height: patch.height, format: .rgba32Float,
                                                       shared: true))
                weight.append(try kernels.makeTexture(width: patch.width, height: patch.height, format: .r32Float))
            }
            let coarseGridAtTiled = Grid(place: place, canvasWidth: coarseWidth, canvasHeight: coarseHeight, step: step)
            try run { commands in
                try kernels.encodeLog(commands, warped: warped, grid: coarseGridAtTiled, best: best,
                                      bestPlace: coarseGrid, pyramid: pyramid[0], weight: weight[0], eps: eps,
                                      position: index)
                for k in 0..<(places.count - 1) {
                    try encodeReduce(commands, pyramid: pyramid, weight: weight, places: places, from: k)
                }
            }
            // The photo's mean log colour at the coarsest level, which fills
            // what it doesn't cover there.
            let coarsest = places.count - 1
            guard let mean = Self.coverageWeightedMean(pyramid[coarsest], place: places[coarsest]) else {
                cameras[index].bounds = nil
                continue
            }
            try run { commands in
                try kernels.encodeExpandFill(commands, pyramid: pyramid[coarsest], weight: weight[coarsest],
                                             place: places[coarsest], coarse: nil, coarsePlace: places[coarsest],
                                             accumulator: sums[coarsest], accumulatorPlace: levelGrid(levels[coarsest]),
                                             mean: mean)
                for k in stride(from: coarsest - 1, through: 0, by: -1) {
                    try kernels.encodeExpandFill(commands, pyramid: pyramid[k], weight: weight[k], place: places[k],
                                                 coarse: pyramid[k + 1], coarsePlace: places[k + 1],
                                                 accumulator: sums[k], accumulatorPlace: levelGrid(levels[k]))
                }
            }
            cameras[index].filledCoarse = pyramid[0]
            cameras[index].filledCoarsePlace = places[0]
            sampleMemory()
        }

        // 4. Collapse the coarse levels: the blended panorama at level `tiled`.
        let coarsestSums = sums[levels.count - 1]
        let fill = Self.meanBand(coarsestSums, place: levelGrid(bands)) ?? .zero
        try run { commands in
            try kernels.encodeCollapse(commands, accumulator: coarsestSums, place: levelGrid(bands), coarse: nil,
                                       coarsePlace: levelGrid(bands), fill: fill)
            for k in stride(from: levels.count - 2, through: 0, by: -1) {
                try kernels.encodeCollapse(commands, accumulator: sums[k], place: levelGrid(levels[k]), coarse: sums[k + 1],
                                           coarsePlace: levelGrid(levels[k + 1]))
            }
        }
        coarseResult = sums[0]
        coarsePlace = levelGrid(tiled)
        sampleMemory()

        var tileSize = max(options.tileSize, 4 * step)
        tileSize = Self.ceilDiv(tileSize, step) * step
        let plan = PanoramaBlendPlan(width: width, height: height, tiledLevels: tiled, bands: bands,
                                     halfOverlap: halfOverlap, tileSize: tileSize,
                                     apron: PanoramaBlendPlan.requiredApron(tiledLevels: tiled),
                                     frameBounds: cameras.map(\.bounds))
        self.plan = plan
        return plan
    }

    /// Encodes reduce k -> k + 1 of a photo's colour pyramid and its weights.
    private func encodeReduce(_ commands: MTLCommandBuffer, pyramid: [MTLTexture], weight: [MTLTexture],
                              places: [Place], from k: Int) throws {
        let scratchWidth = places[k + 1].width, scratchHeight = places[k].height
        let colourScratch = try kernels.makeTexture(width: scratchWidth, height: scratchHeight, format: .rgba32Float)
        let weightScratch = try kernels.makeTexture(width: scratchWidth, height: scratchHeight, format: .r32Float)
        try kernels.encodeReduce(commands, source: pyramid[k], sourcePlace: places[k], destination: pyramid[k + 1],
                                 destinationPlace: places[k + 1], scratch: colourScratch, colour: true)
        try kernels.encodeReduce(commands, source: weight[k], sourcePlace: places[k], destination: weight[k + 1],
                                 destinationPlace: places[k + 1], scratch: weightScratch, colour: false)
    }

    // MARK: - Tiles

    /// The textures every tile reuses, sized for the largest window.
    private final class TileTextures {
        let warped: [MTLTexture]
        let best: MTLTexture
        let pyramid: [MTLTexture]
        let weight: [MTLTexture]
        let sums: [MTLTexture]
        let colourScratch: MTLTexture
        let weightScratch: MTLTexture
        let output: MTLTexture
        var pixels: [Float16]

        init(kernels: MergePanoBlendKernels, plan: PanoramaBlendPlan) throws {
            let width = min(plan.width, plan.tileSize + 2 * plan.apron)
            let height = min(plan.height, plan.tileSize + 2 * plan.apron)
            let slots = max(plan.mostCamerasPerTile, 1)
            let array = try kernels.makeTexture(width: width, height: height, format: .rgba16Float, arrayLength: slots)
            warped = try (0..<slots).map { try kernels.view(array, slice: $0) }
            best = try kernels.makeTexture(width: width, height: height, format: .rgba32Float)
            var pyramid: [MTLTexture] = [], weight: [MTLTexture] = [], sums: [MTLTexture] = []
            for level in 0..<plan.tiledLevels {
                let w = PanoramaStitcher.ceilDiv(width, 1 << level), h = PanoramaStitcher.ceilDiv(height, 1 << level)
                pyramid.append(try kernels.makeTexture(width: w, height: h, format: .rgba32Float))
                weight.append(try kernels.makeTexture(width: w, height: h, format: .r32Float))
                sums.append(try kernels.makeTexture(width: w, height: h, format: .rgba32Float))
            }
            self.pyramid = pyramid
            self.weight = weight
            self.sums = sums
            colourScratch = try kernels.makeTexture(width: PanoramaStitcher.ceilDiv(width, 2), height: height,
                                                    format: .rgba32Float)
            weightScratch = try kernels.makeTexture(width: PanoramaStitcher.ceilDiv(width, 2), height: height,
                                                    format: .r32Float)
            let tile = min(plan.tileSize, max(plan.width, plan.height))
            output = try kernels.makeTexture(width: min(tile, plan.width), height: min(tile, plan.height),
                                             format: .rgba16Float, shared: true)
            pixels = [Float16](repeating: 0, count: output.width * output.height * 4)
        }
    }

    /// Blends one tile and calls `body` with its rgba pixels.
    private func withTile(_ tile: PixelRegion, plan: PanoramaBlendPlan,
                          _ body: (UnsafeBufferPointer<Float16>) throws -> Void) throws {
        guard !finished, let coarseResult else { throw PanoramaBlendError.invalidLayout("the stitch has finished") }
        let textures = try tileTextures ?? TileTextures(kernels: kernels, plan: plan)
        tileTextures = textures
        let window = plan.window(for: tile)
        let tiled = plan.tiledLevels
        let windowPlace = Place(x: window.x, y: window.y, width: window.width, height: window.height)
        func place(_ level: Int) -> Place {
            let x = window.x >> level, y = window.y >> level
            return Place(x: x, y: y, width: Self.ceilDiv(window.x + window.width, 1 << level) - x,
                         height: Self.ceilDiv(window.y + window.height, 1 << level) - y)
        }
        let grid = Grid(place: windowPlace, canvasWidth: plan.width, canvasHeight: plan.height, step: 1)
        let touching = plan.cameras(touching: window).filter { cameras[$0].filledCoarse != nil }

        // Warp each photo and offer it to the seams, one photo per command
        // buffer: a frame can then leave the GPU before the next arrives.
        try run { commands in
            try kernels.encodeClear(commands, textures.best, width: window.width, height: window.height,
                                    value: SIMD4(-1, -1, 0, 0))
            for level in 0..<tiled {
                let patch = place(level)
                try kernels.encodeClear(commands, textures.sums[level], width: patch.width, height: patch.height,
                                        value: .zero)
            }
        }
        for (slot, index) in touching.enumerated() {
            let frameTexture = try cache.texture(cameras[index].camera.frameIndex, frame: cameras[index].frame)
            try run { commands in
                try kernels.encodeWarp(commands, frame: frameTexture, mapping: cameras[index].mapping, grid: grid,
                                       into: textures.warped[slot])
                try kernels.encodeLabel(commands, warped: textures.warped[slot], mapping: cameras[index].mapping,
                                        grid: grid, best: textures.best, bestPlace: windowPlace)
            }
        }
        sampleMemory()

        // Each photo's fine pyramid levels, built down from its shared
        // coarse level, added into the tile's sums.
        let places = (0..<tiled).map(place)
        for (slot, index) in touching.enumerated() {
            try run { commands in
                try kernels.encodeLog(commands, warped: textures.warped[slot], grid: grid, best: textures.best,
                                      bestPlace: windowPlace, pyramid: textures.pyramid[0], weight: textures.weight[0],
                                      eps: eps, position: index)
                for k in 0..<(tiled - 1) {
                    try kernels.encodeReduce(commands, source: textures.pyramid[k], sourcePlace: places[k],
                                             destination: textures.pyramid[k + 1], destinationPlace: places[k + 1],
                                             scratch: textures.colourScratch, colour: true)
                    try kernels.encodeReduce(commands, source: textures.weight[k], sourcePlace: places[k],
                                             destination: textures.weight[k + 1], destinationPlace: places[k + 1],
                                             scratch: textures.weightScratch, colour: false)
                }
                for k in stride(from: tiled - 1, through: 0, by: -1) {
                    let coarser = k == tiled - 1 ? cameras[index].filledCoarse! : textures.pyramid[k + 1]
                    let coarserPlace = k == tiled - 1 ? cameras[index].filledCoarsePlace : places[k + 1]
                    try kernels.encodeExpandFill(commands, pyramid: textures.pyramid[k], weight: textures.weight[k],
                                                 place: places[k], coarse: coarser, coarsePlace: coarserPlace,
                                                 accumulator: textures.sums[k], accumulatorPlace: places[k])
                }
            }
        }
        sampleMemory()

        // Collapse onto the shared coarse result, and back to linear light.
        try run { commands in
            for k in stride(from: tiled - 1, through: 0, by: -1) {
                let coarser = k == tiled - 1 ? coarseResult : textures.sums[k + 1]
                try kernels.encodeCollapse(commands, accumulator: textures.sums[k], place: places[k], coarse: coarser,
                                           coarsePlace: k == tiled - 1 ? coarsePlace : places[k + 1])
            }
            try kernels.encodeFinish(commands, collapsed: textures.sums[0], best: textures.best,
                                     offset: SIMD2(tile.x - window.x, tile.y - window.y), width: tile.width,
                                     height: tile.height, output: textures.output, eps: eps)
        }
        let count = tile.width * tile.height * 4
        try textures.pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw PanoramaBlendError.invalidLayout("empty tile") }
            textures.output.getBytes(base, bytesPerRow: tile.width * 8,
                                     from: MTLRegionMake2D(0, 0, tile.width, tile.height), mipmapLevel: 0)
        }
        try textures.pixels.withUnsafeBufferPointer { buffer in
            try body(UnsafeBufferPointer(rebasing: buffer[0..<count]))
        }
    }

    /// Fills a writer's region from rows of tiles, stitching rows as needed.
    private func fill(_ region: PixelRegion, into rgb: UnsafeMutableBufferPointer<Float16>, rows: PanoramaTileRowBuffer,
                      plan: PanoramaBlendPlan, progress: (PanoramaBlendProgress) -> Void,
                      shouldCancel: () -> Bool) throws {
        guard rgb.count >= region.pixelCount * 3, let destination = rgb.baseAddress else {
            throw MergeDNGError.bufferSizeMismatch(expected: region.pixelCount * 3, actual: rgb.count)
        }
        var y = region.y
        while y < region.y + region.height {
            let row = y / plan.tileSize
            if rows.row != row {
                let clock = ContinuousClock(), start = clock.now
                for column in 0..<plan.tilesAcross {
                    try Self.checkCancellation(shouldCancel)
                    let tile = plan.tile(column: column, row: row)
                    try autoreleasepool {
                        try withTile(tile, plan: plan) { pixels in
                            try rows.store(pixels, tile: tile, rowTop: row * plan.tileSize)
                        }
                    }
                    statistics.tilesCompleted += 1
                    progress(PanoramaBlendProgress(stage: .tiles, completed: statistics.tilesCompleted,
                                                   total: plan.tileCount))
                }
                rows.row = row
                statistics.tileSeconds += Self.seconds(clock.now - start)
            }
            let count = min(region.y + region.height, (row + 1) * plan.tileSize) - y
            try rows.copy(rows: (y - row * plan.tileSize)..<(y - row * plan.tileSize + count), x: region.x,
                          width: region.width, into: destination + (y - region.y) * region.width * 3)
            y += count
        }
    }

    // MARK: - Helpers

    /// Encodes into one command buffer and waits for it. Inside an
    /// autorelease pool: command buffers are autoreleased and hold on to
    /// every texture they used, so without a pool a long stitch would keep
    /// all its tiles' textures alive until it returned.
    private func run(_ encode: (MTLCommandBuffer) throws -> Void) throws {
        try autoreleasepool {
            guard let commands = kernels.gpu.commandQueue.makeCommandBuffer() else {
                throw RenderError.commandBufferFailed
            }
            try encode(commands)
            try MergePanoBlendKernels.run(commands)
        }
    }

    private func sampleMemory() {
        statistics.peakTextureBytes = max(statistics.peakTextureBytes, kernels.liveTextureBytes)
        statistics.peakFrameCacheBytes = cache.peakBytes
        statistics.frameUploads = cache.uploads
        statistics.peakDeviceBytes = max(statistics.peakDeviceBytes,
                                         kernels.gpu.device.currentAllocatedSize - deviceBaseline)
    }

    static func checkCancellation(_ shouldCancel: () -> Bool) throws {
        if Task.isCancelled || shouldCancel() { throw CancellationError() }
    }

    static func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    private static func clip(_ place: Place, to grid: Place) -> Place {
        let x0 = max(place.x, grid.x), y0 = max(place.y, grid.y)
        let x1 = min(place.maxX, grid.maxX), y1 = min(place.maxY, grid.maxY)
        return Place(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    static func readRGBA32(_ texture: MTLTexture, width: Int, height: Int) -> [Float] {
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }
        return values
    }

    /// Sum of coverage x log colour over sum of coverage, or nil if nothing is covered.
    private static func coverageWeightedMean(_ texture: MTLTexture, place: Place) -> SIMD3<Float>? {
        let values = readRGBA32(texture, width: place.width, height: place.height)
        var sum = SIMD3<Double>.zero, total = 0.0
        for i in stride(from: 0, to: values.count, by: 4) where values[i + 3] > 0 {
            let a = Double(values[i + 3])
            sum += a * SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
            total += a
        }
        guard total > 0 else { return nil }
        return SIMD3<Float>(sum / total)
    }

    /// The mean blended band where any weight reached, from the sums.
    private static func meanBand(_ texture: MTLTexture, place: Place) -> SIMD3<Float>? {
        let values = readRGBA32(texture, width: place.width, height: place.height)
        var sum = SIMD3<Double>.zero, count = 0.0
        for i in stride(from: 0, to: values.count, by: 4) where values[i + 3] > 0 {
            sum += SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2])) / Double(values[i + 3])
            count += 1
        }
        return count > 0 ? SIMD3<Float>(sum / count) : nil
    }

    /// The median, over every pixel where two photos' seams meet, of the
    /// distance to the nearer of the two photos' edges, in output pixels.
    static func medianHalfOverlap(seams: PanoramaSeamMap, warps: [(texture: MTLTexture, place: Place)?]) -> Double? {
        // Per photo, each coarse pixel's distance to the nearest pixel the
        // photo covers less than half of.
        let distances: [[Float]?] = warps.map { warp in
            guard let warp else { return nil }
            let w = warp.place.width, h = warp.place.height
            var halves = [Float16](repeating: 0, count: w * h * 4)
            halves.withUnsafeMutableBytes { bytes in
                warp.texture.getBytes(bytes.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h),
                                      mipmapLevel: 0)
            }
            let inside = (0..<(w * h)).map { halves[$0 * 4 + 3] >= 0.5 }
            return distanceToOutside(inside, width: w, height: h)
        }
        func distance(_ camera: Int, _ x: Int, _ y: Int) -> Float {
            guard camera >= 0, camera < warps.count, let warp = warps[camera], let map = distances[camera] else { return 0 }
            let lx = x - warp.place.x, ly = y - warp.place.y
            guard lx >= 0, ly >= 0, lx < warp.place.width, ly < warp.place.height else { return 0 }
            return map[ly * warp.place.width + lx]
        }
        var found: [Float] = []
        let w = seams.width, h = seams.height
        for y in 0..<h {
            for x in 0..<w {
                let label = Int(seams.labels[y * w + x])
                guard label >= 0 else { continue }
                for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < w && ny < h {
                    let other = Int(seams.labels[ny * w + nx])
                    guard other >= 0, other != label else { continue }
                    found.append(min(distance(label, x, y), distance(other, x, y)))
                }
            }
        }
        guard !found.isEmpty else { return nil }
        found.sort()
        return Double(found[found.count / 2]) * Double(seams.step)
    }

    /// Chamfer distance (in pixels, to within about 8%) from each pixel to
    /// the nearest one outside `inside`; beyond the map counts as outside.
    static func distanceToOutside(_ inside: [Bool], width: Int, height: Int) -> [Float] {
        let far = Float(width + height)
        var d = inside.map { $0 ? far : 0 }
        let diagonal: Float = 1.4142
        func at(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= width || y >= height ? 0 : d[y * width + x] }
        for y in 0..<height {
            for x in 0..<width where d[y * width + x] > 0 {
                d[y * width + x] = min(d[y * width + x], at(x - 1, y) + 1, at(x, y - 1) + 1,
                                       at(x - 1, y - 1) + diagonal, at(x + 1, y - 1) + diagonal)
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where d[y * width + x] > 0 {
                d[y * width + x] = min(d[y * width + x], at(x + 1, y) + 1, at(x, y + 1) + 1,
                                       at(x + 1, y + 1) + diagonal, at(x - 1, y + 1) + diagonal)
            }
        }
        return d
    }
}

/// One row of stitched tiles as RGB half floats, in a scratch file, for the
/// pull-style pixel source.
final class PanoramaTileRowBuffer {
    let width: Int
    let rowHeight: Int
    /// The tile row the buffer holds, or nil.
    var row: Int?
    private var file: PanoramaScratchFile?

    init(width: Int, rowHeight: Int) throws {
        self.width = width
        self.rowHeight = rowHeight
        let parent = PanoramaFrameStore.scratchParent
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-rows-\(UUID().uuidString)")
        file = try PanoramaScratchFile(url: url, byteCount: width * rowHeight * 6)
    }

    /// Stores a tile's rgba pixels (alpha dropped) at its place in the row.
    func store(_ rgba: UnsafeBufferPointer<Float16>, tile: PixelRegion, rowTop: Int) throws {
        guard let pointer = file?.pointer, let source = rgba.baseAddress else {
            throw PanoramaBlendError.scratchFile("the row buffer was released")
        }
        let rows = pointer.assumingMemoryBound(to: Float16.self)
        for r in 0..<tile.height {
            let target = UnsafeMutableBufferPointer(start: rows + ((tile.y - rowTop + r) * width + tile.x) * 3,
                                                    count: tile.width * 3)
            try PixelCopy.rgb(from: source + r * tile.width * 4, channels: 4, sourceRowSamples: tile.width * 4,
                              region: PixelRegion(x: 0, y: 0, width: tile.width, height: 1), into: target)
        }
    }

    /// Copies `rows` of the buffer, `width` pixels from `x`, to `destination`.
    func copy(rows: Range<Int>, x: Int, width regionWidth: Int, into destination: UnsafeMutablePointer<Float16>) throws {
        guard let pointer = file?.pointer else { throw PanoramaBlendError.scratchFile("the row buffer was released") }
        let halves = pointer.assumingMemoryBound(to: Float16.self)
        for (offset, r) in rows.enumerated() {
            (destination + offset * regionWidth * 3).update(from: halves + (r * width + x) * 3, count: regionWidth * 3)
        }
    }

    func release() {
        file = nil
        row = nil
    }
}
