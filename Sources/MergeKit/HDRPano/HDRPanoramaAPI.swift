import Foundation

// The HDR panorama's public contract: what the app asks for and what it
// gets back, mirroring the HDR merge's shape (MergeKit/HDR/HDRMergeAPI.swift)
// and the panorama's (MergeKit/Pano/PanoramaMergeAPI.swift). The engine and
// the app's HDR Panorama command are built against this file.
//
// **Experimental.** Nobody has yet shot a real HDR panorama for Latent to
// be checked against, and none is freely licensed, so every test is
// synthetic or cut out of a real bracket. The menu item, the dialog and
// docs/wiki/Photo-Merge.md all say so.

/// Both stages' settings. The HDR stage merges each position; the panorama
/// stage stitches the results.
public struct HDRPanoramaOptions: Sendable, Equatable {
    /// Auto Align and Deghost for every position. `referenceIndex` is
    /// ignored: each position picks its own reference frame, since one
    /// index can't mean anything across several brackets.
    public var hdr: HDRMergeOptions
    /// Projection, Auto Crop and Auto Settings for the stitch.
    public var panorama: PanoramaMergeOptions

    public init(hdr: HDRMergeOptions = HDRMergeOptions(), panorama: PanoramaMergeOptions = PanoramaMergeOptions()) {
        self.hdr = hdr
        self.panorama = panorama
    }
}

/// Something the dialog should say before merging. None of these stop a
/// merge; `HDRPanoramaError` does.
public enum HDRPanoramaWarning: Sendable, Equatable {
    /// The positions hold different numbers of photos. Each is merged with
    /// what it has, but a position with fewer exposures has less range.
    case unevenBrackets(counts: [Int])
    /// This position is a single raw photo with no bracket around it, so it
    /// goes into the panorama as it is: there is nothing to merge it with.
    case singlePhotoPosition(position: Int, fileName: String)
    /// This position is a photo that was already merged, so the Auto Align
    /// and Deghost settings below don't apply to it.
    case alreadyMergedPosition(position: Int, fileName: String)
    /// The positions could only be told apart by something weaker than the
    /// repeating exposures, so check the list before merging.
    case groupingIsAGuess(evidence: HDRPanoramaGrouping.Evidence)
    /// The intermediate HDRs need this much room while the merge runs; it
    /// is given back when the merge ends, however it ends.
    case scratchSpace(bytes: Int64)
    /// What the stitch itself has to say.
    case panorama(PanoramaMergeWarning)
}

/// Why a selection can't be made into an HDR panorama, in words the dialog
/// can show.
public enum HDRPanoramaError: Error, Equatable, LocalizedError {
    case tooFewPhotos
    /// The photos don't fall into positions any of the evidence can see.
    case cantTellPositions
    /// Everything is one position: a bracket, not a panorama.
    case tooFewPositions
    /// No position has more than one photo and none is already merged.
    case notBrackets
    /// Every photo has the same exposure.
    case sameExposure
    case unreadable(fileName: String, reason: String)
    /// Not a Bayer raw and not a linear DNG (an already-merged photo).
    case unsupportedSource(fileName: String)
    case differentCameras(fileName: String)
    /// The volume hasn't room for the intermediate HDRs and the result.
    case notEnoughDiskSpace(neededBytes: Int64, availableBytes: Int64)
    /// A position's own HDR merge failed, and why.
    case positionFailed(position: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .tooFewPhotos:
            "An HDR panorama needs at least two photos: a bracket or an HDR merge at each of two or more positions."
        case .cantTellPositions:
            "These don’t look like brackets: each position needs the same exposures. "
                + "Shoot the same bracket at every position, or merge each bracket with Photo Merge › HDR first."
        case .tooFewPositions:
            "These photos are all one position, so there is nothing to stitch. Use Photo Merge › HDR instead."
        case .notBrackets:
            "None of these photos is part of a bracket. Use Photo Merge › Panorama instead."
        case .sameExposure:
            "The photos all have the same exposure. An HDR panorama needs a bracket at each position. "
                + "Use Photo Merge › Panorama instead."
        case .unreadable(let name, let reason): "\(name) couldn’t be read (\(reason))."
        case .unsupportedSource(let name):
            "\(name) isn’t a raw photo or an HDR merge, so it can’t be part of an HDR panorama."
        case .differentCameras(let name):
            "\(name) was taken with a different camera or focal length from the first photo."
        case .notEnoughDiskSpace(let needed, let available):
            "Not enough disk space: the HDR panorama needs "
                + "\(ByteCountFormatter().string(fromByteCount: needed)) for the merged brackets and the result, "
                + "and only \(ByteCountFormatter().string(fromByteCount: available)) is free."
        case .positionFailed(let position, let reason):
            "The bracket at position \(position + 1) couldn’t be merged: \(reason)"
        }
    }
}

