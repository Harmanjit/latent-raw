import CoreGraphics
import Foundation
import MergeKit
import PixelEngine

/// Where Photo › Photo Merge gets its merge engines.
///
/// The app only ever talks to an engine through `HDRMerging` or
/// `PanoramaMerging` (MergeKit/HDR/HDRMergeAPI.swift,
/// MergeKit/Pano/PanoramaMergeAPI.swift), so the sheets, the job and their
/// tests never depend on how merging is done. This is the one place that
/// picks the real engine; tests hand the sheets and the job a fake of their
/// own.
@MainActor
enum PhotoMergeEngine {
    #if DEBUG
    /// Stands in for the engine in debug runs, for the snapshot harness's
    /// HDR merge step, so the sheet can be pictured without real brackets.
    static var debugHDR: (any HDRMerging)?
    /// The same for the Panorama dialog's step.
    static var debugPanorama: (any PanoramaMerging)?
    #endif

    /// The HDR engine, using `gpu` for the merge.
    ///
    /// - Parameter forDialog: the dialog's engine keeps each photo reduced
    ///   while measuring it, for the preview; HDR Merge Without Dialog's
    ///   has no preview, so it doesn't.
    static func hdr(gpu: GPUContext, forDialog: Bool = false) -> any HDRMerging {
        #if DEBUG
        if let debugHDR { return debugHDR }
        #endif
        return HDRMerger(gpu: gpu, keepsPreviewFrames: forDialog)
    }

    /// The panorama engine, using `gpu` for the stitch.
    ///
    /// The real engine (`PanoramaMerger`) is being written on its own
    /// branch; until it lands this hands back a stand-in that throws, so
    /// the command, the dialog and the job are complete and testable and
    /// only this one line changes when the engine arrives.
    static func panorama(gpu: GPUContext) -> any PanoramaMerging {
        #if DEBUG
        if let debugPanorama { return debugPanorama }
        #endif
        // LEAD: construct PanoramaMerger(gpu:) here when merge/pano-engine lands.
        return UnbuiltPanoramaMerger()
    }

    /// What `panorama(gpu:)` hands back until the engine is built in: every
    /// call throws, so the dialog says so instead of the app pretending it
    /// can stitch.
    struct UnbuiltPanoramaMerger: PanoramaMerging {
        static let reason = "The panorama engine isn’t built into this version yet"

        func analyse(_ urls: [URL], options: PanoramaMergeOptions) async throws -> PanoramaMergeAnalysis {
            throw PanoramaError.gpuUnavailable(reason: Self.reason)
        }

        func preview(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                     longEdge: Int) async throws -> CGImage {
            throw PanoramaError.gpuUnavailable(reason: Self.reason)
        }

        func merge(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                   sources: [MergeRecipe.Source], to destination: URL,
                   prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
                   progress: @escaping @Sendable (PanoramaMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
            throw PanoramaError.gpuUnavailable(reason: Self.reason)
        }
    }
}
