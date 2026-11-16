import Foundation
import Metal
import PixelEngine

/// Scope menu › Selected Mask Only: the histogram, waveform, parade and
/// vectorscope measured over the selected local adjustment's mask, each
/// pixel weighted by the mask's value there.
///
/// The mask comes from the renderer's own mask overlay in its "White on
/// Black" mode, rendered at the analysis render's size into the analysis
/// texture pool (so nothing on screen or kept for the scopes is touched).
/// While the mask overlay shows, the analysis render carries its tint, so
/// the picture is rendered again without it. Both are then copied on the
/// GPU and read back and measured off the main thread
/// (`MaskedScopeReadback`, `MaskedScopeAccumulator`); the scopes update
/// when that finishes, unless a newer measurement was asked for since.
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

    /// Starts measuring the visible scope over the selected mask; the
    /// result lands in `histogram` / `waveform` / `vectorscope` shortly
    /// after (`maskedScopeTask`). False when the option is off, no mask
    /// is selected or anything fails, and the caller then measures the
    /// whole picture as usual.
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
        // The mask must be the current one, never a brush slice a
        // deferring render kept while its whole redraw runs off the main
        // thread: these renders bring every slice up to date, whoever
        // calls (the redraw still landing then asks for the render that
        // measures the scopes again, BrushMaskSet.apply).
        let defersBrushRedraws = session.defersBrushRedraws
        session.defersBrushRedraws = false
        defer {
            session.defersBrushRedraws = defersBrushRedraws
            session.releasePooledTextures(in: .analysis)
        }
        func render(_ output: RenderOutput) -> MTLTexture? {
            try? session.withTexturePool(.analysis) {
                let texture = try pipeline.render(session, scale: .binned(quads: quads),
                                                  parameters: parameters, output: output)
                guard texture.width == analysis.width, texture.height == analysis.height else { return nil }
                return texture
            }
        }

        // The picture: the analysis render itself, unless the mask overlay
        // is showing and tinted it, when it is made again without one.
        // Each is copied before the next render can reuse its storage.
        let queue = gpu.commandQueue
        var clean = displayOutput
        clean.rawClipMask = false
        let picture: ScopeTextureCopy?
        if clean.maskOverlay != nil {
            clean.maskOverlay = nil
            clean.maskOverlayStyle = .standard
            picture = render(clean).flatMap { ScopeTextureCopy($0, commandQueue: queue) }
        } else {
            picture = ScopeTextureCopy(analysis, commandQueue: queue)
        }
        guard let picture else { return false }

        var maskOutput = RenderOutput.edrDisplay(headroom: 1)
        maskOutput.maskOverlay = index
        maskOutput.maskOverlayStyle = MaskOverlayStyle(mode: .whiteOnBlack)
        guard let mask = render(maskOutput).flatMap({ ScopeTextureCopy($0, commandQueue: queue) }),
              let readback = MaskedScopeReadback(picture: picture, mask: mask, wanted: wanted) else { return false }

        // Read back and measured off the main thread; shown only if no
        // other measurement started meanwhile and the same mask is still
        // the one the scopes are limited to, on the same photo.
        maskedScopeGeneration &+= 1
        let generation = maskedScopeGeneration
        let sessionID = ObjectIdentifier(session)
        maskedScopeTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { readback.measure() }.value
            guard let self, let result, generation == self.maskedScopeGeneration,
                  self.session.map(ObjectIdentifier.init) == sessionID, self.scopeMaskIndex == index else { return }
            if wanted.contains(.histogram) { self.histogram = result.histogram }
            if wanted.contains(.waveform) { self.waveform = result.waveform }
            if wanted.contains(.vectorscope) { self.vectorscope = result.vectorscope }
        }
        return true
    }
}
