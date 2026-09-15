import Foundation
import MergeKit
import PixelEngine

/// Where Photo › Photo Merge › HDR… gets its merge engine.
///
/// The app only ever talks to the engine through `HDRMerging`
/// (MergeKit/HDR/HDRMergeAPI.swift), so the sheet, the job and their tests
/// never depend on how merging is done. This is the one place that picks
/// the real engine; tests hand the sheet and the job a fake of their own.
@MainActor
enum PhotoMergeEngine {
    #if DEBUG
    /// Stands in for the engine in debug runs, for the snapshot harness's
    /// HDR merge step, so the sheet can be pictured without real brackets.
    static var debugHDR: (any HDRMerging)?
    #endif

    /// The HDR engine, using `gpu` for the merge.
    static func hdr(gpu: GPUContext) -> any HDRMerging {
        #if DEBUG
        if let debugHDR { return debugHDR }
        #endif
        return UnavailableHDRMerger() // LEAD: construct HDRMerger(gpu:) here when merge/hdr-core lands
    }
}

/// The engine this build has until the real one is part of it: every
/// request fails with a message the sheet shows in place of the photos.
struct UnavailableHDRMerger: HDRMerging {
    static let error = HDRMergeError.gpuUnavailable(reason: "The HDR engine isn't built into this version yet")

    func analyse(_ urls: [URL]) async throws -> HDRMergeAnalysis {
        throw Self.error
    }

    func merge(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (HDRMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
        throw Self.error
    }
}
