// The HDR merge: a bracket of raws in, lined up if they moved, one LinearRaw
// DNG out (docs/PhotoMerge.md section 3).

import CoreGraphics
import Foundation
import Metal
import PixelEngine
import RawCore
import ColorKit

/// Merges a bracket of Bayer raws into a float DNG.
///
/// **Analysis** (`analyse`) opens each frame once, checks the bracket can be
/// merged, and measures it on reduced frames: the exposure between
/// neighbouring frames (from the pixels, checked against EXIF), how much of
/// each frame is clipped, which frame the result should open like, and
/// (with Auto Align on) how the frames moved relative to each other.
///
/// **Auto Align** measures, in the analysis, how each frame moved relative
/// to its neighbour in exposure (`FrameAligner`, on half-size frames), and
/// the merge warps every frame onto the reference frame's pixel grid before
/// weighting it (`HDRMergeAlignment` has the rules for frames that can't be
/// lined up). The result keeps the reference frame's full size: along the
/// edges where another frame moved out of the picture, that frame simply
/// counts for nothing.
///
/// **Merging** (`merge`) opens each frame again, one at a time, demosaics it
/// at full resolution and adds it to a weighted sum on the GPU
/// (`HDRMergeAccumulator`), so memory stays the same however many frames
/// there are. Then it renders a preview the way Latent will show the
/// result, hands the app the recipe for the sidecar, and streams the DNG
/// to disk.
///
/// **Near clipping** a frame fades out over a wide band rather than pixel
/// by pixel (`HDRClipFeather`), so something that moved across a bright,
/// clipped sky during a long exposure can't punch dark holes in it.
///
/// **Deghosting**, when asked for, runs before merging: every frame is
/// opened once more at quarter size to find what moved (`findGhosts`), and
/// wherever something moved every frame's weight drops to zero except the
/// one frame that sees that place best, so moving things come from a single
/// exposure.
///
/// **One white balance for every frame.** RCD demosaics best with the
/// colours roughly balanced, and every frame must be demosaiced alike, so
/// all of them use the as-shot multipliers of the median-exposure frame
/// (the reference isn't known until the analysis ends, and the median frame
/// is the likeliest to be it). The multipliers are divided back out after
/// demosaicing, so the choice changes nothing in the stored colours; the
/// DNG's AsShotNeutral comes from the reference frame.
public final class HDRMerger: HDRMerging {
    let gpu: GPUContext
    let memoryPolicy: MemoryPolicy
    /// Free space on the volume holding a URL; replaceable for tests.
    let availableCapacity: @Sendable (URL) -> Int64?
    /// GPU memory a merge may plan to use; nil for the device's
    /// recommended working set. Replaceable for tests.
    let gpuMemoryBudget: Int?

    /// - Parameter keepsPreviewFrames: whether `analyse` keeps each frame
    ///   reduced in memory for `preview` (HDRMerger+Preview.swift), as the
    ///   dialog wants. Without it the first preview reads the raw files
    ///   again; a merge with no preview (the command line, HDR Merge Without
    ///   Dialog) needn't hold them.
    public convenience init(gpu: GPUContext, keepsPreviewFrames: Bool = false) {
        self.init(gpu: gpu, memoryPolicy: .current, keepsPreviewFrames: keepsPreviewFrames)
    }

    /// How frames fade out near their clipping; replaceable for tests.
    let clipFeather: HDRClipFeather
    /// See `init(gpu:keepsPreviewFrames:)`.
    let keepsPreviewFrames: Bool
    /// The reduced frames previews merge (`HDRPreviewCache`).
    let previewCache = HDRPreviewCache()

    init(gpu: GPUContext, memoryPolicy: MemoryPolicy,
         availableCapacity: @escaping @Sendable (URL) -> Int64? = LinearRawDNGWriter.volumeAvailableCapacity,
         gpuMemoryBudget: Int? = nil, clipFeather: HDRClipFeather = .standard, keepsPreviewFrames: Bool = false) {
        self.gpu = gpu
        self.memoryPolicy = memoryPolicy
        self.availableCapacity = availableCapacity
        self.gpuMemoryBudget = gpuMemoryBudget
        self.clipFeather = clipFeather
        self.keepsPreviewFrames = keepsPreviewFrames
    }

    /// Most frames a merge takes: 9, or 5 on a Mac with 8 GB or less,
    /// where a long merge competes with everything else for memory.
    var frameLimit: Int { memoryPolicy.isConstrained ? 5 : 9 }

    /// Long edge of the image the preview is rendered from; the DNG's JPEG
    /// preview is about this size.
    static let previewLongEdge = 1600
    /// Free space to leave on the volume beyond the file (as the writer does).
    static let freeSpaceMargin: Int64 = 64_000_000

    // MARK: - Analysis

