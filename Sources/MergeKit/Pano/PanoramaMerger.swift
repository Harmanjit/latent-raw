// The panorama merge: overlapping photos in, one LinearRaw DNG out
// (docs/PhotoMerge.md section 4). The pieces it drives were built and tested
// separately; this is the class that runs them in order.

import CoreGraphics
import Foundation
import Metal
import PixelEngine
import RawCore
import simd

/// Stitches selected photos into a panorama DNG.
///
/// **Analysis** (`analyse`) opens every photo, decodes a 1/8-scale copy of
/// each (`PanoramaFramePrep`), solves where the cameras pointed
/// (`PanoramaLayoutSolver`), sizes the result for this Mac
/// (`PanoramaOutputSizer`) and reports what the dialog must say. It keeps
/// the small copies so the preview needn't read the photos again
/// (`releasePreviews()` drops them).
///
/// **Preview** (`preview`) stitches those small copies through the real
/// `PanoramaStitcher` — the same seams and the same multi-band blend as the
/// merge — and renders the result through the normal pipeline, so the
/// dialog shows what it will get, not an approximation.
///
/// **Merge** (`merge`) prepares each photo at the output's decode span, one
/// at a time, into memory-mapped scratch files (`PanoramaFrameStore`), so
/// only one frame is ever on the GPU; stitches the panorama tile by tile;
/// and streams the tiles straight into `LinearRawDNGWriter`. Nothing
/// full-size is ever held in memory.
///
/// **The brightest value.** The DNG writer divides the pixels by a power of
/// two so nothing is above 1.0 (`ExposureNormalisation`), and needs that
/// divisor *before* the tiles stream past it once. The merge works it out
/// while preparing the frames: the largest colour value in each prepared
/// frame times the gain the layout gives it, the largest of those over
/// every frame, and then `blendHeadroom` (a stop) on top, because a
/// multi-band blend can overshoot its inputs a little at a strong edge. A
/// power of two costs nothing: `BaselineExposure` takes the stops back, and
/// half floats keep their precision when they are only rescaled.
///
/// **What the result is.** A lens-corrected linear image: `lensApplied` is
/// true in the recipe and no lens is named in the file, so nothing corrects
/// it twice. Its metadata is the first connected photo's, but upright
/// (orientation 1), because the stitch already is. Auto Crop travels in the
/// recipe as a rectangle in the output's own pixels (and normalised); the
/// app stores it as an undoable crop edit rather than cutting it off.
public final class PanoramaMerger: PanoramaMerging {
    let gpu: GPUContext
    /// Free space on the volume holding a URL; replaceable for tests.
    let availableCapacity: @Sendable (URL) -> Int64?
    /// What the output is sized against; nil asks the GPU. Tests force a
    /// small budget to exercise the downsampling path.
    let sizeLimits: SizeLimits?
    let previewCache = PanoramaPreviewCache()

    /// The limits the output size is worked out from
    /// (`PanoramaOutputSizer`).
    public struct SizeLimits: Sendable, Equatable {
        public var maxTextureSide: Int
        public var editPixelBudget: Double

        public init(maxTextureSide: Int, editPixelBudget: Double) {
            self.maxTextureSide = maxTextureSide
            self.editPixelBudget = editPixelBudget
        }
    }

    public convenience init(gpu: GPUContext) {
        self.init(gpu: gpu, sizeLimits: nil)
    }

    init(gpu: GPUContext, sizeLimits: SizeLimits? = nil,
         availableCapacity: @escaping @Sendable (URL) -> Int64? = LinearRawDNGWriter.volumeAvailableCapacity) {
        self.gpu = gpu
        self.sizeLimits = sizeLimits
        self.availableCapacity = availableCapacity
    }

