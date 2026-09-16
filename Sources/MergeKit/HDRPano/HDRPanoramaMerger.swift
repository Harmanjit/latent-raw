// The HDR panorama: brackets in, one LinearRaw DNG out
// (docs/PhotoMerge.md section 8, phase 9). **Experimental.**
//
// This composes what already exists rather than adding pixel code of its
// own: it groups the photos into positions, has the HDR engine merge each
// position, and hands the results to the panorama engine, which already
// stitches linear DNGs (`PanoramaFramePrep` accepts `.linearRGB` sources —
// that is how Lightroom's "photos you merged earlier" case works too).

import Foundation
import PixelEngine
import RawCore

/// Merges each position of a bracketed sweep to HDR, then stitches the
/// results into a panorama.
///
/// **Grouping** (`HDRPanoramaGrouper`) works out the positions from the
/// repeating exposure pattern, the gaps between shots, and — only when
/// those say nothing — how much consecutive photos overlap.
///
/// **Intermediate HDRs are written as temporary DNGs**, one per position,
/// into a scratch folder that is removed however the merge ends. The
/// alternative — keeping each position's merged frame in the panorama's
/// prep as linear pixels — would save the disk but needs new code in two
/// engines and holds a full-size float frame per position while the layout
/// is solved. Temporary DNGs cost nothing to write (the HDR merge writes
/// one anyway), keep the peak memory at exactly one HDR merge, and reuse
/// the path the panorama engine is already tested on. The cost is disk:
/// about `width x height x 6` bytes per position (a 24 MP position is
/// 145 MB, five of them 725 MB), checked before anything is merged and
/// reported to the dialog as `HDRPanoramaWarning.scratchSpace`.
///
/// **The layout is solved twice**, and only the second one matters. The
/// analysis solves it on one photo per position, so the dialog can say
/// where the sweep goes and how big it will be without merging anything;
/// the merge solves it again on the real intermediates, because those are
/// what is stitched. A position's HDR has the same size, lens, orientation
/// and capture time as the frame the analysis used, so the two agree.
///
/// **The recipe** is `kind: .hdrPanorama`, listing every photo the user
/// selected — not the intermediates — with both stages' options
/// (`PanoramaMergeOptions.RecipeOverride`).
public final class HDRPanoramaMerger: HDRPanoramaMerging {
    let hdr: any HDRMerging
    let panorama: any PanoramaMerging
    /// Used only to compare consecutive photos when the metadata can't tell
    /// the positions apart (`HDRPanoramaGrouper`, evidence 3). nil for an
    /// engine built from other engines (the app's tests), which then fails
    /// instead of measuring.
    let gpu: GPUContext?
    /// Where the intermediate HDRs go; a folder of this run's own is made
    /// inside it and removed at the end.
    let scratchRoot: URL
    /// Free space on the volume holding a URL; replaceable for tests.
    let availableCapacity: @Sendable (URL) -> Int64?

    /// The real engines, both using `gpu`. The HDR engine keeps nothing for
    /// previews: the HDR panorama's dialog has none (see the type note).
    public convenience init(gpu: GPUContext) {
        self.init(hdr: HDRMerger(gpu: gpu, keepsPreviewFrames: false), panorama: PanoramaMerger(gpu: gpu),
                  scratchRoot: FileManager.default.temporaryDirectory, gpu: gpu)
    }

    /// Engines of the caller's own (the app's tests hand it fakes).
    public convenience init(hdr: any HDRMerging, panorama: any PanoramaMerging) {
        self.init(hdr: hdr, panorama: panorama, scratchRoot: FileManager.default.temporaryDirectory)
    }

    /// See `init(hdr:panorama:)`; tests give it a scratch folder and a
    /// volume of their own.
    init(hdr: any HDRMerging, panorama: any PanoramaMerging, scratchRoot: URL,
         availableCapacity: @escaping @Sendable (URL) -> Int64? = LinearRawDNGWriter.volumeAvailableCapacity,
         gpu: GPUContext? = nil) {
        self.hdr = hdr
        self.panorama = panorama
        self.scratchRoot = scratchRoot
        self.availableCapacity = availableCapacity
        self.gpu = gpu
    }