    public func analyse(_ urls: [URL], options: HDRMergeOptions) async throws -> HDRMergeAnalysis {
        try await analyseWithReport(urls, options: options).analysis
    }

    /// `analyse`, with how long each stage took.
    public func analyseWithReport(_ urls: [URL], options: HDRMergeOptions = HDRMergeOptions())
    async throws -> (analysis: HDRMergeAnalysis, report: HDRMergeReport) {
        var report = HDRMergeReport()
        let bracket = try report.time("Check the photos") { try validate(urls) }
        let width = bracket[0].summary.width, height = bracket[0].summary.height
        let span = Self.analysisSpan(width: width, height: height)
        let alignmentSpan = Self.alignmentSpan(width: width, height: height)
        let aligner = FrameAligner()
        let previewFactor = Self.previewFactor(width: width, height: height)
        if keepsPreviewFrames { previewCache.prepare(for: urls) }

        // Only the previous frame's reduced images are kept: pairs are
        // neighbours, and a 24 MP frame's alignment pyramid alone is 40 MB.
        var previous: (frame: HDRAnalysisFrame, relativeEV: Double, alignment: AlignmentImage?)?
        var relativeEVs: [Double] = []
        var clipped: [Double] = [], crushed: [Double] = []
        var largestShift = 0.0
        var links: [AlignmentResult] = []
        var neighbourShifts: [Double?] = []
        for (index, member) in bracket.enumerated() {
            try Task.checkCancellation()
            let name = member.url.lastPathComponent
            let (frame, alignmentSource) = try report.time("Decode and reduce \(name)") {
                () throws -> (HDRAnalysisFrame, HDRMergeKernels.AnalysisImage?) in
                try autoreleasepool {
                    let file = try Self.open(member.url)
                    let levels = try Self.gpuStep { try Self.levels(for: file, gpu: gpu) }
                    let image = try Self.gpuStep {
                        try HDRMergeKernels.analysisImage(of: file, span: span, levels: levels, gpu: gpu)
                    }
                    // Alignment wants more detail than the exposure
                    // measurement: 2 x 2 blocks give each Bayer quad's
                    // colour without demosaicing.
                    let alignmentImage = try options.autoAlign ? Self.gpuStep {
                        try HDRMergeKernels.analysisImage(of: file, span: alignmentSpan, levels: levels, gpu: gpu)
                    } : nil
                    // Kept for the dialog's preview while the frame is open
                    // anyway, unless an earlier analysis of the same photos
                    // (with Auto Align the other way) kept it already.
                    if keepsPreviewFrames, previewCache.frame(for: member.url) == nil,
                       let reduced = HDRPreviewFrame.reduce(file, url: member.url, levels: levels,
                                                            factor: previewFactor) {
                        previewCache.store(reduced)
                    }
                    return (HDRAnalysisFrame(image, levels: levels), alignmentImage)
                }
            }
            report.sampleMemory(gpu.device)
            clipped.append(frame.clippedFraction)
            crushed.append(frame.crushedFraction)

            var relativeEV = 0.0
            // Neighbour to neighbour: very dark and very bright frames share
            // almost nothing usable, neighbours share the most.
            func measureExposure(brighter: HDRAnalysisFrame) -> Double {
                guard let last = previous else { return 0 }
                let exifStops = log2(bracket[index - 1].exposure / member.exposure)
                let pair = report.time("Measure exposure \(index - 1)-\(index)") {
                    HDRExposure.measuredStops(brighter: brighter, darker: frame)
                }
                return last.relativeEV - HDRExposure.pairStops(measured: pair.stops, samples: pair.samples,
                                                               exif: exifStops).stops
            }
            if let last = previous { relativeEV = measureExposure(brighter: last.frame) }
            // Phase correlation's shift between this frame and the previous
            // one, in full-resolution pixels; nil when it can't judge.
            func neighbourShift() -> Double? {
                guard let last = previous else { return nil }
                let shift = report.time("Check alignment \(index - 1)-\(index)") { () -> HDRAlignmentCheck.Shift? in
                    let (a, b) = HDRAlignmentCheck.matchedLogLuminance(brighter: last.frame, brighterEV: last.relativeEV,
                                                                       darker: frame, darkerEV: relativeEV)
                    return HDRAlignmentCheck.shift(a, b, width: frame.width, height: frame.height)
                }
                guard let shift, shift.peak >= HDRAlignmentCheck.minimumPeak else { return nil }
                return shift.length * Double(span)
            }
            var alignment: AlignmentImage?
            if let alignmentSource {
                // The frame's alignment image needs its exposure, known only now.
                let image = report.time("Prepare \(name) for alignment") {
                    AlignmentImage(analysis: alignmentSource, fullWidth: width, fullHeight: height,
                                   exposure: AlignmentExposure(gain: pow(2, relativeEV),
                                                               channelClip: frame.channelClip))
                }
                if let last = previous?.alignment {
                    let link = report.time("Align \(index - 1) to \(index)") {
                        aligner.align(moving: last, reference: image, model: .hdr)
                    }
                    links.append(link)
                    // Phase correlation is asked only about links the aligner
                    // rejected: it takes several times longer than aligning.
                    neighbourShifts.append(link.accepted ? nil : neighbourShift())
                    // The exposure measured again with the previous frame
                    // lined up: compared block by block while several pixels
                    // apart, edges slip into the "flat" blocks and bias the
                    // ratio (0.04 stops for a 6 px shift on the synthetic
                    // bracket), which would show as faint steps where the
                    // merge hands over between frames. This frame's
                    // alignment image keeps the first measurement, a few
                    // hundredths of a stop out, which alignment can't notice.
                    if link.accepted, link.maxCornerShift >= Self.remeasureShiftPixels, let last = previous {
                        relativeEV = measureExposure(brighter: last.frame.moved(by: link.estimatedHomography))
                    }
                }
                alignment = image
            } else if let shift = neighbourShift() {
                largestShift = max(largestShift, shift)
            }
            previous = (frame, relativeEV, alignment)
            relativeEVs.append(relativeEV)
        }

        // EXIF put the frames in order; should the pixels disagree about
        // which is brighter (frames within a fraction of a stop, with wrong
        // EXIF), their order wins, so the analysis stays brightest first.
        let order = bracket.indices.sorted { i, j in
            relativeEVs[i] != relativeEVs[j] ? relativeEVs[i] > relativeEVs[j] : i < j
        }
        let brightest = order[0]
        let referenceIndex = HDRExposure.referenceIndex(clipped: order.map { clipped[$0] },
                                                        crushed: order.map { crushed[$0] })
        // The links follow the order the frames were read in; the chain
        // records where each of those frames ended up.
        let alignment = options.autoAlign
            ? HDRMergeAlignment(links: links, chainOrder: bracket.indices.map { i in order.firstIndex(of: i)! },
                                neighbourShiftPixels: neighbourShifts, width: width, height: height)
            : nil
        let plan = alignment?.plan(reference: referenceIndex)
        let frames = order.enumerated().map { index, i -> HDRMergeFrame in
            let s = bracket[i].summary
            var shift: Double?
            switch plan?.frames[index] {
            case .reference?: shift = 0
            case .aligned(let pixels)?: shift = pixels
            default: shift = nil
            }
            return HDRMergeFrame(url: bracket[i].url, exposureSeconds: s.shutter, iso: s.iso, aperture: s.aperture,
                                 relativeEV: relativeEVs[i] - relativeEVs[brightest],
                                 exifRelativeEV: log2(bracket[i].exposure / bracket[brightest].exposure),
                                 clippedFraction: clipped[i], alignmentShiftPixels: shift)
        }
        let range = -(frames.map(\.relativeEV).min() ?? 0)

        var warnings: [HDRMergeWarning] = []
        if range < HDRExposure.smallRangeStops { warnings.append(.smallExposureRange(stops: range)) }
        for (index, frame) in frames.enumerated()
        where abs(frame.relativeEV - frame.exifRelativeEV) > HDRExposure.warningDisagreementStops {
            warnings.append(.exposureMetadataDisagrees(frameIndex: index, exifRelativeEV: frame.exifRelativeEV,
                                                       measuredRelativeEV: frame.relativeEV))
        }
        if let plan {
            // Aligned frames need no warning; the dialog notes how far they moved.
            for (index, frame) in plan.frames.enumerated() {
                if frame == .unaligned { warnings.append(.frameCouldNotBeAligned(frameIndex: index, leftOut: false)) }
                if frame == .leftOut { warnings.append(.frameCouldNotBeAligned(frameIndex: index, leftOut: true)) }
            }
        } else if largestShift > Self.misalignmentPixels {
            warnings.append(.framesLookMisaligned(maximumShiftPixels: largestShift))
        }

        let analysis = HDRMergeAnalysis(
            frames: frames, referenceIndex: referenceIndex,
            width: width, height: height, exposureRangeStops: range, warnings: warnings,
            estimatedOutputBytes: Self.estimatedOutputBytes(width: width, height: height), alignment: alignment)
        return (analysis, report)
    }

