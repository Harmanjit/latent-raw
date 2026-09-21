import Foundation
import CoreGraphics
import PixelEngine

/// Find Blemishes (docs/Retouch.md §7): the classical blob detector over
/// each enabled face, weighted by its skin mask, so a spot on skin
/// becomes a heal patch and a nostril or an eye corner does not. Wave 2
/// (W2-T) fills this in; until then nothing is found.
public enum BlemishFinder {
    /// BlobDetector over each enabled face's box with the skin slice as
    /// weight; raw-grid HealPatches (cap 64), excluding blobs inside any
    /// of `existing` (heals + dust).
    public static func find(in render: TouchUpAnalysis.Render, masks: TouchUpMaskSet, touchUp: TouchUp,
                            existing: [HealPatch], session: ImageSession, pipeline: RenderPipeline,
                            parameters: EditParameters) -> [HealPatch] {
        []
    }
}
