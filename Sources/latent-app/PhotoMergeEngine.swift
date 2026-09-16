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
    /// The same for the HDR Panorama dialog's step.
    static var debugHDRPanorama: (any HDRPanoramaMerging)?
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
    static func panorama(gpu: GPUContext) -> any PanoramaMerging {
        #if DEBUG
        if let debugPanorama { return debugPanorama }
        #endif
        return PanoramaMerger(gpu: gpu)
    }

    /// The HDR panorama engine (experimental): the HDR engine for each
    /// position and the panorama engine for the stitch, both on `gpu`.
    static func hdrPanorama(gpu: GPUContext) -> any HDRPanoramaMerging {
        #if DEBUG
        if let debugHDRPanorama { return debugHDRPanorama }
        #endif
        return HDRPanoramaMerger(gpu: gpu)
    }
}
