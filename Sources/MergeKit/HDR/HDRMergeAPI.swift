import Foundation

// The HDR merge's public contract: what the app asks for and what it gets
// back. The engine (`HDRMerger`, Phase 4) and the app's Photo Merge job
// (Phase 5b) were built in parallel against this file, so change it only
// with both sides in view. docs/PhotoMerge.md section 3 describes the
// algorithm behind it.

/// One photo of a bracket, as the analysis understood it.
public struct HDRMergeFrame: Sendable, Equatable {
    public let url: URL
    public let exposureSeconds: Double
    public let iso: Double
    public let aperture: Double
    /// Stops of light this frame gathered relative to the brightest frame:
    /// 0 for the brightest, negative for darker ones (-2 means a quarter
    /// of the light). This is the value the merge uses: measured from the
    /// pixels when possible, from the EXIF otherwise.
    public let relativeEV: Double
    /// The same, worked out from EXIF (shutter, ISO, aperture) alone.
    public let exifRelativeEV: Double
    /// Share of pixels clipped (at the sensor's maximum) in this frame, 0...1.
    public let clippedFraction: Double

    public init(url: URL, exposureSeconds: Double, iso: Double, aperture: Double,
                relativeEV: Double, exifRelativeEV: Double, clippedFraction: Double) {
        self.url = url; self.exposureSeconds = exposureSeconds; self.iso = iso; self.aperture = aperture
        self.relativeEV = relativeEV; self.exifRelativeEV = exifRelativeEV; self.clippedFraction = clippedFraction
    }
}

/// Something the user should know before merging. None of these stop a
/// merge; errors (`HDRMergeError`) do.
public enum HDRMergeWarning: Sendable, Equatable {
    /// Neighbouring frames are offset by up to this many full-resolution
    /// pixels. v1 doesn't align frames yet, so the result may show double
    /// edges.
    case framesLookMisaligned(maximumShiftPixels: Double)
    /// The pixels say this frame's exposure differs from its EXIF by this
    /// much; the measured value is used.
    case exposureMetadataDisagrees(frameIndex: Int, exifRelativeEV: Double, measuredRelativeEV: Double)
    /// The whole bracket spans less than 1 stop, so merging gains little.
    case smallExposureRange(stops: Double)
}

/// Everything the dialog shows, and what `merge` needs, found without
/// rendering full-resolution frames.
public struct HDRMergeAnalysis: Sendable, Equatable {
    /// In exposure order, brightest first.
    public let frames: [HDRMergeFrame]
    /// Index into `frames` of the frame whose exposure the result opens
    /// with (the one with the fewest clipped and crushed pixels).
    public let referenceIndex: Int
    /// The result's size in pixels, before orientation.
    public let width: Int
    public let height: Int
    /// Stops between the darkest and brightest frames.
    public let exposureRangeStops: Double
    public let warnings: [HDRMergeWarning]
    /// Roughly how big the DNG will be, for the free-space check and the dialog.
    public let estimatedOutputBytes: Int64

    public init(frames: [HDRMergeFrame], referenceIndex: Int, width: Int, height: Int,
                exposureRangeStops: Double, warnings: [HDRMergeWarning], estimatedOutputBytes: Int64) {
        self.frames = frames; self.referenceIndex = referenceIndex; self.width = width; self.height = height
        self.exposureRangeStops = exposureRangeStops; self.warnings = warnings
        self.estimatedOutputBytes = estimatedOutputBytes
    }
}

public struct HDRMergeOptions: Sendable, Equatable, Codable {
    /// Overrides the automatic reference frame (an index into
    /// `HDRMergeAnalysis.frames`); nil chooses automatically.
    public var referenceIndex: Int?
    /// How hard the merge looks for things that moved (Phase 6b).
    public var deghost: DeghostAmount = .none

    public init(referenceIndex: Int? = nil, deghost: DeghostAmount = .none) {
        self.referenceIndex = referenceIndex
        self.deghost = deghost
    }

    private enum CodingKeys: String, CodingKey { case referenceIndex, deghost }

    /// Written by hand so options saved before a field existed still decode,
    /// with that field at its default: the synthesised decoder would
    /// refuse JSON without a `deghost` key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceIndex = try container.decodeIfPresent(Int.self, forKey: .referenceIndex)
        deghost = try container.decodeIfPresent(DeghostAmount.self, forKey: .deghost) ?? DeghostAmount.none
    }
}

/// Why a set of photos can't be merged, in words the dialog can show.
public enum HDRMergeError: Error, Equatable, LocalizedError {
    case tooFewFrames
    case tooManyFrames(limit: Int)
    case differentCameras
    case differentSizes
    case differentOrientations
    /// Not a Bayer raw (an X-Trans, monochrome or already-merged file).
    case unsupportedSource(fileName: String)
    /// Every frame has (nearly) the same exposure.
    case sameExposure
    case notEnoughDiskSpace(neededBytes: Int64, availableBytes: Int64)
    case unreadable(fileName: String, reason: String)
    /// The GPU couldn't provide the memory the merge needs.
    case gpuUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .tooFewFrames: "Select at least two photos to merge."
        case .tooManyFrames(let limit): "HDR merges take at most \(limit) photos on this Mac."
        case .differentCameras: "The photos were taken with different cameras."
        case .differentSizes: "The photos aren't all the same size."
        case .differentOrientations: "The photos weren't all taken in the same orientation."
        case .unsupportedSource(let name): "\(name) can't be merged: only Bayer raw files can."
        case .sameExposure: "The photos all have the same exposure. HDR needs a bracket: the same scene at different exposures."
        case .notEnoughDiskSpace(let needed, let available):
            "Not enough disk space: the merge needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free."
        case .unreadable(let name, let reason): "\(name) couldn't be read: \(reason)"
        case .gpuUnavailable(let reason): "The graphics processor couldn't run the merge: \(reason)"
        }
    }
}

public struct HDRMergeProgress: Sendable, Equatable {
    /// 0...1 over the whole merge.
    public let fraction: Double
    /// A short phrase for the progress line, e.g. "Merging photo 2 of 3".
    public let stage: String

    public init(fraction: Double, stage: String) {
        self.fraction = fraction; self.stage = stage
    }
}

/// The merge engine as the app sees it. `HDRMerger` is the real one; tests
/// substitute their own.
public protocol HDRMerging: Sendable {
    /// Validates the photos and measures them. Throws `HDRMergeError`.
    func analyse(_ urls: [URL]) async throws -> HDRMergeAnalysis

    /// Merges and writes the DNG to `destination` (which must not exist).
    ///
    /// - Parameters:
    ///   - sources: one per `analysis.frames`, in the same order, for the
    ///     recipe (paths relative to the destination's folder).
    ///   - prepareSidecar: called with the recipe exactly as the DNG will
    ///     store it, after the pixels are merged and before the DNG is
    ///     written; the app writes the result's sidecar here. If it throws,
    ///     nothing is written and the error is rethrown.
    ///   - progress: called from any thread.
    /// Checks for cancellation between frames and while writing; a
    /// cancelled merge throws `CancellationError` and leaves no DNG.
    func merge(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (HDRMergeProgress) -> Void) async throws -> MergeDNGWriteResult
}
