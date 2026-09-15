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
}
