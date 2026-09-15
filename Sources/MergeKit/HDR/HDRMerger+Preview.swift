// The HDR dialog's live preview, part 2: merging the reduced frames
// (HDRPreviewFrames.swift) with the dialog's options, through the merge's
// own steps, and rendering the result as the DNG will open.

import CoreGraphics
import Foundation
import PixelEngine
import RawCore
import simd

extension HDRMerger {
    /// The long edge, in photosites, a preview's frames are kept at: at most
    /// this, as close to it as a whole reduction allows (a 21 MP frame,
    /// 5,616 photosites long, is kept at half size, 2,808 long).
    ///
    /// **Why this big** when the dialog's picture is about 1,000 pixels:
    /// deghosting is judged on these frames, and it only finds what the
    /// full merge finds on frames reduced by 2 or so. On the Ihrke bracket,
    /// judged at a quarter of the size, Medium left out 20% of each frame
    /// where the merge leaves out 7%: patches of four photosites of wind-
    /// blown leaves average into blocks that all disagree a little. At half
    /// size every level leaves out within about a fifth of what the merge
    /// does, on all three test brackets (`HDRDeghostSettings.reduced(by:)`).
    /// The merge itself, which only needs the picture's pixels, runs on the
    /// frames reduced again (`previewFrames`).
    public static let previewCacheLongEdge = 3072

    /// Sensor photosites per kept photosite, along each side, for frames of
    /// `width x height` (`previewCacheLongEdge`).
    static func previewFactor(width: Int, height: Int) -> Int {
        max(1, Int((Double(max(width, height)) / Double(previewCacheLongEdge)).rounded(.up)))
    }

    public func preview(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, longEdge: Int,
                        showDeghostOverlay: Bool) async throws -> CGImage {
        try await previewWithReport(analysis, options: options, longEdge: longEdge,
                                    showDeghostOverlay: showDeghostOverlay).image
    }

    public func releasePreviews() {
        previewCache.release()
    }