    /// Free space to leave beyond what the merge needs.
    static let freeSpaceMargin: Int64 = 64_000_000
    /// The share of the progress bar the HDR merges take; the stitch has
    /// the rest. Merging a position reads every frame of it and writes a
    /// full-size DNG, so the two stages are of the same order.
    static let hdrShare = 0.6

    // MARK: - Analysis

    public func analyse(_ urls: [URL], options: HDRPanoramaOptions) async throws -> HDRPanoramaAnalysis {
        guard urls.count >= 2 else { throw HDRPanoramaError.tooFewPhotos }
        let photos = try Self.photos(urls)
        try Task.checkCancellation()
        // The pixels are only read when the metadata can't tell the
        // positions apart, and then only for the pairs asked about.
        let overlap = OverlapMeasure(photos: photos, gpu: gpu)
        let measure: ((Int) throws -> Double)? = gpu == nil ? nil : { try overlap.similarity($0) }
        let grouping = try HDRPanoramaGrouper.group(photos, overlap: measure)
        let positions = grouping.positions
        // One photo per position lays the sweep out; see the type note.
        let layoutURLs = positions.map { photos[$0.reference].url }
        let panoramaAnalysis = try await panorama.analyse(layoutURLs, options: options.panorama)

        var warnings: [HDRPanoramaWarning] = []
        if grouping.isUneven { warnings.append(.unevenBrackets(counts: positions.map(\.frames.count))) }
        for (index, position) in positions.enumerated() where position.frames.count == 1 {
            let name = photos[position.reference].url.lastPathComponent
            warnings.append(position.alreadyMerged ? .alreadyMergedPosition(position: index, fileName: name)
                : .singlePhotoPosition(position: index, fileName: name))
        }
        switch grouping.evidence {
        case .exposurePatternAndTiming, .exposurePattern, .alreadyMerged: break
        case .timeGaps, .overlap, .mixed: warnings.append(.groupingIsAGuess(evidence: grouping.evidence))
        }
        let scratch = Self.scratchBytes(photos: photos, grouping: grouping)
        if scratch > 0 { warnings.append(.scratchSpace(bytes: scratch)) }
        warnings += panoramaAnalysis.warnings.map { .panorama($0) }

        return HDRPanoramaAnalysis(photos: photos, grouping: grouping, panorama: panoramaAnalysis,
                                   warnings: warnings,
                                   estimatedOutputBytes: panoramaAnalysis.estimatedOutputBytes,
                                   estimatedScratchBytes: scratch)
    }

    public func releasePreviews() async {
        await panorama.releasePreviews()
        hdr.releasePreviews()
    }

