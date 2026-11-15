import Foundation
import Metal
import PixelEngine

/// Scope menu › Selected Mask Only: the histogram, waveform, parade and
/// vectorscope measured over the selected local adjustment's mask, each
/// pixel weighted by the mask's value there.
///
/// The mask comes from the renderer's own mask overlay in its "White on
/// Black" mode, rendered at the analysis render's size into the analysis
/// texture pool (so nothing on screen or kept for the scopes is touched),
/// then read back with the picture and measured on the CPU
/// (`MaskedScopeAccumulator`). While the mask overlay shows, the analysis
/// render carries its tint, so the picture is rendered again without it.
/// Only while the option is on and a mask is selected; otherwise the
/// scopes are measured on the GPU exactly as before.
extension EditorModel {
    /// The local whose mask the scopes are limited to, or nil when they
    /// describe the whole picture.
    var scopeMaskIndex: Int? {
        guard ScopeSettings.shared.selectedMaskOnly, let i = selectedLocalIndex,
              i < min(parameters.locals.count, LocalAdjustment.maximumCount) else { return nil }
        return i
    }

    /// Measures the visible scope over the selected mask. False when the
    /// option is off, no mask is selected or anything fails, and the
    /// caller then measures the whole picture as usual.
    func measureMaskedScopes(from analysis: MTLTexture) -> Bool {
        guard let index = scopeMaskIndex, let session, let pipeline, let gpu = gpuContext else { return false }
        let wanted: MaskedScopeAccumulator.Wanted
        switch scope {
        case .histogram: wanted = .histogram
        case .waveform, .parade: wanted = .waveform
        case .vectorscope: wanted = .vectorscope
        case .waveformVectorscope: wanted = [.waveform, .vectorscope]
        case .histogramVectorscope: wanted = [.histogram, .vectorscope]
        }

        let quads = max(previewQuads, 4)   // as renderPreview makes the analysis render
        let parameters = renderParameters
        defer { session.releasePooledTextures(in: .analysis) }
        // Each render is read back before the next: they share the
        // analysis pool's storage.
        func readBack(_ output: RenderOutput) -> [Float]? {
            try? session.withTexturePool(.analysis) {
                let texture = try pipeline.render(session, scale: .binned(quads: quads),
                                                  parameters: parameters, output: output)
                guard texture.width == analysis.width, texture.height == analysis.height else { return nil }
                return ScopeReadback.rgbaFloats(texture, commandQueue: gpu.commandQueue)
            }
        }

        // The picture: the analysis render itself, unless the mask overlay
        // is showing and tinted it, when it is made again without one.
        var clean = displayOutput
        clean.rawClipMask = false
        let pixels: [Float]?
        if clean.maskOverlay != nil {
            clean.maskOverlay = nil
            clean.maskOverlayStyle = .standard
            pixels = readBack(clean)
        } else {
            pixels = ScopeReadback.rgbaFloats(analysis, commandQueue: gpu.commandQueue)
        }
        guard let pixels else { return false }

        var maskOutput = RenderOutput.edrDisplay(headroom: 1)
        maskOutput.maskOverlay = index
        maskOutput.maskOverlayStyle = MaskOverlayStyle(mode: .whiteOnBlack)
        guard let maskPixels = readBack(maskOutput) else { return false }

        let count = analysis.width * analysis.height
        var weights = [Float](repeating: 0, count: count)
        for p in 0..<count {
            weights[p] = MaskedScopeAccumulator.maskWeight(fromOverlay: maskPixels[p * 4], maskPixels[p * 4 + 1],
                                                           maskPixels[p * 4 + 2])
        }
        let result = MaskedScopeAccumulator.accumulate(rgba: pixels, weights: weights, width: analysis.width,
                                                       height: analysis.height, wanted: wanted)
        if wanted.contains(.histogram) { histogram = result.histogram }
        if wanted.contains(.waveform) { waveform = result.waveform }
        if wanted.contains(.vectorscope) { vectorscope = result.vectorscope }
        return true
    }
}
