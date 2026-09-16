import Foundation
import CoreGraphics

// The panorama merge's public contract: what the app asks for and what it
// gets back, mirroring the HDR merge's shape (MergeKit/HDR/HDRMergeAPI.swift).
// The engine (Phase 8c) and the app's Panorama command were built in
// parallel against this file, so change it only with both sides in view.

public struct PanoramaMergeOptions: Sendable, Equatable, Codable {
    /// `.automatic` lets the solver choose (Perspective up to about 70°
    /// across, else Cylindrical).
    public var projection: PanoramaProjection
    /// Store the auto-crop rectangle as the result's crop edit, so the
    /// blank edges are hidden but can be undone.
    public var autoCrop: Bool
    /// Apply Latent's Auto adjust to the result, as the HDR merge's option does.
    public var autoSettings: Bool
    /// What the result records about itself, when that isn't what the
    /// stitch alone would say. Nil for an ordinary panorama; set by the HDR
    /// Panorama merge (Phase 9), which hands the stitcher intermediate HDRs
    /// it made itself and must record the photographer's own photos.
    /// It belongs to one merge, not to the user's settings, so it is not
    /// encoded with them.
    public var recipeOverride: RecipeOverride?

    /// The recipe an HDR panorama writes in place of the stitch's own.
    public struct RecipeOverride: Sendable, Equatable {
        /// `.hdrPanorama`, in practice.
        public var kind: MergeRecipe.Kind
        /// Replaces the sources the merge was given (the intermediate
        /// HDRs): every photo the user selected, in the HDR panorama
        /// analysis's order.
        public var sources: [MergeRecipe.Source]
        /// Index into `sources` of the photo the result follows.
        public var reference: Int
        /// Added to the options the stitch records: the HDR stage's
        /// settings and how the positions were found.
        public var options: [String: JSONValue]

        public init(kind: MergeRecipe.Kind, sources: [MergeRecipe.Source], reference: Int,
                    options: [String: JSONValue] = [:]) {
            self.kind = kind; self.sources = sources; self.reference = reference; self.options = options
        }
    }

    public init(projection: PanoramaProjection = .automatic, autoCrop: Bool = true, autoSettings: Bool = false,
                recipeOverride: RecipeOverride? = nil) {
        self.projection = projection; self.autoCrop = autoCrop; self.autoSettings = autoSettings
        self.recipeOverride = recipeOverride
    }

    /// `recipeOverride` is left out on purpose: see its note.
    private enum CodingKeys: String, CodingKey { case projection, autoCrop, autoSettings }
}

/// One photo, as the analysis understood it.
public struct PanoramaMergeFrame: Sendable, Equatable {
    public let url: URL
    public let captureTime: Date
    public let exposureSeconds: Double
    public let iso: Double
    public let aperture: Double
    /// Brightness correction applied to this photo so it matches the
    /// panorama, in stops (0 for the photo the gains are measured against).
    public let gainStops: Double
    /// Where the photo points: yaw, pitch and roll in degrees, nil when the
    /// photo is left out.
    public let yawPitchRoll: SIMD3<Double>?
    /// True when no accepted pair connects this photo to the rest, so it is
    /// not part of the panorama.
    public let leftOut: Bool

    public init(url: URL, captureTime: Date, exposureSeconds: Double, iso: Double, aperture: Double,
                gainStops: Double, yawPitchRoll: SIMD3<Double>?, leftOut: Bool) {
        self.url = url; self.captureTime = captureTime; self.exposureSeconds = exposureSeconds
        self.iso = iso; self.aperture = aperture; self.gainStops = gainStops
        self.yawPitchRoll = yawPitchRoll; self.leftOut = leftOut
    }
}

/// Something the dialog should say before merging. None of these stop a
/// merge; `PanoramaMergeError` does.
public enum PanoramaMergeWarning: Sendable, Equatable {
    /// Photos that couldn't be joined to the rest, by index into `frames`.
    case framesLeftOut(indices: [Int])
    /// The panorama is bigger than this Mac can edit, so it will be made
    /// smaller. The user has to agree (Harman's rule: never refuse a
    /// panorama for its size).
    case downsampled(outputSize: PanoramaOutputSize)
    /// The photos differ in brightness by more than this many stops even
    /// after evening them out, so seams may still show.
    case unevenExposure(stops: Double)
    /// The cameras explain the matches only to this many pixels: usually
    /// parallax from a handheld sweep, so near objects may look doubled.
    case largeParallax(rmsPixels: Double)
}

/// Everything the dialog shows, worked out from reduced copies of the photos.
public struct PanoramaMergeAnalysis: Sendable {
    /// In capture order.
    public let frames: [PanoramaMergeFrame]
    public let layout: PanoramaLayout
    public let outputSize: PanoramaOutputSize
    /// Degrees across and up/down.
    public let widthDegrees: Double
    public let heightDegrees: Double
    public let warnings: [PanoramaMergeWarning]
    public let estimatedOutputBytes: Int64

    public init(frames: [PanoramaMergeFrame], layout: PanoramaLayout, outputSize: PanoramaOutputSize,
                widthDegrees: Double, heightDegrees: Double, warnings: [PanoramaMergeWarning],
                estimatedOutputBytes: Int64) {
        self.frames = frames; self.layout = layout; self.outputSize = outputSize
        self.widthDegrees = widthDegrees; self.heightDegrees = heightDegrees
        self.warnings = warnings; self.estimatedOutputBytes = estimatedOutputBytes
    }
}

public struct PanoramaMergeProgress: Sendable, Equatable {
    /// 0...1 over the whole merge.
    public let fraction: Double
    /// A short phrase for the progress line, e.g. "Stitching tile 4 of 30".
    public let stage: String

    public init(fraction: Double, stage: String) {
        self.fraction = fraction; self.stage = stage
    }
}

/// The panorama engine as the app sees it. Tests substitute their own.
public protocol PanoramaMerging: Sendable {
    /// Reads the photos, works out where each one goes and how big the
    /// result will be. Throws `PanoramaError`.
    func analyse(_ urls: [URL], options: PanoramaMergeOptions) async throws -> PanoramaMergeAnalysis

    /// A quick picture of the finished panorama for the dialog, at most
    /// `longEdge` pixels on its long side, rendered through the normal
    /// pipeline so it looks like the result will.
    func preview(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                 longEdge: Int) async throws -> CGImage

    /// Stitches and writes the DNG to `destination` (which must not exist).
    /// `sources` matches `analysis.frames` in order. `prepareSidecar` is
    /// called with the recipe exactly as the DNG will store it, before the
    /// DNG is written, so the app can write the result's sidecar; if it
    /// throws, nothing is written. Cancellation throws `CancellationError`,
    /// leaves no DNG and removes any scratch files.
    func merge(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (PanoramaMergeProgress) -> Void) async throws -> MergeDNGWriteResult

    /// Frees anything the analysis kept for previews.
    func releasePreviews() async
}

public extension PanoramaMerging {
    func releasePreviews() async {}
}