    /// The photos at `urls`, read for their metadata and sorted into
    /// capture order — the same order the panorama engine puts them in, so
    /// the positions and the stitch agree.
    ///
    /// - Throws: `HDRPanoramaError` when a photo is unreadable, isn't a
    ///   Bayer raw or a linear DNG, or doesn't match the first photo's
    ///   camera and focal length.
    static func photos(_ urls: [URL]) throws -> [HDRPanoramaPhoto] {
        var summaries: [(url: URL, summary: RawSummary)] = []
        for url in urls {
            let summary: RawSummary
            do {
                summary = try RawFile(path: url.path, metadataOnly: true).summary
            } catch {
                throw HDRPanoramaError.unreadable(fileName: url.lastPathComponent, reason: String(describing: error))
            }
            switch summary.cfaPattern {
            case .bayer, .linearRGB: break
            default: throw HDRPanoramaError.unsupportedSource(fileName: url.lastPathComponent)
            }
            summaries.append((url, summary))
        }
        // The same check the panorama's own prep makes, said in this
        // dialog's words and before anything slow happens.
        let first = summaries[0].summary
        for photo in summaries.dropFirst() {
            let s = photo.summary
            let sameFocal = abs(s.focalLength - first.focalLength) <= max(0.01 * first.focalLength, 0.05)
            guard s.cameraMake == first.cameraMake, s.cameraModel == first.cameraModel,
                  s.rawWidth == first.rawWidth, s.rawHeight == first.rawHeight, sameFocal else {
                throw HDRPanoramaError.differentCameras(fileName: photo.url.lastPathComponent)
            }
        }
        return summaries.sorted {
            $0.summary.captureTime != $1.summary.captureTime ? $0.summary.captureTime < $1.summary.captureTime
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }.map { photo in
            HDRPanoramaPhoto(url: photo.url, captureTime: photo.summary.captureTime,
                             exposureSeconds: photo.summary.shutter, iso: photo.summary.iso,
                             aperture: photo.summary.aperture,
                             alreadyMerged: photo.summary.cfaPattern == .linearRGB)
        }
    }

    /// Room the intermediate HDRs need: one full-size linear DNG (3 half
    /// floats a pixel, plus the previews and directories) for every
    /// position that is actually merged.
    static func scratchBytes(grouping: HDRPanoramaGrouping, width: Int, height: Int) -> Int64 {
        let merged = grouping.positions.filter(\.needsMerging).count
        guard merged > 0 else { return 0 }
        return Int64(merged) * (Int64(width) * Int64(height) * 6 + 2_000_000)
    }

    /// `scratchBytes` when the photos' size isn't to hand: the panorama's
    /// own estimate of one frame, which the analysis knows.
    static func scratchBytes(photos: [HDRPanoramaPhoto], grouping: HDRPanoramaGrouping) -> Int64 {
        guard let first = photos.first, let size = try? frameSize(first.url) else { return 0 }
        return scratchBytes(grouping: grouping, width: size.width, height: size.height)
    }

    static func frameSize(_ url: URL) throws -> (width: Int, height: Int) {
        let summary = try RawFile(path: url.path, metadataOnly: true).summary
        return (summary.rawWidth, summary.rawHeight)
    }

    // MARK: - Merging