    /// `preview`, with how long each stage took.
    ///
    /// **The same merge, smaller.** The kept frames are merged by the
    /// functions `merge` uses (`findGhosts`, `accumulate`, `storage`,
    /// `renderPreview`), with `HDRPreviewFrameSet.current` handing them the
    /// reduced frames. Only what is measured in pixels is scaled to the
    /// reduced frames, so it covers the same part of the scene: Auto Align's
    /// warps, the clip feathering, and deghosting's patch, widening and
    /// feathering (`reduced(by:)` below). Exposures, weights, clip levels
    /// and the recipe that decides how the DNG opens are the merge's own.
    ///
    /// **Two sizes.** Deghosting looks for movement on the kept frames (see
    /// `previewCacheLongEdge`); the frames are merged at the size the
    /// picture needs, with the deghosting masks averaged down to it.
    ///
    /// **Speed.** Nothing is read from disk once the frames are kept (the
    /// analysis keeps them when the merger was made with
    /// `keepsPreviewFrames`; otherwise the first preview reads them). A
    /// 6-frame, 21 MP bracket then previews in about a tenth of a second.
    ///
    /// - Parameter longEdge: the picture's long edge at most, in pixels;
    ///   never more than the kept frames'. The picture is upright (turned
    ///   as the reference photo was shot).
    public func previewWithReport(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, longEdge: Int,
                                  showDeghostOverlay: Bool) async throws -> (image: CGImage, report: HDRMergeReport) {
        var report = HDRMergeReport()
        let frames = analysis.frames
        guard frames.count >= 2 else { throw HDRMergeError.tooFewFrames }
        let reference = options.referenceIndex.flatMap { frames.indices.contains($0) ? $0 : nil } ?? analysis.referenceIndex
        let (kept, small) = try report.time("Reduce the photos") { try previewFrames(for: analysis, longEdge: longEdge) }
        try Task.checkCancellation()

        let alignment = options.autoAlign ? analysis.alignment?.plan(reference: reference) : nil
        let rotation = ImageRotation(libRawFlip: kept.file(for: frames[reference].url)?.summary.orientation ?? 0)

        // Movement, looked for on the kept frames.
        var ghosts: GhostPass?
        if let settings = options.deghost.settings {
            ghosts = try HDRPreviewFrameSet.$current.withValue(kept) {
                try findGhosts(frames, reference: reference, width: kept.width, height: kept.height,
                               alignment: alignment?.reduced(by: kept.factor),
                               settings: settings.reduced(by: kept.factor),
                               feather: clipFeather.reduced(by: kept.factor), report: &report) { _, _ in }
            }
        }
        try Task.checkCancellation()

        // The merge, on the frames the picture needs.
        let smallGhosts = ghosts.map { pass in
            GhostPass(masks: pass.masks.map { mask in
                          mask.map { HDRPreviewFrameSet.pool($0, to: small, from: kept) }
                      },
                      levels: pass.levels)
        }
        let image = try HDRPreviewFrameSet.$current.withValue(small) { () throws -> CGImage in
            let accumulated = try accumulate(frames, reference: reference, width: small.width, height: small.height,
                                             alignment: alignment?.reduced(by: small.factor), ghosts: smallGhosts,
                                             feather: clipFeather.reduced(by: small.factor),
                                             report: &report) { _, _ in }
            try Task.checkCancellation()
            let (_, _, stored, normalisation) = try storage(for: accumulated, reference: reference, options: options,
                                                            alignment: alignment, sources: [])
            return try report.time("Render preview") {
                try Self.gpuStep {
                    try renderPreview(accumulated.merged, normalisation: normalisation, recipe: stored,
                                      reference: accumulated.reference.summary,
                                      cameraToXYZ: accumulated.reference.cameraToXYZ,
                                      baselineExposure: frames[reference].relativeEV, longEdge: longEdge,
                                      rotation: rotation, fitting: true)
                }
            }
        }
        guard showDeghostOverlay, let ghosts,
              let ownership = HDRDeghostOverlay.ownership(masks: ghosts.masks, reference: reference) else {
            return (image, report)
        }
        // Drawn from the masks as deghosting found them, the finer ones.
        let overlaid = report.time("Draw the deghost overlay") {
            HDRDeghostOverlay.draw(ownership, over: image, sensorWidth: kept.width, sensorHeight: kept.height,
                                   rotation: rotation)
        }
        return (overlaid ?? image, report)
    }

    /// The analysed photos as a preview `longEdge` pixels long uses them:
    /// the kept frames, and those reduced again by the largest whole number
    /// that still leaves at least `longEdge` (the kept frames themselves when
    /// none does). Frames not kept yet (the merger doesn't keep them while
    /// analysing, or this is another bracket) are read and kept first.
    func previewFrames(for analysis: HDRMergeAnalysis, longEdge: Int)
    throws -> (kept: HDRPreviewFrameSet, small: HDRPreviewFrameSet) {
        let urls = analysis.frames.map(\.url)
        let factor = Self.previewFactor(width: analysis.width, height: analysis.height)
        previewCache.prepare(for: urls)
        for frame in analysis.frames where previewCache.frame(for: frame.url) == nil {
            try Task.checkCancellation()
            try autoreleasepool {
                let file = try Self.open(frame.url)
                let name = frame.url.lastPathComponent
                guard case .bayer = file.summary.cfaPattern else { throw HDRMergeError.unsupportedSource(fileName: name) }
                guard file.summary.width == analysis.width, file.summary.height == analysis.height else {
                    throw HDRMergeError.differentSizes
                }
                let levels = try Self.gpuStep { try Self.levels(for: file, gpu: gpu) }
                guard let reduced = HDRPreviewFrame.reduce(file, url: frame.url, levels: levels, factor: factor) else {
                    throw HDRMergeError.unreadable(fileName: name, reason: "there isn't enough memory for its preview")
                }
                previewCache.store(reduced)
            }
        }
        let size = HDRPreviewFrame.size(width: analysis.width, height: analysis.height, factor: factor)
        let by = max(1, max(size.width, size.height) / max(1, longEdge))
        // Released (the dialog closed) while this was reading: nothing to show.
        guard let kept = previewCache.frameSet(for: urls, reducedBy: 1),
              let small = previewCache.frameSet(for: urls, reducedBy: by) else { throw CancellationError() }
        return (kept, small)
    }
}