    /// A neighbour that Auto Align moves by at least this many pixels has
    /// its exposure measured again, lined up. Below it the blocks the
    /// measurement compares (6 or more photosites wide) barely change.
    static let remeasureShiftPixels = 0.5

    /// With Auto Align off, shifts larger than this many full-resolution
    /// pixels get a warning.
    static let misalignmentPixels = HDRMergeAlignment.unalignedLimitPixels

    /// A photo of the bracket, as validation found it.
    struct BracketMember {
        let url: URL
        /// From a metadata-only open.
        let summary: RawSummary
        /// `HDRExposure.exifExposure`.
        let exposure: Double
    }

    /// Checks that `urls` make a mergeable bracket, from metadata alone,
    /// and returns them brightest first by EXIF.
    func validate(_ urls: [URL]) throws -> [BracketMember] {
        guard urls.count >= 2 else { throw HDRMergeError.tooFewFrames }
        guard urls.count <= frameLimit else { throw HDRMergeError.tooManyFrames(limit: frameLimit) }
        var members: [BracketMember] = []
        for url in urls {
            let file: RawFile
            do {
                file = try RawFile(path: url.path, metadataOnly: true)
            } catch {
                throw HDRMergeError.unreadable(fileName: url.lastPathComponent, reason: String(describing: error))
            }
            let s = file.summary
            guard case .bayer = s.cfaPattern else { throw HDRMergeError.unsupportedSource(fileName: url.lastPathComponent) }
            guard let exposure = HDRExposure.exifExposure(shutter: s.shutter, iso: s.iso, aperture: s.aperture) else {
                throw HDRMergeError.unreadable(fileName: url.lastPathComponent, reason: "its shutter speed isn't recorded")
            }
            members.append(BracketMember(url: url, summary: s, exposure: exposure))
        }
        let first = members[0].summary
        guard members.allSatisfy({ $0.summary.cameraMake == first.cameraMake && $0.summary.cameraModel == first.cameraModel })
        else { throw HDRMergeError.differentCameras }
        guard members.allSatisfy({ $0.summary.width == first.width && $0.summary.height == first.height })
        else { throw HDRMergeError.differentSizes }
        guard members.allSatisfy({ $0.summary.orientation == first.orientation })
        else { throw HDRMergeError.differentOrientations }
        let stops = members.map { log2($0.exposure) }
        guard let low = stops.min(), let high = stops.max(), high - low >= HDRExposure.sameExposureStops
        else { throw HDRMergeError.sameExposure }
        // Stable: equal exposures keep the order they were given in.
        return members.enumerated().sorted { a, b in
            a.element.exposure != b.element.exposure ? a.element.exposure > b.element.exposure : a.offset < b.offset
        }.map(\.element)
    }