    /// Long edge of the JPEG preview stored in the DNG.
    static let previewLongEdge = 1600
    /// Free space to leave on the volume beyond the file (as the writer does).
    static let freeSpaceMargin: Int64 = 64_000_000
    /// Output pixels per side of a blend tile (`PanoramaBlendOptions`).
    static let tileSize = 1024
    /// See the note on the brightest value: a stop of room for the blend's
    /// overshoot at a strong edge.
    static let blendHeadroom: Float = 2
    /// Photos differing by more than this many stops after gain
    /// compensation are worth warning about.
    static let unevenExposureStops = 0.2
    /// A solve that explains the matches only to this many full-resolution
    /// pixels is parallax, not noise, and near things may double.
    static let largeParallaxPixels = 3.0
    /// Exposure measurements over fewer texels than this are too small a
    /// sample to warn from.
    static let exposureSampleFloor = 500

    // MARK: - Analysis

    public func analyse(_ urls: [URL], options: PanoramaMergeOptions) async throws -> PanoramaMergeAnalysis {
        try await analyseWithReport(urls, options: options).analysis
    }

    /// `analyse`, with how long each stage took and what the geometry found.
    public func analyseWithReport(_ urls: [URL], options: PanoramaMergeOptions = PanoramaMergeOptions())
    async throws -> (analysis: PanoramaMergeAnalysis, report: PanoramaMergeReport) {
        var report = PanoramaMergeReport()
        let prep = PanoramaFramePrep(gpu: gpu)
        let photos = try report.time("Open photos") { try prep.photos(urls) }
        var inputs: [PanoramaFrameInput] = []
        var clipLevels: [Float] = []
        try report.time("Decode and reduce") {
            for photo in photos {
                try Task.checkCancellation()
                let measured = try prep.measure(photo)
                inputs.append(measured.input)
                clipLevels.append(measured.clipLevel)
            }
        }
        report.sampleMemory(gpu.device)
        try Task.checkCancellation()
        let solved = try report.time("Layout") {
            try PanoramaLayoutSolver(options: PanoramaLayoutOptions(projection: options.projection)).solve(inputs)
        }
        let layout = solved.layout, layoutReport = solved.report
        report.layout = layoutReport
        let size = outputSize(for: layout.canvas)

        let leftOut = Set(layoutReport.leftOut)
        let frames = layoutReport.frames.enumerated().map { index, frame in
            PanoramaMergeFrame(url: photos[index].url, captureTime: frame.captureTime,
                               exposureSeconds: frame.exposureTime, iso: frame.iso, aperture: frame.aperture,
                               gainStops: frame.gain.map { log2($0) } ?? 0, yawPitchRoll: frame.yawPitchRoll,
                               leftOut: leftOut.contains(index))
        }
        var warnings: [PanoramaMergeWarning] = []
        if !layoutReport.leftOut.isEmpty { warnings.append(.framesLeftOut(indices: layoutReport.leftOut.sorted())) }
        if size.needsDownsampling { warnings.append(.downsampled(outputSize: size)) }
        let uneven = layoutReport.exposureMeasurements
            .filter { $0.samples >= Self.exposureSampleFloor }
            .map { abs($0.remainingStops) }.max() ?? 0
        if uneven > Self.unevenExposureStops { warnings.append(.unevenExposure(stops: uneven)) }
        if layoutReport.rmsErrorPixels > Self.largeParallaxPixels {
            warnings.append(.largeParallax(rmsPixels: layoutReport.rmsErrorPixels))
        }

        let analysis = PanoramaMergeAnalysis(
            frames: frames, layout: layout, outputSize: size, widthDegrees: layoutReport.widthDegrees,
            heightDegrees: layoutReport.heightDegrees, warnings: warnings,
            estimatedOutputBytes: Self.estimatedOutputBytes(width: size.width, height: size.height))
        previewCache.store(PanoramaPreviewFrames(inputs: inputs, urls: photos.map(\.url), clipLevels: clipLevels))
        return (analysis, report)
    }

    /// The output size for a canvas: the GPU's limits, or the ones this
    /// merger was made with.
    func outputSize(for canvas: PanoramaCanvas) -> PanoramaOutputSize {
        guard let sizeLimits else {
            return PanoramaOutputSizer.size(fullWidth: canvas.width, fullHeight: canvas.height, device: gpu.device)
        }
        return PanoramaOutputSizer.size(fullWidth: canvas.width, fullHeight: canvas.height,
                                        maxTextureSide: sizeLimits.maxTextureSide,
                                        editPixelBudget: sizeLimits.editPixelBudget)
    }

