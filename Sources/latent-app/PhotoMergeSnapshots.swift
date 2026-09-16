#if DEBUG
import AppKit
import Catalog
import CoreGraphics
import MergeKit
import simd

/// The snapshot harness's `hdrmerge` and `panoramamerge` steps
/// (SnapshotHarness.swift lists the steps): a Photo Merge dialog over the
/// window, measured by a stand-in engine so it can be pictured from any
/// folder. Debug builds only, like the harness.
@MainActor
enum PhotoMergeSnapshots {
    /// Selects a few images (the selection and those after it), opens the
    /// step's dialog with a stand-in engine, and waits for its list.
    /// Returns the window to picture, or what went wrong.
    static func enter(_ step: SnapshotPlan.Step, window: NSWindow, library: Library,
                      perform: (KeyCommand) -> Bool) async -> (window: NSWindow?, problem: String?) {
        guard let selected = library.selectedImage,
              let index = library.visibleImages.firstIndex(where: { $0.id == selected.id }) else {
            return (nil, "no image selected")
        }
        let panorama = step == .panoramaMerge
        let around = library.visibleImages[index...] + library.visibleImages[..<index].reversed()
        let ids = Set(around.prefix(panorama ? 4 : 3).compactMap(\.id))
        guard ids.count >= 2 else { return (nil, "the folder has fewer than two images") }
        library.setSelection(ids, primary: selected.id)
        if panorama {
            PhotoMergeEngine.debugPanorama = StandInPanoramaMerger()
            _ = perform(.photoMergePanorama)
        } else {
            PhotoMergeEngine.debugHDR = StandInHDRMerger()
            _ = perform(.photoMergeHDR)
        }
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
        PhotoMergeEngine.debugPanorama = nil
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

/// Measures nothing: says the photos are a handheld sweep of a 24 MP
/// camera, taken left to right, the last one too far from the rest to join,
/// with every warning the dialog can show — including a panorama far too
/// big for this Mac, so the picture always checks the agreement and the
/// tallest dialog.
private struct StandInPanoramaMerger: PanoramaMerging {
    /// Harman's own 17-frame sweep, rounded: the numbers the dialog's
    /// downsampling sentence was written against.
    static let fullSize = (width: 29_195, height: 7_664)
    static let outputSize = PanoramaOutputSize(fullWidth: fullSize.width, fullHeight: fullSize.height,
                                               scale: 0.4275, width: 12_482, height: 3_276,
                                               limit: .memory, decodeSpan: 2)

    func analyse(_ urls: [URL], options: PanoramaMergeOptions) async throws -> PanoramaMergeAnalysis {
        // A real engine sorts a sweep by capture time; the selection arrives
        // in the grid's order, so by name is the same thing here.
        let urls = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let count = urls.count
        let frames = urls.enumerated().map { index, url in
            let leftOut = count > 2 && index == count - 1
            let yaw = Double(index) * 24 - Double(count - 1) * 12
            return PanoramaMergeFrame(url: url, captureTime: Date(timeIntervalSince1970: 1_789_498_800 + Double(index)),
                                      exposureSeconds: 1.0 / 250, iso: 200, aperture: 5.6,
                                      gainStops: leftOut ? 0 : Double(index % 3) * 0.3 - 0.3,
                                      yawPitchRoll: leftOut ? nil : SIMD3(yaw, 0, 0), leftOut: leftOut)
        }
        let cameras = frames.enumerated().compactMap { index, frame -> PanoramaCamera? in
            guard let yaw = frame.yawPitchRoll?.x else { return nil }
            let radians = yaw * .pi / 180
            let rotation = [cos(radians), 0, sin(radians), 0, 1, 0, -sin(radians), 0, cos(radians)]
            return PanoramaCamera(frameIndex: index, rotation: rotation, focalLengthPixels: 5_000,
                                  principalPoint: SIMD2(2_008, 3_008), width: 4_016, height: 6_016,
                                  exposureGain: 1)
        }
        let canvas = PanoramaCanvas(projection: options.projection == .automatic ? .cylindrical
                                        : options.projection,
                                    pixelsPerRadian: 5_000, origin: SIMD2(-14_597, -3_832),
                                    width: Self.fullSize.width, height: Self.fullSize.height)
        let crop = CGRect(x: 300, y: 1_380, width: 28_595, height: 4_903)
        let layout = PanoramaLayout(cameras: cameras, canvas: canvas, autoCropRect: crop)
        let leftOut = frames.indices.filter { frames[$0].leftOut }
        var warnings: [PanoramaMergeWarning] = [.downsampled(outputSize: Self.outputSize),
                                                .largeParallax(rmsPixels: 7)]
        if !leftOut.isEmpty { warnings.insert(.framesLeftOut(indices: leftOut), at: 0) }
        return PanoramaMergeAnalysis(frames: frames, layout: layout, outputSize: Self.outputSize,
                                     widthDegrees: 186, heightDegrees: 44, warnings: warnings,
                                     estimatedOutputBytes: 245_000_000)
    }

    /// A made-up wide sweep the size asked for: sky, a ridge and a sun,
    /// with the ragged edges a stitch leaves.
    func preview(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                 longEdge: Int) async throws -> CGImage {
        let width = max(4, longEdge), height = max(2, longEdge * 3_276 / 12_482)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CancellationError() }
        let w = CGFloat(width), h = CGFloat(height)
        let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.25, green: 0.45, blue: 0.8, alpha: 1),
                                                          CGColor(red: 0.98, green: 0.78, blue: 0.5, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [])
        context.setFillColor(CGColor(red: 1, green: 0.94, blue: 0.75, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.52, width: h * 0.2, height: h * 0.2))
        context.setFillColor(CGColor(red: 0.18, green: 0.28, blue: 0.22, alpha: 1))
        context.move(to: CGPoint(x: 0, y: h * 0.42))
        for step in 0...24 {
            let x = w * CGFloat(step) / 24
            let y = h * (0.34 + 0.12 * CGFloat(abs(sin(Double(step) * 0.7))))
            context.addLine(to: CGPoint(x: x, y: y))
        }
        context.addLine(to: CGPoint(x: w, y: 0))
        context.addLine(to: CGPoint(x: 0, y: 0))
        context.fillPath()
        // The ragged edges of a stitch, which Auto Crop hides.
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for (index, corner) in [CGRect(x: 0, y: h * 0.86, width: w * 0.08, height: h * 0.14),
                                CGRect(x: w * 0.9, y: 0, width: w * 0.1, height: h * 0.1)].enumerated() {
            if options.autoCrop, index == 0 { continue }
            context.fill(corner)
        }
        guard let image = context.makeImage() else { throw CancellationError() }
        return image
    }

    func merge(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL, prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (PanoramaMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
        // The step only looks; a merge from it writes nothing.
        throw CancellationError()
    }
}
#endif