    /// Photosites per side of an analysis block: even (whole Bayer quads)
    /// and enough to bring the long edge to about 1024 px, the size the
    /// alignment spike measured shifts at. A 24 MP frame gets 6, a 45 MP
    /// frame 10, anything up to 2048 px wide 2.
    static func analysisSpan(width: Int, height: Int) -> Int {
        2 * max(1, Int((Double(max(width, height)) / 2048).rounded(.up)))
    }

    /// Photosites per side of an alignment image's block: 2 (each Bayer
    /// quad) up to a long edge of 9,600 photosites (about 60 MP), which
    /// leaves the aligner's 3,200 px finest level plenty to reduce from;
    /// bigger sensors get 4 and so on, so the image read back stays under
    /// about 90 MB.
    static func alignmentSpan(width: Int, height: Int) -> Int {
        2 * max(1, Int((Double(max(width, height)) / 9600).rounded(.up)))
    }

    /// The DNG's size: every tile is full size, 3 half floats per pixel,
    /// plus room for the directories and the previews.
    static func estimatedOutputBytes(width: Int, height: Int) -> Int64 {
        let tile = LinearRawDNGWriter.tileSize(512, width: width, height: height)
        let tiles = ((width + tile - 1) / tile) * ((height + tile - 1) / tile)
        return Int64(tiles * tile * tile * 6) + 2_000_000
    }

    // MARK: - Merging