    /// The DNG's size: every tile is full size, 3 half floats per pixel,
    /// plus room for the directories and the previews.
    static func estimatedOutputBytes(width: Int, height: Int) -> Int64 {
        let tile = LinearRawDNGWriter.tileSize(512, width: width, height: height)
        let tiles = ((width + tile - 1) / tile) * ((height + tile - 1) / tile)
        return Int64(tiles * tile * tile * 6) + 2_000_000
    }

    public func releasePreviews() async {
        previewCache.release()
    }

    // MARK: - Preview

    public func preview(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                        longEdge: Int) async throws -> CGImage {
        try await previewWithReport(analysis, options: options, longEdge: longEdge).image
    }

    /// `preview`, with its timings.
    public func previewWithReport(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions, longEdge: Int)
    async throws -> (image: CGImage, report: PanoramaMergeReport) {
        var report = PanoramaMergeReport()
        let urls = analysis.frames.map(\.url)
        let frames: PanoramaPreviewFrames
        if let kept = previewCache.frames(for: urls) {
            frames = kept
        } else {
            // The analysis's copies were released (or this analysis came
            // from elsewhere): make them again.
            frames = try report.time("Decode and reduce") { try previewFrames(urls) }
            previewCache.store(frames)
        }
        let clipLevel = Self.clipLevel(cameras: analysis.layout.cameras, levels: frames.clipLevels)
        // The crop the dialog shows, so the preview fills the space it is
        // given whether Auto Crop is on or off.
        let shown = options.autoCrop ? Self.cropRect(analysis.layout) : nil
        let canvas = analysis.layout.canvas
        let target = shown ?? CGRect(x: 0, y: 0, width: Double(canvas.width), height: Double(canvas.height))
        let scale = min(1, Double(longEdge) / max(target.width, target.height))
        let size = Self.previewOutputSize(canvas: canvas, scale: scale)
        let reference = try report.time("Read metadata") { try Self.referenceFile(analysis, urls: urls) }
        let image = try report.time("Stitch and render") {
            let stitcher = try PanoramaStitcher(
                layout: analysis.layout, outputSize: size, frames: frames,
                options: PanoramaBlendOptions(tileSize: Self.tileSize, clipLevel: Double(clipLevel),
                                              frameCacheBytes: frameCacheBytes,
                                              removeScratchWhenFinished: false), gpu: gpu)
            return try render(stitcher, size: size, crop: shown.map { Self.region($0, scale: scale, in: size) },
                              clipLevel: clipLevel, reference: reference.summary,
                              cameraToXYZ: reference.cameraToXYZMatrixRaw, longEdge: longEdge)
        }
        report.sampleMemory(gpu.device)
        return (image, report)
    }

    /// The 1/8 copies of `urls`, for a preview whose analysis no longer has
    /// them.
    private func previewFrames(_ urls: [URL]) throws -> PanoramaPreviewFrames {
        let prep = PanoramaFramePrep(gpu: gpu)
        let photos = try prep.photos(urls)
        // The analysis's layout points into its own capture order.
        guard photos.map(\.url) == urls else {
            throw PanoramaError.notAPanorama(reason: "the photos changed since they were analysed.")
        }
        var inputs: [PanoramaFrameInput] = [], clipLevels: [Float] = []
        for photo in photos {
            try Task.checkCancellation()
            let measured = try prep.measure(photo)
            inputs.append(measured.input)
            clipLevels.append(measured.clipLevel)
        }
        return PanoramaPreviewFrames(inputs: inputs, urls: photos.map(\.url), clipLevels: clipLevels)
    }

    // MARK: - Merging