    public func merge(_ analysis: HDRPanoramaAnalysis, options: HDRPanoramaOptions,
                      sources: [MergeRecipe.Source], to destination: URL,
                      prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                      progress: @escaping @Sendable (HDRPanoramaProgress) -> Void) async throws -> MergeDNGWriteResult {
        guard sources.count == analysis.photos.count else {
            throw HDRPanoramaError.positionFailed(
                position: 0, reason: "the merge was given \(sources.count) sources for "
                    + "\(analysis.photos.count) photos")
        }
        let needed = analysis.estimatedScratchBytes + analysis.estimatedOutputBytes + Self.freeSpaceMargin
        if let available = availableCapacity(destination.deletingLastPathComponent()), available < needed {
            throw HDRPanoramaError.notEnoughDiskSpace(neededBytes: needed, availableBytes: available)
        }

        let scratch = scratchRoot.appendingPathComponent("Latent-HDRPano-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Stage 1: one HDR merge per position, into the scratch folder.
        let positions = analysis.grouping.positions
        var frameURLs: [URL] = []
        for (index, position) in positions.enumerated() {
            try Task.checkCancellation()
            let share = Self.hdrShare * Double(index) / Double(positions.count)
            guard position.needsMerging else {
                // A single photo (already merged, or a stray with no
                // bracket): stitched as it is.
                progress(HDRPanoramaProgress(fraction: share,
                                             stage: "Position \(index + 1) of \(positions.count)"))
                frameURLs.append(analysis.photos[position.reference].url)
                continue
            }
            progress(HDRPanoramaProgress(fraction: share,
                                         stage: "Merging bracket \(index + 1) of \(positions.count)"))
            let urls = position.frames.map { analysis.photos[$0].url }
            let merged = scratch.appendingPathComponent(String(format: "position-%03d-HDR.dng", index))
            let step = Self.hdrShare / Double(positions.count)
            do {
                var hdrOptions = options.hdr
                // Each position picks its own reference; one index can't
                // mean anything across several brackets.
                hdrOptions.referenceIndex = nil
                let positionAnalysis = try await hdr.analyse(urls, options: hdrOptions)
                _ = try await hdr.merge(
                    positionAnalysis, options: hdrOptions,
                    sources: Self.scratchSources(urls), to: merged,
                    prepareSidecar: { _ in },
                    progress: { inner in
                        progress(HDRPanoramaProgress(
                            fraction: share + step * inner.fraction,
                            stage: "Merging bracket \(index + 1) of \(positions.count): \(inner.stage)"))
                    })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw HDRPanoramaError.positionFailed(position: index,
                                                      reason: PhotoMergeText.describe(error))
            }
            frameURLs.append(merged)
        }

        // Stage 2: lay the real intermediates out and stitch them.
        try Task.checkCancellation()
        progress(HDRPanoramaProgress(fraction: Self.hdrShare, stage: "Laying out the panorama"))
        let stitchAnalysis = try await panorama.analyse(frameURLs, options: options.panorama)
        try Task.checkCancellation()

        var panoramaOptions = options.panorama
        panoramaOptions.recipeOverride = Self.recipeOverride(
            analysis, options: options, sources: sources, stitch: stitchAnalysis, frameURLs: frameURLs)
        let stitchSources = Self.scratchSources(stitchAnalysis.frames.map(\.url))
        let tail = 1 - Self.hdrShare
        return try await panorama.merge(
            stitchAnalysis, options: panoramaOptions, sources: stitchSources, to: destination,
            prepareSidecar: prepareSidecar,
            progress: { inner in
                progress(HDRPanoramaProgress(fraction: Self.hdrShare + tail * inner.fraction, stage: inner.stage))
            })
    }

    /// Stand-in recipe sources for files the user never sees (the
    /// intermediates): the stitch needs one per frame, and every one of
    /// them is replaced by `recipeOverride` before anything is written.
    static func scratchSources(_ urls: [URL]) -> [MergeRecipe.Source] {
        urls.map { MergeRecipe.Source(path: $0.lastPathComponent, hash: "", captureTime: 0) }
    }

    /// What the result records: an HDR panorama made from the
    /// photographer's own photos, with both stages' settings.
    static func recipeOverride(_ analysis: HDRPanoramaAnalysis, options: HDRPanoramaOptions,
                               sources: [MergeRecipe.Source], stitch: PanoramaMergeAnalysis,
                               frameURLs: [URL]) -> PanoramaMergeOptions.RecipeOverride {
        let positions = analysis.grouping.positions
        // The stitch lists its frames in capture order; each is one of
        // `frameURLs`, so a frame maps back to the position that made it.
        let positionOf = { (url: URL) -> Int? in
            frameURLs.firstIndex { $0.standardizedFileURL == url.standardizedFileURL }
        }
        let joined = stitch.frames.enumerated().first { !$0.element.leftOut }
        let referencePosition = joined.flatMap { positionOf($0.element.url) } ?? 0
        let referencePhoto = positions.indices.contains(referencePosition)
            ? (positions[referencePosition].frames.first ?? 0) : 0

        var recorded: [String: JSONValue] = [
            "hdrPanorama": .bool(true),
            "experimental": .bool(true),
            "positions": .number(Double(positions.count)),
            "grouping": .string(analysis.grouping.evidence.rawValue),
            "autoAlign": .bool(options.hdr.autoAlign),
            "deghost": .string(options.hdr.deghost.rawValue),
        ]
        // Which photos went into each position, by index into `sources`.
        recorded["brackets"] = .array(positions.map { position in
            .object([
                "frames": .array(position.frames.map { .number(Double($0)) }),
                "reference": .number(Double(position.reference)),
                "merged": .bool(position.needsMerging),
            ])
        })
        let leftOut = stitch.frames.indices.filter { stitch.frames[$0].leftOut }
            .compactMap { positionOf(stitch.frames[$0].url) }
        if !leftOut.isEmpty { recorded["positionsLeftOut"] = .array(leftOut.map { .number(Double($0)) }) }
        return PanoramaMergeOptions.RecipeOverride(kind: .hdrPanorama, sources: sources,
                                                   reference: referencePhoto, options: recorded)
    }
}

/// How alike two consecutive photos look, for the grouper's last resort.
///
/// Each photo is reduced to the panorama's own 1/8 thumbnail
/// (`PanoramaFramePrep`) the first time it is asked about, and kept. The
/// two are compared as the correlation of their log luminance over the
/// texels both recorded well — log, so that a bracket's two stops of
/// exposure difference don't matter at all, and only texels neither
/// clipped nor lost in noise, for the same reason. Frames of one bracket
/// come out at nearly 1; a new position, which shows a different part of
/// the scene in most of the frame, comes out far lower.
///
/// Not Sendable: used from one task, inside one `analyse`.
final class OverlapMeasure {
    private let photos: [HDRPanoramaPhoto]
    private let gpu: GPUContext?
    private var prep: PanoramaFramePrep?
    private var prepared: [PanoramaFramePrep.Photo] = []
    private var thumbnails: [Int: PanoramaThumbnail] = [:]