/// Everything the dialog shows, worked out without merging anything.
///
/// **What the layout is solved from.** One photo per position — the
/// position's reference frame — not the merged HDRs, which don't exist yet.
/// A position's HDR comes out the same size, with the same lens and the
/// same capture time as that frame, so the layout the merge ends up with is
/// the same layout; only the pixels are cleaner. The merge solves it again
/// on the real intermediates, so the result is never stitched from a guess.
public struct HDRPanoramaAnalysis: Sendable {
    /// Every selected photo, in capture order.
    public let photos: [HDRPanoramaPhoto]
    public let grouping: HDRPanoramaGrouping
    /// The stitch of one photo per position: where each position points,
    /// how big the result will be and what the panorama warns about. Its
    /// frames are the positions, in the same order as `grouping.positions`.
    public let panorama: PanoramaMergeAnalysis
    public let warnings: [HDRPanoramaWarning]
    /// Roughly how big the result will be.
    public let estimatedOutputBytes: Int64
    /// Room the intermediate HDRs take while the merge runs, given back
    /// when it ends.
    public let estimatedScratchBytes: Int64

    public init(photos: [HDRPanoramaPhoto], grouping: HDRPanoramaGrouping, panorama: PanoramaMergeAnalysis,
                warnings: [HDRPanoramaWarning], estimatedOutputBytes: Int64, estimatedScratchBytes: Int64) {
        self.photos = photos; self.grouping = grouping; self.panorama = panorama; self.warnings = warnings
        self.estimatedOutputBytes = estimatedOutputBytes; self.estimatedScratchBytes = estimatedScratchBytes
    }

    /// The photo the result is named after and placed beside: the first
    /// photo, in capture order, of the first position the panorama joined
    /// to the rest. Nil when no position was joined.
    public var referencePhotoIndex: Int? {
        for frame in panorama.frames where !frame.leftOut {
            if let position = grouping.positions.first(where: { $0.reference == index(of: frame.url) }) {
                return position.frames.first
            }
        }
        return grouping.positions.first?.frames.first
    }

    private func index(of url: URL) -> Int? {
        photos.firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL }
    }
}

public struct HDRPanoramaProgress: Sendable, Equatable {
    /// 0...1 over both stages.
    public let fraction: Double
    /// A short phrase for the progress line, e.g. "Merging bracket 2 of 5".
    public let stage: String

    public init(fraction: Double, stage: String) {
        self.fraction = fraction; self.stage = stage
    }
}

/// The HDR panorama engine as the app sees it. `HDRPanoramaMerger` is the
/// real one; tests substitute their own.
public protocol HDRPanoramaMerging: Sendable {
    /// Groups the photos into positions and lays the panorama out. Throws
    /// `HDRPanoramaError`, or the panorama's own `PanoramaError`.
    func analyse(_ urls: [URL], options: HDRPanoramaOptions) async throws -> HDRPanoramaAnalysis

    /// Merges each position and stitches the results into `destination`
    /// (which must not exist).
    ///
    /// - Parameters:
    ///   - sources: one per `analysis.photos`, in the same order; they are
    ///     what the result's recipe records, so it names the photographer's
    ///     photos and not the intermediates.
    ///   - prepareSidecar: called with the recipe exactly as the DNG will
    ///     store it, before the DNG is written.
    /// Cancellation throws `CancellationError`, leaves no DNG and removes
    /// every intermediate.
    func merge(_ analysis: HDRPanoramaAnalysis, options: HDRPanoramaOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (HDRPanoramaProgress) -> Void) async throws -> MergeDNGWriteResult

    /// Frees anything the analysis kept (the dialog has closed).
    func releasePreviews() async
}

public extension HDRPanoramaMerging {
    func releasePreviews() async {}
}