    public func merge(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                      sources: [MergeRecipe.Source], to destination: URL,
                      prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                      progress: @escaping @Sendable (PanoramaMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
        try await mergeWithReport(analysis, options: options, sources: sources, to: destination,
                                  prepareSidecar: prepareSidecar, progress: progress).result
    }

    /// `merge`, with the timings, the memory and the brightest values.
    ///
    /// The stages, and the share of the progress bar each takes: preparing
    /// the photos 45%, the DNG's preview 10%, stitching and writing the
    /// rest.
    public func mergeWithReport(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                                sources: [MergeRecipe.Source], to destination: URL,
                                prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                                progress: @escaping @Sendable (PanoramaMergeProgress) -> Void)
    async throws -> (result: MergeDNGWriteResult, report: PanoramaMergeReport) {
        var report = PanoramaMergeReport()
        let cameras = analysis.layout.cameras
        guard !cameras.isEmpty else { throw PanoramaError.notAPanorama(reason: "no photos could be matched.") }
        guard sources.count == analysis.frames.count else {
            throw PanoramaError.cantWrite(fileName: destination.lastPathComponent,
                                          reason: "the merge was given \(sources.count) sources for "
                                              + "\(analysis.frames.count) photos")
        }
        // A doomed merge is refused before any of the slow work.
        try checkDiskSpace(needed: analysis.estimatedOutputBytes, at: destination)

        progress(PanoramaMergeProgress(fraction: 0, stage: "Preparing"))
        let prep = PanoramaFramePrep(gpu: gpu)
        let urls = analysis.frames.map(\.url)
        let photos = try report.time("Open photos") { try prep.photos(urls) }
        // The analysis's frames are in capture order and the cameras point
        // into them, so a photo whose file changed underneath (a different
        // capture time, say) would be prepared for the wrong place.
        guard photos.map(\.url) == urls else {
            throw PanoramaError.cantWrite(fileName: destination.lastPathComponent,
                                          reason: "the photos changed since they were analysed")
        }
        let multipliers = PanoramaFramePrep.sharedMultipliers(photos)
        let span = max(1, analysis.outputSize.decodeSpan)
        let store = try Self.mappingScratchErrors { try PanoramaFrameStore() }
        var finished = false
        defer { if !finished { store.removeScratch() } }

        // The brightest value the panorama can reach, and where it clips:
        // both are known once every frame has been prepared (see the note
        // at the top).
        var brightest: Float = 0
        var clipLevel: Float = 0
        var peakGPU = 0
        try report.time("Prepare frames") {
            for (position, camera) in cameras.enumerated() {
                try Task.checkCancellation()
                progress(PanoramaMergeProgress(fraction: 0.45 * Double(position) / Double(cameras.count),
                                               stage: "Preparing photo \(position + 1) of \(cameras.count)"))
                try autoreleasepool {
                    let prepared = try prep.prepared(photos[camera.frameIndex], span: span, multipliers: multipliers)
                    let maximum = try Self.mappingGPUErrors {
                        try ExposureNormalisation.maximum(of: prepared.texture, commandQueue: gpu.commandQueue)
                    }
                    guard maximum.isFinite else {
                        throw PanoramaError.unreadable(fileName: photos[camera.frameIndex].url.lastPathComponent,
                                                       reason: "its brightest value is \(maximum)")
                    }
                    let gain = Float(camera.exposureGain)
                    brightest = max(brightest, gain * maximum)
                    clipLevel = max(clipLevel, gain * prepared.clipLevel)
                    try Self.mappingScratchErrors {
                        try store.add(frameIndex: camera.frameIndex, texture: prepared.texture,
                                      sampleScale: 1 / Double(span), commandQueue: gpu.commandQueue)
                    }
                }
                peakGPU = Swift.max(peakGPU, gpu.device.currentAllocatedSize)
            }
        }
        report.peakGPUBytes = Swift.max(report.peakGPUBytes, peakGPU)
        report.scratchBytes = store.byteCount
        report.clipLevel = clipLevel
        let bound = max(Self.blendHeadroom * brightest, Float.leastNormalMagnitude)
        report.maximumBound = bound
        let normalisation = try ExposureNormalisation(maximum: bound)

        // The DNG's own preview: the real blend, at preview size, from the
        // frames just prepared.
        try Task.checkCancellation()
        progress(PanoramaMergeProgress(fraction: 0.45, stage: "Rendering the preview"))
        let reference = try Self.referenceFile(analysis, urls: urls)
        let previewImage = try report.time("Render preview") {
            let size = Self.previewOutputSize(
                canvas: analysis.layout.canvas,
                scale: min(analysis.outputSize.scale,
                           Double(Self.previewLongEdge) / Double(max(analysis.outputSize.width,
                                                                     analysis.outputSize.height))
                               * analysis.outputSize.scale))
            let stitcher = try PanoramaStitcher(
                layout: analysis.layout, outputSize: size, frames: store,
                options: PanoramaBlendOptions(tileSize: Self.tileSize, clipLevel: Double(clipLevel),
                                              frameCacheBytes: frameCacheBytes,
                                              removeScratchWhenFinished: false), gpu: gpu)
            return try render(stitcher, size: size, crop: nil, clipLevel: clipLevel, reference: reference.summary,
                              cameraToXYZ: reference.cameraToXYZMatrixRaw, longEdge: Self.previewLongEdge)
        }
        report.sampleMemory(gpu.device)

        // The file's own description of itself.
        var metadata: MergeDNGMetadata
        do {
            metadata = try MergeDNGMetadata(summary: reference.summary, cameraToXYZ: reference.cameraToXYZMatrixRaw,
                                            softwareVersion: Self.softwareVersion, baselineExposure: 0)
        } catch let error as MergeDNGError {
            throw PanoramaError.unreadable(fileName: reference.summary.cameraModel, reason: error.description)
        }
        // The stitch is already upright and already lens-corrected, so the
        // file must not be turned again or corrected again: no orientation,
        // and no lens for anything to match a profile against.
        metadata.orientation = 1
        metadata.lensMake = nil
        metadata.lensModel = nil
        metadata.lensSpecification = nil
        metadata.lens = nil
        let recipe = MergeRecipe(kind: .panorama, clipLevel: clipLevel, lensApplied: true,
                                 reference: cameras[0].frameIndex,
                                 options: Self.recipeOptions(analysis, options: options), sources: sources)
        let stored = recipe.normalised(by: normalisation)

        // The stitch, streamed into the writer a tile at a time.
        let beforeStitch = gpu.device.currentAllocatedSize
        let stitcher = try PanoramaStitcher(
            layout: analysis.layout, outputSize: analysis.outputSize, frames: store,
            options: PanoramaBlendOptions(tileSize: Self.tileSize, clipLevel: Double(clipLevel),
                                          frameCacheBytes: frameCacheBytes, removeScratchWhenFinished: true),
            gpu: gpu)
        var writer = LinearRawDNGWriter()
        writer.availableCapacity = availableCapacity
        let blendProgress: @Sendable (PanoramaBlendProgress) -> Void = { blend in
            progress(PanoramaMergeProgress(fraction: 0.55 + 0.45 * blend.fraction, stage: Self.stageText(blend)))
        }
        let seen = MaximumSeen()
        let pixels = try Self.mappingGPUErrors {
            try seen.watching(stitcher.pixelSource(progress: blendProgress, shouldCancel: { Task.isCancelled }))
        }
        // The exact size the file can reach, laid out as the writer will
        // lay it out, so a full disk refuses the merge before the app has
        // written a sidecar for a DNG that never arrives.
        let layout = try TIFFLayout(topLevel: [
            writer.makeFile(pixels, normalisation: normalisation, metadata: metadata, recipe: stored,
                            preview: previewImage),
        ])
        do {
            try writer.checkFreeSpace(needed: Int64(layout.maximumFileSize), at: destination)
        } catch MergeDNGError.insufficientDiskSpace(let needed, let available) {
            stitcher.finish()
            throw PanoramaError.notEnoughDiskSpace(neededBytes: needed, availableBytes: available)
        }

        try Task.checkCancellation()
        progress(PanoramaMergeProgress(fraction: 0.55, stage: "Saving"))
        do {
            try await report.time("Prepare sidecar") { try await prepareSidecar(stored) }
        } catch {
            stitcher.finish()
            throw error
        }
        try Task.checkCancellation()
        let result = try report.time("Stitch and write") {
            try Self.mappingWriteErrors(destination) {
                try writer.write(pixels, maximum: bound, metadata: metadata, recipe: recipe, preview: previewImage,
                                 to: destination)
            }
        }
        finished = true
        report.blend = stitcher.statistics
        // The stitch's peak is measured as a rise over what was allocated
        // when it started, so it counts from there.
        report.peakGPUBytes = Swift.max(report.peakGPUBytes, beforeStitch + stitcher.statistics.peakDeviceBytes)
        report.maximumSeen = seen.value
        progress(PanoramaMergeProgress(fraction: 1, stage: "Done"))
        return (result, report)
    }

    // MARK: - The recipe

    /// What the result records about how it was made. The keys are a
    /// contract with the app and the catalog: `projection`, `autoCrop` and
    /// the crop rectangle (in the output's own pixels and normalised),
    /// `scale` and `decodeSpan`, the photos left out, and the canvas the
    /// panorama was cut from.
    static func recipeOptions(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions) -> [String: JSONValue] {
        let size = analysis.outputSize, canvas = analysis.layout.canvas
        let crop = cropRect(analysis.layout)
        var recorded: [String: JSONValue] = [
            "projection": .string(canvas.projection.rawValue),
            "projectionAsked": .string(options.projection.rawValue),
            "autoCrop": .bool(options.autoCrop),
            "scale": .number(rounded(size.scale, places: 6)),
            "decodeSpan": .number(Double(size.decodeSpan)),
            "sizeLimit": .string(size.limit.rawValue),
            "canvasWidth": .number(Double(canvas.width)),
            "canvasHeight": .number(Double(canvas.height)),
            "outputWidth": .number(Double(size.width)),
            "outputHeight": .number(Double(size.height)),
            "photos": .number(Double(analysis.frames.count)),
            "stitched": .number(Double(analysis.layout.cameras.count)),
        ]
        let leftOut = analysis.frames.indices.filter { analysis.frames[$0].leftOut }
        if !leftOut.isEmpty { recorded["leftOut"] = .array(leftOut.map { .number(Double($0)) }) }
        if crop.width > 0, crop.height > 0 {
            let pixels = region(crop, scale: size.scale, in: size)
            recorded["cropPixels"] = .object([
                "x": .number(Double(pixels.x)), "y": .number(Double(pixels.y)),
                "width": .number(Double(pixels.width)), "height": .number(Double(pixels.height)),
            ])
            recorded["cropNormalised"] = .object([
                "x": .number(rounded(Double(pixels.x) / Double(size.width), places: 6)),
                "y": .number(rounded(Double(pixels.y) / Double(size.height), places: 6)),
                "width": .number(rounded(Double(pixels.width) / Double(size.width), places: 6)),
                "height": .number(rounded(Double(pixels.height) / Double(size.height), places: 6)),
            ])
        }
        return recorded
    }

    static func rounded(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    /// The layout's Auto Crop rectangle, or the empty rectangle when the
    /// solver found none.
    static func cropRect(_ layout: PanoramaLayout) -> CGRect {
        let crop = layout.autoCropRect
        guard crop.width >= 1, crop.height >= 1 else { return .zero }
        return crop
    }

    /// A canvas rectangle in the pixels of an output made at `scale`,
    /// clamped inside it.
    static func region(_ rect: CGRect, scale: Double, in size: PanoramaOutputSize) -> PixelRegion {
        let x = max(0, min(size.width - 1, Int((rect.minX * scale).rounded())))
        let y = max(0, min(size.height - 1, Int((rect.minY * scale).rounded())))
        let width = max(1, min(size.width - x, Int((rect.width * scale).rounded(.down))))
        let height = max(1, min(size.height - y, Int((rect.height * scale).rounded(.down))))
        return PixelRegion(x: x, y: y, width: width, height: height)
    }

    /// Where the panorama clips, in the frames' units: the highest level
    /// any photo that went into it clips at, once its gain is applied. The
    /// blend takes the same value (`PanoramaBlendOptions.clipLevel`), so
    /// the recipe and the blend agree about the highlights.
    static func clipLevel(cameras: [PanoramaCamera], levels: [Float]) -> Float {
        var clip: Float = 0
        for camera in cameras where levels.indices.contains(camera.frameIndex) {
            clip = max(clip, Float(camera.exposureGain) * levels[camera.frameIndex])
        }
        return clip > 0 ? clip : 1
    }

    static var softwareVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - Rendering

    /// The size a preview stitch is made at: the whole canvas, scaled.
    static func previewOutputSize(canvas: PanoramaCanvas, scale: Double) -> PanoramaOutputSize {
        let scale = min(1, max(scale, 1e-6))
        let width = max(1, Int((Double(canvas.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(canvas.height) * scale).rounded(.down)))
        return PanoramaOutputSize(fullWidth: canvas.width, fullHeight: canvas.height, scale: scale,
                                  width: width, height: height, limit: scale < 1 ? .memory : .none,
                                  decodeSpan: PanoramaOutputSizer.decodeSpan(scale: scale))
    }

    /// Stitches `stitcher` whole (it is small), keeps `crop` of it, and
    /// renders that the way Latent will show the DNG: opened as a linear
    /// panorama with the reference photo's colour and rendered through the
    /// pipeline with default settings. Unrotated, as DNG previews are.
    func render(_ stitcher: PanoramaStitcher, size: PanoramaOutputSize, crop: PixelRegion?, clipLevel: Float,
                reference: RawSummary, cameraToXYZ: [Float]?, longEdge: Int) throws -> CGImage {
        let kept = crop ?? PixelRegion(x: 0, y: 0, width: size.width, height: size.height)
        var rgba = [Float16](repeating: 0, count: kept.width * kept.height * 4)
        try Self.mappingGPUErrors {
            try stitcher.stitch(shouldCancel: { Task.isCancelled }) { tile in
                let region = tile.region
                let top = max(kept.y, region.y), bottom = min(kept.y + kept.height, region.y + region.height)
                let left = max(kept.x, region.x), right = min(kept.x + kept.width, region.x + region.width)
                guard top < bottom, left < right else { return }
                for y in top..<bottom {
                    for x in left..<right {
                        let source = ((y - region.y) * region.width + (x - region.x)) * 4
                        let target = ((y - kept.y) * kept.width + (x - kept.x)) * 4
                        rgba[target] = tile.pixels[source]
                        rgba[target + 1] = tile.pixels[source + 1]
                        rgba[target + 2] = tile.pixels[source + 2]
                        rgba[target + 3] = 1
                    }
                }
            }
        }
        let info = LinearMergeInfo(kind: MergeRecipe.Kind.panorama.rawValue, clipLevel: clipLevel,
                                   lensApplied: true, baselineShift: 0)
        guard let file = RawFile.linearSource(
            width: kept.width, height: kept.height, like: reference, cameraToXYZ: cameraToXYZ,
            baselineExposure: 0, mergeInfo: info,
            fill: { plane in
                guard let base = plane.baseAddress else { return }
                rgba.withUnsafeBufferPointer { source in
                    guard let from = source.baseAddress else { return }
                    UnsafeMutableRawPointer(base).copyMemory(from: from, byteCount: rgba.count * 2)
                }
            })
        else { throw PanoramaError.gpuUnavailable(reason: "no memory for the preview") }
        return try PanoramaFramePrep.gpuStep {
            let session = try ImageSession(file: file, gpu: gpu)
            let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
            let rendered = try RenderPipeline(gpu: gpu).render(session, scale: .full, parameters: parameters)
            return try Exporter(gpu: gpu).cgImage(from: rendered, colorSpace: .sRGB, maxLongEdge: longEdge)
        }
    }

    // MARK: - Helpers

    /// How much of the GPU prepared frames may hold during a stitch: a
    /// quarter of what the device recommends, between 256 MB and 1.5 GB. A
    /// smaller cache only means loading a frame again for the next row of
    /// tiles.
    var frameCacheBytes: Int {
        let quarter = Int(Double(gpu.device.recommendedMaxWorkingSetSize) * 0.25)
        return Swift.min(Swift.max(quarter, 256 << 20), 1_500 << 20)
    }

    /// The photo the DNG's metadata comes from: the first one that made it
    /// into the panorama.
    static func referenceFile(_ analysis: PanoramaMergeAnalysis, urls: [URL]) throws -> RawFile {
        guard let camera = analysis.layout.cameras.first, urls.indices.contains(camera.frameIndex) else {
            throw PanoramaError.notAPanorama(reason: "no photos could be matched.")
        }
        let url = urls[camera.frameIndex]
        do {
            return try RawFile(path: url.path, metadataOnly: true)
        } catch {
            throw PanoramaError.unreadable(fileName: url.lastPathComponent, reason: String(describing: error))
        }
    }

    static func stageText(_ blend: PanoramaBlendProgress) -> String {
        switch blend.stage {
        case .seams: return "Finding the seams (photo \(blend.completed + 1) of \(max(1, blend.total)))"
        case .tiles: return "Stitching tile \(min(blend.completed + 1, blend.total)) of \(blend.total)"
        }
    }

    func checkDiskSpace(needed: Int64, at destination: URL) throws {
        guard let available = availableCapacity(destination) else { return }
        let total = needed + Self.freeSpaceMargin
        guard available >= total else {
            throw PanoramaError.notEnoughDiskSpace(neededBytes: total, availableBytes: available)
        }
    }

    static func mappingScratchErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PanoramaBlendError {
            throw PanoramaError.cantWrite(fileName: "the panorama's scratch file", reason: error.description)
        }
    }

    /// Runs GPU and stitching work, turning its failures into the dialog's
    /// words.
    static func mappingGPUErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PanoramaBlendError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        } catch let error as MergeDNGError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        } catch let error as RenderError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        } catch let error as GPUContextError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        }
    }

    static func mappingWriteErrors<T>(_ destination: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MergeDNGError.insufficientDiskSpace(let needed, let available) {
            throw PanoramaError.notEnoughDiskSpace(neededBytes: needed, availableBytes: available)
        } catch let error as MergeDNGError {
            throw PanoramaError.cantWrite(fileName: destination.lastPathComponent, reason: error.description)
        } catch let error as PanoramaBlendError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        }
    }
}

