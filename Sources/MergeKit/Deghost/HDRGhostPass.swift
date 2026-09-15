// The deghosting pass of an HDR merge: before any frame is merged, every
// frame is opened once more and looked at in quarter size, to find where
// each one shows something that moved (docs/PhotoMerge.md section 3,
// stage 5; the method is described in Shaders/MergeDeghost.metal).

import Foundation
import PixelEngine
import RawCore

extension HDRMerger {
    /// What the deghosting pass hands the merge.
    struct GhostPass {
        /// One per frame, in the analysis's order, the reference frame's too
        /// (it is left out of a moving area another frame is the source of);
        /// nil for frames left out of the merge.
        let masks: [HDRGhostMask?]
        /// Each frame's levels (`HDRMerger.levels`), so the merge needn't
        /// work them out again; nil for frames left out of the merge.
        let levels: [HDRFrameLevels?]
    }

    /// Finds every frame's ghost mask (`HDRGhostDetector` has the steps).
    ///
    /// Memory stays flat however many frames there are: each frame is
    /// opened, measured at quarter size and let go, keeping only 11 bytes per
    /// quarter-size pixel on the CPU until its movement is found; what
    /// reaches the merge is 1 byte per quarter-size pixel per frame. The
    /// detector's GPU textures are freed when this returns, before the merge
    /// allocates its own.
    ///
    /// **With Auto Align** every frame's measurement is warped onto the
    /// reference frame before it is compared (`HDRGhostDetector.measure`), so
    /// a frame's brightness and colour are compared with the same part of the
    /// scene in the others, not with whatever sits at the same pixel. Frames Auto
    /// Align left out aren't looked at.
    ///
    /// - Parameters:
    ///   - alignment: what Auto Align decided, or nil with it off.
    ///   - progress: the share of this pass done (0...1) and a stage name.
    func findGhosts(_ frames: [HDRMergeFrame], reference: Int, width: Int, height: Int,
                    alignment: HDRMergeAlignment.Plan?, settings: HDRDeghostSettings, feather: HDRClipFeather,
                    report: inout HDRMergeReport, progress: (Double, String) -> Void) throws -> GhostPass {
        let detector = try Self.gpuStep {
            try HDRGhostDetector(gpu: gpu, width: width, height: height, feather: feather,
                                 referenceIndex: reference, referenceEV: frames[reference].relativeEV)
        }
        let merged = frames.indices.filter { alignment?.includes($0) ?? true }
        var measurements: [HDRGhostMeasurement?] = []
        var levels: [HDRFrameLevels?] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard merged.contains(index) else {
                measurements.append(nil)
                levels.append(nil)
                continue
            }
            progress(0.7 * Double(index) / Double(frames.count),
                     "Looking for movement in photo \(index + 1) of \(frames.count)")
            let name = frame.url.lastPathComponent
            try autoreleasepool {
                let file = try report.time("Decode \(name) for deghosting") { try Self.open(frame.url) }
                guard case .bayer = file.summary.cfaPattern else { throw HDRMergeError.unsupportedSource(fileName: name) }
                guard file.summary.width == width, file.summary.height == height else { throw HDRMergeError.differentSizes }
                let frameLevels = try Self.gpuStep { try Self.levels(for: file, gpu: gpu) }
                let measurement = try report.time("Measure \(name) for deghosting") {
                    try Self.gpuStep {
                        try detector.measure(file, index: index, levels: frameLevels, relativeEV: frame.relativeEV,
                                             movingToReference: alignment?.homographies[index],
                                             isDarkest: index == merged.last)
                    }
                }
                report.sampleMemory(gpu.device)
                measurements.append(measurement)
                levels.append(frameLevels)
            }
        }
        detector.finishMeasuring()

        var flagged: [Double] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard index != reference, let measurement = measurements[index] else {
                flagged.append(0)
                continue
            }
            progress(0.7 + 0.15 * Double(index) / Double(frames.count),
                     "Comparing photo \(index + 1) of \(frames.count)")
            flagged.append(try report.time("Find movement in \(frame.url.lastPathComponent)") {
                try Self.gpuStep { try detector.findMovement(measurement, index: index, settings: settings) }
            })
        }
        measurements.removeAll()

        var masks: [HDRGhostMask?] = []
        var fractions: [Double] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard merged.contains(index) else {
                masks.append(nil)
                fractions.append(0)
                continue
            }
            progress(0.85 + 0.15 * Double(index) / Double(frames.count),
                     "Masking movement in photo \(index + 1) of \(frames.count)")
            let mask = try report.time("Mask movement in \(frame.url.lastPathComponent)") {
                try Self.gpuStep { try detector.mask(index: index, settings: settings) }
            }
            report.sampleMemory(gpu.device)
            masks.append(mask)
            fractions.append(mask.maskedFraction)
        }
        report.ghostFlaggedFractions = flagged
        report.ghostMaskedFractions = fractions
        return GhostPass(masks: masks, levels: levels)
    }
}