    /// Fewest usable texels for a comparison to mean anything.
    static let minimumSamples = 64
    /// Luminance below this is noise, in prepared units (white is 1).
    static let darkest: Float = 1.0 / 1024

    init(photos: [HDRPanoramaPhoto], gpu: GPUContext?) {
        self.photos = photos
        self.gpu = gpu
    }

    /// How alike the photo at `index` and the one after it look, 0 to 1.
    func similarity(_ index: Int) throws -> Double {
        guard photos.indices.contains(index), photos.indices.contains(index + 1) else { return 0 }
        guard let first = try thumbnail(index), let second = try thumbnail(index + 1) else { return 0 }
        return Self.correlation(first, second)
    }

    private func thumbnail(_ index: Int) throws -> PanoramaThumbnail? {
        if let kept = thumbnails[index] { return kept }
        guard let gpu else { return nil }
        if prep == nil {
            let made = PanoramaFramePrep(gpu: gpu)
            // The prep sorts by capture time, which is the order the photos
            // are already in; if it disagrees, the indices would not match.
            let opened = try made.photos(photos.map(\.url))
            guard opened.map(\.url) == photos.map(\.url) else { return nil }
            prep = made
            prepared = opened
        }
        guard let prep, prepared.indices.contains(index) else { return nil }
        let measured = try prep.measure(prepared[index])
        let thumbnail = measured.input.thumbnail
        thumbnails[index] = thumbnail
        return thumbnail
    }

    /// The correlation of two thumbnails' log luminance, 0 (nothing in
    /// common, or too little to say) to 1 (the same view).
    static func correlation(_ a: PanoramaThumbnail, _ b: PanoramaThumbnail) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        let first = a.luminance, second = b.luminance
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(first.count)
        ys.reserveCapacity(first.count)
        for i in first.indices where a.clippedShare[i] < 0.5 && b.clippedShare[i] < 0.5
            && first[i] > darkest && second[i] > darkest {
            xs.append(Double(log2(first[i])))
            ys.append(Double(log2(second[i])))
        }
        guard xs.count >= minimumSamples else { return 0 }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for i in xs.indices {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        let spread = (varianceX * varianceY).squareRoot()
        guard spread > 0 else { return 0 }
        return max(0, min(1, covariance / spread))
    }
}

/// An error in the words a merge reports it with, wherever that is needed
/// inside MergeKit.
enum PhotoMergeText {
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