/// The brightest colour value that actually went into the file, watched as
/// the tiles stream past. Only for the report and the tests: the writer is
/// given the bound worked out before the stitch.
final class MaximumSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var largest: Float = 0

    var value: Float { lock.withLock { largest } }

    /// `source` with every region it fills measured on the way through.
    func watching(_ source: LinearRawPixelSource) -> LinearRawPixelSource {
        LinearRawPixelSource(width: source.width, height: source.height) { [self] region, rgb in
            try source.fill(region, rgb)
            let filled = UnsafeMutableBufferPointer(rebasing: rgb[..<(region.pixelCount * 3)])
            let maximum = ExposureNormalisation.maximum(of: UnsafeBufferPointer(filled))
            lock.withLock { largest = max(largest, maximum) }
        }
    }
}

/// What a panorama analysis, preview or merge cost.
public struct PanoramaMergeReport: Sendable {
    public struct Stage: Sendable, Equatable {
        public let name: String
        public let seconds: Double
    }

    public var stages: [Stage] = []
    /// The geometry's own report (analysis only).
    public var layout: PanoramaLayoutReport?
    /// The largest `MTLDevice.currentAllocatedSize` seen, which counts every
    /// allocation in the process, not only the merge's.
    public var peakGPUBytes = 0
    /// Bytes of prepared frames written to scratch files.
    public var scratchBytes = 0
    /// The stitch's own figures.
    public var blend = PanoramaBlendStatistics()
    /// The upper bound the pixels were normalised by, and the brightest
    /// value that actually reached the file (0 when nothing was written).
    public var maximumBound: Float = 0
    public var maximumSeen: Float = 0
    /// Where the panorama clips, before normalisation.
    public var clipLevel: Float = 0

    public init() {}

    public var totalSeconds: Double { stages.reduce(0) { $0 + $1.seconds } }

    mutating func sampleMemory(_ device: MTLDevice) {
        peakGPUBytes = max(peakGPUBytes, device.currentAllocatedSize)
    }

    mutating func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer { stages.append(Stage(name: name, seconds: Self.seconds(clock.now - start))) }
        return try body()
    }

    mutating func time<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer { stages.append(Stage(name: name, seconds: Self.seconds(clock.now - start))) }
        return try await body()
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