    public func merge(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, sources: [MergeRecipe.Source],
                      to destination: URL,
                      prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                      progress: @escaping @Sendable (HDRMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
        try await mergeWithReport(analysis, options: options, sources: sources, to: destination,
                                  prepareSidecar: prepareSidecar, progress: progress).result
    }

    /// `merge`, with how long each stage took and the peak GPU memory.
    public func mergeWithReport(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, sources: [MergeRecipe.Source],
                                to destination: URL,
                                prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                                progress: @escaping @Sendable (HDRMergeProgress) -> Void)
    async throws -> (result: MergeDNGWriteResult, report: HDRMergeReport) {
        var report = HDRMergeReport()
        let frames = analysis.frames
        guard frames.count >= 2 else { throw HDRMergeError.tooFewFrames }
        guard frames.count <= frameLimit else { throw HDRMergeError.tooManyFrames(limit: frameLimit) }
        guard sources.count == frames.count else {
            throw HDRMergeError.unreadable(fileName: destination.lastPathComponent,
                                           reason: "the merge was given \(sources.count) sources for \(frames.count) photos")
        }
        // An override outside the bracket is ignored rather than trusted.
        let reference = options.referenceIndex.flatMap { frames.indices.contains($0) ? $0 : nil } ?? analysis.referenceIndex
        // Auto Align needs the analysis's measurements: an analysis made
        // with it off merges the frames where they are.
        let alignment = options.autoAlign ? analysis.alignment?.plan(reference: reference) : nil

        // Everything that can refuse the merge outright, before any work.
        try checkDiskSpace(needed: analysis.estimatedOutputBytes, at: destination)
        let needed = HDRMergeAccumulator.estimatedPeakBytes(width: analysis.width, height: analysis.height,
                                                            aligned: alignment?.warps ?? false)
        let budget = gpuMemoryBudget ?? Int(clamping: gpu.device.recommendedMaxWorkingSetSize)
        guard needed <= budget else {
            let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
            throw HDRMergeError.gpuUnavailable(reason: "the merge needs \(format(needed)) of graphics memory "
                                                   + "and \(format(budget)) is available")
        }

        progress(HDRMergeProgress(fraction: 0, stage: "Preparing"))
        // With deghosting the first quarter of the progress bar finds the
        // movement; merging the frames takes the bar to 80% either way.
        var ghosts: GhostPass?
        var mergeProgress = (start: 0.0, share: 0.8)
        if let settings = options.deghost.settings {
            ghosts = try findGhosts(frames, reference: reference, width: analysis.width, height: analysis.height,
                                    alignment: alignment, settings: settings, feather: clipFeather,
                                    report: &report) { fraction, stage in
                progress(HDRMergeProgress(fraction: 0.25 * fraction, stage: stage))
            }
            mergeProgress = (0.25, 0.55)
        }
        let accumulated = try accumulate(frames, reference: reference, width: analysis.width,
                                         height: analysis.height, alignment: alignment, ghosts: ghosts,
                                         feather: clipFeather, report: &report) { fraction, stage in
            progress(HDRMergeProgress(fraction: mergeProgress.start + mergeProgress.share * fraction, stage: stage))
        }
        let merged = accumulated.merged

        try Task.checkCancellation()
        progress(HDRMergeProgress(fraction: 0.8, stage: "Rendering the preview"))
        let (maximum, recipe, stored, normalisation) = try storage(for: accumulated, reference: reference,
                                                                   options: options, alignment: alignment,
                                                                   sources: sources)
        let referenceFrame = accumulated.reference
        let preview = try report.time("Render preview") {
            try Self.gpuStep {
                try renderPreview(merged, normalisation: normalisation, recipe: stored, reference: referenceFrame.summary,
                                  cameraToXYZ: referenceFrame.cameraToXYZ,
                                  baselineExposure: frames[reference].relativeEV)
            }
        }
        report.sampleMemory(gpu.device)

        let metadata: MergeDNGMetadata
        do {
            metadata = try MergeDNGMetadata(summary: referenceFrame.summary, cameraToXYZ: referenceFrame.cameraToXYZ,
                                            softwareVersion: Self.softwareVersion,
                                            baselineExposure: frames[reference].relativeEV)
        } catch let error as MergeDNGError {
            throw HDRMergeError.unreadable(fileName: frames[reference].url.lastPathComponent, reason: error.description)
        }

        var writer = LinearRawDNGWriter()
        writer.availableCapacity = availableCapacity
        let pixels = try LinearRawPixelSource.texture(merged, commandQueue: gpu.commandQueue)
        // The exact size the file can reach, laid out as the writer will
        // lay it out, so a full disk refuses the merge before the app has
        // written a sidecar for a DNG that never arrives.
        let layout = try TIFFLayout(topLevel: [
            writer.makeFile(pixels, normalisation: normalisation, metadata: metadata, recipe: stored, preview: preview),
        ])
        try Self.mappingDiskErrors { try writer.checkFreeSpace(needed: Int64(layout.maximumFileSize), at: destination) }

        try Task.checkCancellation()
        progress(HDRMergeProgress(fraction: 0.85, stage: "Saving"))
        try await report.time("Prepare sidecar") { try await prepareSidecar(stored) }
        try Task.checkCancellation()
        let result = try report.time("Write DNG") {
            try Self.mappingDiskErrors {
                try writer.write(pixels, maximum: maximum, metadata: metadata, recipe: recipe, preview: preview,
                                 to: destination)
            }
        }
        progress(HDRMergeProgress(fraction: 1, stage: "Done"))
        return (result, report)
    }

    /// The recipe of a merged image and how its pixels are stored: the
    /// largest merged value, the recipe as written (`recipe`, in merged
    /// units) and as the DNG's pixels are read back (`stored`, normalised,
    /// with the reference frame's lens), and the normalisation between them.
    /// Shared by the merge and the preview, so both open the result alike.
    func storage(for accumulated: Accumulated, reference: Int, options: HDRMergeOptions,
                 alignment: HDRMergeAlignment.Plan?, sources: [MergeRecipe.Source])
    throws -> (maximum: Float, recipe: MergeRecipe, stored: MergeRecipe, normalisation: ExposureNormalisation) {
        let maximum = try ExposureNormalisation.maximum(of: accumulated.merged, commandQueue: gpu.commandQueue)
        // Where the result is clipped in every frame: the darkest merged
        // frame's clip level on the brightest frame's scale (0.98 x 2^range
        // when it saturates at its nominal white).
        let range = -accumulated.darkestRelativeEV
        let darkest = accumulated.darkestLevels
        let darkestSaturation = (darkest.clipRaw / Self.clipFraction - darkest.channelBlack.min()) * darkest.scale
        let recipe = MergeRecipe(kind: .hdr, clipLevel: Self.clipFraction * Float(pow(2, range)) * darkestSaturation,
                                 lensApplied: false, reference: reference,
                                 options: Self.recipeOptions(options, alignment: alignment), sources: sources)
        let normalisation = try ExposureNormalisation(maximum: maximum)
        let stored = recipe.normalised(by: normalisation).withLens(of: accumulated.reference.summary)
        return (maximum, recipe, stored, normalisation)
    }

    /// What `accumulate` hands back: the merged image and what the rest of
    /// the merge needs from the frames it has already let go of.
    struct Accumulated {
        let merged: MTLTexture
        let reference: (summary: RawSummary, cameraToXYZ: [Float]?)
        /// The darkest frame that went into the merge.
        let darkestLevels: HDRFrameLevels
        let darkestRelativeEV: Double
    }

    /// Adds every frame to the GPU sums, one at a time, and resolves them.
    /// Its own function so the accumulator and every per-frame texture are
    /// released when it returns, before the preview needs memory.
    ///
    /// Each frame goes through the same steps, in this order: decode, the
    /// accumulator's demosaic, the warp onto the reference frame (with Auto
    /// Align), the clip feathering and the ghost mask, then the weighted sum.
    ///
    /// - Parameters:
    ///   - alignment: what Auto Align decided, or nil with it off. Frames it
    ///     left out are skipped.
    ///   - ghosts: the deghosting pass's masks, or nil without deghosting.
    ///   - feather: the clip feathering (`clipFeather`, scaled down for a preview).
    ///   - progress: the share of this step done (0...1) and a stage name.
    func accumulate(_ frames: [HDRMergeFrame], reference: Int, width: Int, height: Int,
                    alignment: HDRMergeAlignment.Plan?, ghosts: GhostPass?, feather: HDRClipFeather,
                    report: inout HDRMergeReport, progress: (Double, String) -> Void) throws -> Accumulated {
        let multipliers = try sharedMultipliers(frames)
        let accumulator = try Self.gpuStep { try HDRMergeAccumulator(gpu: gpu, width: width, height: height) }
        let merged = frames.indices.filter { alignment?.includes($0) ?? true }
        let warps = alignment?.warps ?? false
        var referenceFrame: (summary: RawSummary, cameraToXYZ: [Float]?)?
        var darkestLevels: HDRFrameLevels?
        for (index, frame) in frames.enumerated() where merged.contains(index) {
            try Task.checkCancellation()
            progress(Double(index) / Double(frames.count), "Merging photo \(index + 1) of \(frames.count)")
            let name = frame.url.lastPathComponent
            let isDarkest = index == merged.last
            let homography = alignment?.homographies[index]
            // The pool drains Metal's autoreleased objects (command buffers,
            // the sensor buffer's wrapper) before the next frame opens.
            try autoreleasepool {
                let file = try report.time("Decode \(name)") { try Self.open(frame.url) }
                guard case .bayer = file.summary.cfaPattern else { throw HDRMergeError.unsupportedSource(fileName: name) }
                guard file.summary.width == width, file.summary.height == height else { throw HDRMergeError.differentSizes }
                let levels = try ghosts?.levels[index] ?? Self.gpuStep { try Self.levels(for: file, gpu: gpu) }
                try report.time("Demosaic and add \(name)") {
                    try Self.gpuStep {
                        // The darkest frame keeps a weight floor, so pixels
                        // clipped in every frame come from it, and no
                        // feathering: no darker frame could take over from it.
                        // When frames are warped, the reference keeps a
                        // far smaller floor still: along an edge that every
                        // other frame moved away from, it is all there is.
                        try accumulator.add(file, levels: levels, multipliers: multipliers,
                                            relativeEV: frame.relativeEV,
                                            weightFloor: isDarkest ? 1e-4 : (warps && index == reference ? 1e-8 : 0),
                                            feather: isDarkest ? nil : feather,
                                            ghostMask: ghosts?.masks[index],
                                            movingToReference: homography)
                    }
                }
                report.sampleMemory(gpu.device)
                if index == reference { referenceFrame = (file.summary, file.cameraToXYZMatrixRaw) }
                if isDarkest { darkestLevels = levels }
            }
        }
        accumulator.releaseScratch()
        let result = try report.time("Resolve") { try Self.gpuStep { try accumulator.resolve() } }
        report.sampleMemory(gpu.device)
        guard let referenceFrame, let darkestLevels, let darkest = merged.last else { throw HDRMergeError.tooFewFrames }
        return Accumulated(merged: result, reference: referenceFrame, darkestLevels: darkestLevels,
                           darkestRelativeEV: frames[darkest].relativeEV)
    }

    /// The as-shot white balance of the median-exposure frame (see the
    /// type's notes), normalised to green, from a metadata-only open.
    private func sharedMultipliers(_ frames: [HDRMergeFrame]) throws -> SIMD3<Float> {
        let median = frames[(frames.count - 1) / 2].url
        let summary: RawSummary
        do {
            // A preview's reduced frame carries the same white balance.
            summary = try HDRPreviewFrameSet.current?.file(for: median)?.summary
                ?? RawFile(path: median.path, metadataOnly: true).summary
        } catch {
            throw HDRMergeError.unreadable(fileName: median.lastPathComponent, reason: String(describing: error))
        }
        let m = ColorKit.normalizedWhiteBalance(summary.cameraMultipliers)
        let rgb = SIMD3<Float>(m.x, m.y, m.z)
        // A file without a usable white balance demosaics unbalanced rather
        // than dividing by zero later.
        guard rgb.x.isFinite, rgb.z.isFinite, rgb.x > 0, rgb.z > 0 else { return SIMD3(repeating: 1) }
        return rgb
    }

    /// The merge's options as the recipe records them.
    ///
    /// Deghosting, Auto Align and the version of the clip feathering are
    /// always recorded (all change the pixels); the reference frame only
    /// when overridden. With Auto Align, `alignmentShifts` holds how far
    /// each frame was moved (the most any corner moved, in pixels, to a
    /// hundredth; null for a frame that couldn't be lined up) and `leftOut`
    /// the frames left out of the merge, if any.
    ///
    /// - Parameter alignment: what Auto Align decided; nil when it was off
    ///   (or the analysis had no measurements), recorded as `autoAlign: false`.
    static func recipeOptions(_ options: HDRMergeOptions, alignment: HDRMergeAlignment.Plan? = nil) -> [String: JSONValue] {
        var recorded: [String: JSONValue] = [
            "deghost": .string(options.deghost.rawValue),
            "clipFeather": .number(Double(HDRClipFeather.version)),
            "autoAlign": .bool(alignment != nil),
        ]
        if let index = options.referenceIndex { recorded["referenceIndex"] = .number(Double(index)) }
        if let alignment {
            recorded["alignmentShifts"] = .array(alignment.frames.map { frame in
                switch frame {
                case .reference: .number(0)
                case .aligned(let shift): .number((shift * 100).rounded() / 100)
                case .unaligned, .leftOut: .null
                }
            })
            let leftOut = alignment.frames.indices.filter { !alignment.includes($0) }
            if !leftOut.isEmpty { recorded["leftOut"] = .array(leftOut.map { .number(Double($0)) }) }
        }
        return recorded
    }

    static var softwareVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - Frames

    /// A full open (sensor data included), with its failure in the dialog's words.
    ///
    /// During a preview (`HDRPreviewFrameSet.current`), the frame's reduced
    /// copy instead.
    static func open(_ url: URL) throws -> RawFile {
        if let previewing = HDRPreviewFrameSet.current {
            guard let file = previewing.file(for: url) else {
                throw HDRMergeError.unreadable(fileName: url.lastPathComponent, reason: "it isn't part of the preview")
            }
            return file
        }
        do {
            return try RawFile(path: url.path)
        } catch {
            throw HDRMergeError.unreadable(fileName: url.lastPathComponent, reason: String(describing: error))
        }
    }

    /// How to read `file`'s photosites: its black levels and white, and the
    /// raw value from which a photosite counts as clipped, 98% of where the
    /// sensor saturates.
    ///
    /// **Where it saturates.** Some cameras saturate below their nominal
    /// white, so the plan is `min(white, dataMaximum)`. But a frame with
    /// nothing clipped (the darkest of a bracket, often) has a data maximum
    /// that is just its brightest pixel, and treating that as saturation
    /// would throw away the best highlights the bracket has. So the data
    /// maximum only counts when the frame has a plateau there: at least one
    /// photosite in 10,000 within 0.05% of it, which real clipping gives
    /// and the brightest few photosites of a noisy highlight don't.
    /// Otherwise the nominal white stands.
    ///
    /// **During a preview** a reduced frame's levels are those measured on
    /// the full frame: averaging photosites smooths the plateau away.
    static func levels(for file: RawFile, gpu: GPUContext) throws -> HDRFrameLevels {
        if let previewing = HDRPreviewFrameSet.current, let levels = previewing.levels(for: file) { return levels }
        let s = file.summary
        let black = s.channelBlackLevels
        var saturation = s.whiteLevel
        let observed = s.dataMaximum
        if observed > black.max(), observed < s.whiteLevel {
            let near = observed - max(2, 0.0005 * (observed - black.min()))
            let probe = HDRFrameLevels(channelBlack: black, white: s.whiteLevel, clipRaw: near)
            let coarse = try HDRMergeKernels.analysisImage(of: file, span: 16, levels: probe, gpu: gpu)
            let blocks = coarse.width * coarse.height
            var share: Float = 0
            for i in 0..<blocks { share += coarse.pixels[i * 4 + 3] }
            if blocks > 0, share / Float(blocks) >= 1e-4 { saturation = observed }
        }
        return HDRFrameLevels(channelBlack: black, white: s.whiteLevel, clipRaw: clipFraction * saturation)
    }

    /// A photosite at or above this share of the sensor's saturation counts
    /// as clipped: a little below it, because a photosite near saturation
    /// may already have stopped responding in proportion to the light.
    static let clipFraction: Float = 0.98

    // MARK: - Preview

    /// The merge rendered as Latent will show the DNG: its pixels reduced to
    /// about `longEdge` (at least that, when the image is that big), divided
    /// as the file stores them, opened as a linear source with the reference
    /// frame's metadata and the file's BaselineExposure and merge info, and
    /// rendered through the pipeline with default settings. Unrotated, as
    /// the DNG stores its previews.
    ///
    /// - Parameters:
    ///   - rotation: turns the picture (the dialog's preview is shown upright).
    ///   - fitting: resizes the picture so its long edge is at most
    ///     `longEdge`, rather than anything up to twice that.
    func renderPreview(_ merged: MTLTexture, normalisation: ExposureNormalisation, recipe: MergeRecipe,
                       reference: RawSummary, cameraToXYZ: [Float]?, baselineExposure: Double,
                       longEdge: Int = HDRMerger.previewLongEdge, rotation: ImageRotation = .none,
                       fitting: Bool = false) throws -> CGImage {
        let span = max(1, max(merged.width, merged.height) / max(1, longEdge))
        let small = try HDRMergeKernels.downsample(merged, span: span, scale: normalisation.scale, gpu: gpu)
        let info = LinearMergeInfo(kind: recipe.kind.rawValue, clipLevel: recipe.clipLevel,
                                   lensApplied: recipe.lensApplied, baselineShift: recipe.baselineShift)
        let (w, h) = (small.width, small.height)
        guard let file = RawFile.linearSource(
            width: w, height: h, like: reference, cameraToXYZ: cameraToXYZ,
            baselineExposure: Float(normalisation.storedBaselineExposure(baselineExposure)), mergeInfo: info,
            fill: { plane in
                guard let base = plane.baseAddress else { return }
                small.getBytes(base, bytesPerRow: w * LinearPlane.bytesPerPixel,
                               from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            })
        else { throw RenderError.gpuBufferAllocationFailed }
        let session = try ImageSession(file: file, gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        let rendered = try RenderPipeline(gpu: gpu).render(session, scale: .full, parameters: parameters)
        return try Exporter(gpu: gpu).cgImage(from: rendered, colorSpace: .sRGB, rotation: rotation,
                                              maxLongEdge: fitting ? longEdge : nil)
    }

    // MARK: - Errors

    /// Runs GPU work, turning the GPU's own failures into the dialog's words.
    static func gpuStep<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as RenderError {
            throw HDRMergeError.gpuUnavailable(reason: error.description)
        } catch let error as GPUContextError {
            throw HDRMergeError.gpuUnavailable(reason: error.description)
        } catch let error as HDRMergeKernelError {
            throw HDRMergeError.gpuUnavailable(reason: error.description)
        }
    }

    static func mappingDiskErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MergeDNGError.insufficientDiskSpace(let needed, let available) {
            throw HDRMergeError.notEnoughDiskSpace(neededBytes: needed, availableBytes: available)
        }
    }

    func checkDiskSpace(needed: Int64, at destination: URL) throws {
        guard let available = availableCapacity(destination) else { return }
        let total = needed + Self.freeSpaceMargin
        guard available >= total else {
            throw HDRMergeError.notEnoughDiskSpace(neededBytes: total, availableBytes: available)
        }
    }
}
