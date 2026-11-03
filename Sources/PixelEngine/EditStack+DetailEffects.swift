import Foundation

/// How the finer detail, lens and effects controls (DetailEffects.swift)
/// are stored. Each is written only when it differs from its default, so
/// an edit that never touched them encodes byte for byte as before, and an
/// edit from before they existed reads back with all of them at default.
extension EditStack {
    mutating func storeDetailEffects(from p: EditParameters) {
        if p.sharpenDetail != SharpenRefinement.neutralDetail { modules.sharpen?.detail = p.sharpenDetail }
        if p.sharpenMasking != SharpenRefinement.neutralMasking { modules.sharpen?.masking = p.sharpenMasking }
        if !p.noiseDetail.isNeutral { modules.denoise?.detail = p.noiseDetail }
        if !p.defringeHues.isStandard { modules.defringe?.hues = p.defringeHues }
        if p.manualVignettingMidpoint != ManualVignettingShape.neutralMidpoint {
            modules.lens?.vignettingMidpoint = p.manualVignettingMidpoint
        }
        modules.lens?.autoCA = p.autoCA
        modules.lens?.manualProfile = p.lensProfile
        modules.vignette = p.postCropVignette.isActive ? p.postCropVignette : nil
        modules.grain = p.grain.isActive ? p.grain : nil
    }

    /// Values from a file are clamped to what the controls allow, as the
    /// other modules' geometry is: a hand-edited number must not be able to
    /// blow up a render.
    func restoreDetailEffects(into p: inout EditParameters) {
        // Fields that live inside another module follow that module: when
        // it is absent (a preset without Detail, say) `p` keeps what the
        // defaults gave it, as the module's own values do.
        if let sharpen = modules.sharpen {
            p.sharpenDetail = (sharpen.detail ?? SharpenRefinement.neutralDetail).finiteOr(1).detailClamped(0, 1)
            p.sharpenMasking = (sharpen.masking ?? SharpenRefinement.neutralMasking).finiteOr(0).detailClamped(0, 1)
        }
        if let denoise = modules.denoise { p.noiseDetail = (denoise.detail ?? .neutral).sanitized }
        p.defringeHues = modules.defringe?.hues.map(\.sanitized) ?? .standard
        if let lens = modules.lens {
            p.manualVignettingMidpoint = (lens.vignettingMidpoint ?? ManualVignettingShape.neutralMidpoint)
                .finiteOr(0.5).detailClamped(0, 1)
            p.autoCA = lens.autoCA?.sanitized
            p.lensProfile = lens.manualProfile.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        }
        p.postCropVignette = modules.vignette?.sanitized ?? .off
        p.grain = modules.grain?.sanitized ?? .off
    }
}

extension Float {
    func finiteOr(_ fallback: Float) -> Float { isFinite ? self : fallback }
}
