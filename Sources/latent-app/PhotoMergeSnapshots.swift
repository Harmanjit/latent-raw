#if DEBUG
import AppKit
import Catalog
import MergeKit

/// The snapshot harness's `hdrmerge` step (SnapshotHarness.swift lists the
/// steps): the HDR Merge dialog over the window, measured by a stand-in
/// engine so it can be pictured from any folder. Debug builds only, like
/// the harness.
@MainActor
enum PhotoMergeSnapshots {
    /// Selects three images (the selection and those after it), opens the
    /// dialog with the stand-in engine, and waits for its list. Returns the
    /// window to picture, or what went wrong.
    static func enter(window: NSWindow, library: Library,
                      perform: (KeyCommand) -> Bool) async -> (window: NSWindow?, problem: String?) {
        guard let selected = library.selectedImage,
              let index = library.visibleImages.firstIndex(where: { $0.id == selected.id }) else {
            return (nil, "no image selected")
        }
        let around = library.visibleImages[index...] + library.visibleImages[..<index].reversed()
        let ids = Set(around.prefix(3).compactMap(\.id))
        guard ids.count >= 2 else { return (nil, "the folder has fewer than two images") }
        library.setSelection(ids, primary: selected.id)
        PhotoMergeEngine.debugHDR = StandInHDRMerger()
        _ = perform(.photoMergeHDR)
        let deadline = Date().addingTimeInterval(10)
        while window.attachedSheet?.isVisible != true, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard window.attachedSheet?.isVisible == true else { return (nil, "the dialog did not open (is the GPU ready?)") }
        // The stand-in answers at once; the list and thumbnails a moment later.
        try? await Task.sleep(for: .milliseconds(500))
        return (window, nil)
    }

    static func leave(window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        PhotoMergeEngine.debugHDR = nil
    }
}

/// Measures nothing: says the files are a 2 EV bracket of a 24 MP camera,
/// brightest first, shot by hand: with Auto Align, aligned by up to 17 px
/// with the last photo left out, the longest the dialog's text gets; without
/// it, the misalignment warning.
private struct StandInHDRMerger: HDRMerging {
    func analyse(_ urls: [URL], options: HDRMergeOptions) async throws -> HDRMergeAnalysis {
        // A camera's shutter speeds, 2 stops apart.
        let speeds: [Double] = [15, 60, 250, 1000, 4000, 16000]
        let count = min(urls.count, speeds.count)
        let reference = count / 2
        let frames = urls.prefix(speeds.count).enumerated().map { index, url in
            HDRMergeFrame(url: url, exposureSeconds: 1 / speeds[index], iso: 100, aperture: 8,
                          relativeEV: Double(-2 * index), exifRelativeEV: Double(-2 * index),
                          clippedFraction: 0.2 / Double(index + 1),
                          alignmentShiftPixels: !options.autoAlign || index == count - 1 ? nil
                              : index == reference ? 0 : 16.6)
        }
        let warnings: [HDRMergeWarning] = options.autoAlign
            ? [.frameCouldNotBeAligned(frameIndex: count - 1, leftOut: true)]
            : [.framesLookMisaligned(maximumShiftPixels: 16.6)]
        return HDRMergeAnalysis(frames: frames, referenceIndex: reference, width: 6016, height: 4016,
                                exposureRangeStops: Double(2 * max(frames.count - 1, 0)),
                                warnings: warnings, estimatedOutputBytes: 145_000_000)
    }

    func merge(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (HDRMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
        // The step only looks; a merge from it writes nothing.
        throw CancellationError()
    }
}
#endif
