#if DEBUG
import AppKit
import Catalog
import CoreGraphics
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
/// brightest first, shot by hand, the first a little brighter than its EXIF:
/// with Auto Align, aligned by up to 17 px with the last photo left out, the
/// longest the dialog's text gets; without it, the misalignment warning.
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
        // With the note, three lines: the most the dialog shows before its
        // notes scroll, so the picture checks the tallest dialog.
        let warnings: [HDRMergeWarning] = [.exposureMetadataDisagrees(frameIndex: 0, exifRelativeEV: 0,
                                                                      measuredRelativeEV: 0.4)]
            + (options.autoAlign ? [.frameCouldNotBeAligned(frameIndex: count - 1, leftOut: true)]
                                 : [.framesLookMisaligned(maximumShiftPixels: 16.6)])
        return HDRMergeAnalysis(frames: frames, referenceIndex: reference, width: 6016, height: 4016,
                                exposureRangeStops: Double(2 * max(frames.count - 1, 0)),
                                warnings: warnings, estimatedOutputBytes: 145_000_000)
    }

    /// A made-up landscape (sky, hills, a sun) the size asked for, at the
    /// bracket's 3:2; with the overlay, an outlined, tinted patch where a
    /// deghosted walker might be.
    func preview(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, longEdge: Int,
                 showDeghostOverlay: Bool) async throws -> CGImage {
        let width = max(3, longEdge), height = max(2, longEdge * 2 / 3)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CancellationError() }
        let w = CGFloat(width), h = CGFloat(height)
        let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1),
                                                          CGColor(red: 0.95, green: 0.8, blue: 0.6, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.35), options: [])
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.7, y: h * 0.55, width: h * 0.16, height: h * 0.16))
        context.setFillColor(CGColor(red: 0.2, green: 0.32, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.36))
        context.move(to: .zero)
        context.addCurve(to: CGPoint(x: w, y: h * 0.3), control1: CGPoint(x: w * 0.3, y: h * 0.6),
                         control2: CGPoint(x: w * 0.6, y: h * 0.1))
        context.addLine(to: CGPoint(x: w, y: 0))
        context.fillPath()
        if showDeghostOverlay, options.deghost != .none {
            let patch = CGRect(x: w * 0.3, y: h * 0.15, width: w * 0.12, height: h * 0.25)
            let colour = HDRDeghostOverlay.colour(forFrame: options.referenceIndex ?? analysis.referenceIndex)
            context.setFillColor(CGColor(red: CGFloat(colour.red) / 255, green: CGFloat(colour.green) / 255,
                                         blue: CGFloat(colour.blue) / 255, alpha: 0.4))
            context.fill(patch)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.stroke(patch, width: 2)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.stroke(patch.insetBy(dx: 2, dy: 2), width: 1)
        }
        guard let image = context.makeImage() else { throw CancellationError() }
        return image
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