extension HDRPreviewFrameSet {
    /// A deghosting mask found on the frames of `from`, averaged down to the
    /// quarter-size map of `to` (the same frames reduced a whole number of
    /// times more), as the merge on `to` takes it.
    static func pool(_ mask: HDRGhostMask, to: HDRPreviewFrameSet, from: HDRPreviewFrameSet) -> HDRGhostMask {
        let by = max(1, to.factor / max(1, from.factor))
        let (w, h) = HDRMergeKernels.maskSize(width: to.width, height: to.height)
        guard by > 1 || (w, h) != (mask.width, mask.height) else { return mask }
        var weights = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let rows = (y * by)..<min((y + 1) * by, mask.height)
            for x in 0..<w {
                let columns = (x * by)..<min((x + 1) * by, mask.width)
                var sum = 0, count = 0
                for my in rows { for mx in columns { sum += Int(mask.weights[my * mask.width + mx]); count += 1 } }
                weights[y * w + x] = count > 0 ? UInt8((sum + count / 2) / count) : 0
            }
        }
        return HDRGhostMask(width: w, height: h, weights: weights)
    }
}

extension HDRMergeAlignment.Plan {
    /// The same plan for frames reduced `factor` times along each side: each
    /// warp in reduced pixels. Pixel centres sit at half-pixel positions in
    /// both (`MergeWarpKernels`), so coordinates are simply divided.
    func reduced(by factor: Int) -> HDRMergeAlignment.Plan {
        guard factor > 1 else { return self }
        let toReduced = simd_double3x3(diagonal: SIMD3(1 / Double(factor), 1 / Double(factor), 1))
        let homographies = self.homographies.map { h in
            Homography.isIdentity(h) ? h : toReduced * h * toReduced.inverse
        }
        return HDRMergeAlignment.Plan(frames: frames, homographies: homographies)
    }
}

extension HDRClipFeather {
    /// The same fade, over the same part of the scene, on frames reduced
    /// `factor` times along each side. Its sizes are in quarter-size pixels
    /// of the frame, so they shrink with it (rounded, for the erosion).
    func reduced(by factor: Int) -> HDRClipFeather {
        guard factor > 1 else { return self }
        return HDRClipFeather(erodeRadius: Int((Double(erodeRadius) / Double(factor)).rounded()),
                              sigma: sigma / Float(factor))
    }
}

extension HDRDeghostSettings {
    /// Nearly the same detection on frames reduced `factor` times along each
    /// side: the widening and feathering cover the same part of the scene,
    /// and the patch about the same part, needing a little under the same
    /// share of disagreeing blocks.
    ///
    /// **Calibrated, not derived.** Averaging photosites into bigger blocks
    /// smooths away small, scattered disagreements, so a patch scaled
    /// exactly finds less movement than the full merge does. Needing 65% of
    /// the share of disagreeing blocks (rounded up, at least one) makes up
    /// for it: on the Ihrke, Market Mires and Crete brackets, judged at half
    /// size, Low, Medium and High then leave out within about a fifth of
    /// what the full merge leaves out (Medium on Crete: 19.4% either way;
    /// High on Ihrke: 21.5% against 22.8%). Frames reduced 3 or 4 times
    /// (sensors over about 36 MP) have patches of 3 x 3 blocks, where the
    /// rounding is coarser, so their previews are a rougher guide.
    func reduced(by factor: Int) -> HDRDeghostSettings {
        guard factor > 1 else { return self }
        var reduced = self
        let f = Double(factor)
        reduced.patchRadius = max(1, Int((Double(patchRadius) / f).rounded()))
        let share = Double(patchCount) / pow(Double(2 * patchRadius + 1), 2)
        let blocks = pow(Double(2 * reduced.patchRadius + 1), 2)
        reduced.patchCount = max(1, Int((Self.reducedShare * share * blocks).rounded(.up)))
        reduced.dilateRadius = Int((Double(dilateRadius) / f).rounded())
        reduced.featherSigma = featherSigma / Float(factor)
        return reduced
    }

    /// See `reduced(by:)`.
    static let reducedShare = 0.65
}
