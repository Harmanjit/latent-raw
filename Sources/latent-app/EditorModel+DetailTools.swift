import SwiftUI
import simd
import RawCore
import LensKit
import PixelEngine

/// The Lens Corrections and Detail panels' actions that are more than a
/// slider: picking a lens profile, Remove Chromatic Aberration, and the
/// defringe eyedropper. Each changes `parameters`, so it lands in the edit
/// history and Undo takes it back like any slider.
extension EditorModel {
    // MARK: - Lens profile

    /// The Lensfun model this photo's corrections come from, if any.
    var activeLensProfileName: String? { session?.lensCorrection(for: parameters)?.profileName }

    /// The profile remembered for every photo from this camera and lens, if
    /// one was saved ("Use for All Photos From This Lens").
    var rememberedLensProfile: String? {
        guard let key = session?.lensProfileKey else { return nil }
        return LensProfileOverrides.model(for: key)
    }

    /// The lenses the profile picker offers for the open photo.
    var lensProfileChoices: (fitting: [LensfunLens], others: [LensfunLens]) {
        guard let summary = session?.file.summary else { return ([], []) }
        return LensProfileOverrides.choices(cameraMake: summary.cameraMake, cameraModel: summary.cameraModel)
    }

    /// Picks a profile for this photo, or nil for the automatic one.
    func chooseLensProfile(_ model: String?) {
        guard hasImage, session?.lensCorrectionAlreadyApplied != true else { return }
        parameters.lensProfile = model
    }

    /// Remembers this photo's profile choice for its camera and lens in the
    /// catalog, so every photo from that lens opens with it; the automatic
    /// choice clears what was remembered. The photo's own choice then goes
    /// back to automatic, which now resolves to the same profile.
    func rememberLensProfileForThisLens() {
        guard let session, let remember = onRememberLensProfile else { return }
        remember(parameters.lensProfile, session.lensProfileKey)
    }

    /// The catalog's choices changed (another folder opened, or a choice
    /// was saved or undone): resolve the open photo's profile again.
    func lensProfileDefaultsDidChange() {
        guard let session else { return }
        if session.refreshLensProfile() { rerender() }
        objectWillChange.send()
    }

    // MARK: - Remove Chromatic Aberration

    /// Turns the profile-free correction on (measuring the photo) or off.
    /// The patches are rendered here, the fit runs off the main thread, and
    /// the result is applied only if the same photo is still open.
    func setRemoveChromaticAberration(_ on: Bool) {
        guard hasImage else { return }
        guard on else {
            parameters.autoCA = nil
            lensToolStatus = ""
            return
        }
        guard let session, let pipeline, !measuringChromaticAberration else { return }
        let tiles: [ChromaticAberrationEstimator.Tile]
        do {
            tiles = try ChromaticAberrationEstimator.captureTiles(session: session, pipeline: pipeline,
                                                                  parameters: parameters)
        } catch {
            reportFailure("Measuring chromatic aberration", error)
            return
        }
        measuringChromaticAberration = true
        lensToolStatus = "Measuring colour fringes…"
        let photo = sourceURL
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ChromaticAberrationEstimator.estimate(tiles: tiles)
            }.value
            guard let self else { return }
            self.measuringChromaticAberration = false
            guard self.sourceURL == photo, self.hasImage else { return }
            if let result {
                self.parameters.autoCA = result
                self.lensToolStatus = String(format: "Red %+.3f%%, blue %+.3f%% against green",
                                             result.red * 100, result.blue * 100)
            } else {
                self.lensToolStatus = "Not enough sharp edges to measure: nothing changed"
            }
        }
    }

    // MARK: - Defringe eyedropper

    /// Arms the eyedropper; the next click on the image picks a fringe
    /// colour. Other image tools are turned off while it is armed.
    func armDefringePicker() {
        guard hasImage else { return }
        disarmTools()
        defringePickerActive = true
        lensToolStatus = "Click a purple or green fringe on the image"
    }

    /// The eyedropper's click, in drawable pixels. Reads the picture
    /// around the point as it is before defringing and moves the matching
    /// hue range (purple or green) to the most colourful pixel's hue,
    /// turning that range's amount on if it was off.
    func defringePick(atScreen screen: CGPoint) {
        defringePickerActive = false
        guard let session, let pipeline, let gpu = gpuContext, sensorSize.width > 0 else { return }
        let point = sensorNormalized(screen)
        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { lensToolStatus = ""; return }
        let size = 15
        let x = Int(point.x * Float(sensorSize.width)) - size / 2
        let y = Int(point.y * Float(sensorSize.height)) - size / 2
        var p = renderParameters
        p.defringePurple = 0
        p.defringeGreen = 0
        do {
            let texture = try session.withTexturePool(.analysis) {
                try pipeline.render(session, scale: .region(x: x, y: y, width: size, height: size),
                                    parameters: p, output: .file(.sRGB))
            }
            let pixels = try TextureReadback.float16Pixels(of: texture, gpu: gpu)
            guard let hue = Self.fringeHue(pixels) else {
                lensToolStatus = "No colour fringe there: try a purple or green edge"
                return
            }
            let picked = parameters.defringeHues.picking(hue: hue)
            parameters.defringeHues = picked.ranges
            switch picked.band {
            case .purple:
                if parameters.defringePurple == 0 { parameters.defringePurple = 0.5 }
                lensToolStatus = String(format: "Purple range centred on %.0f°", hue)
            case .green:
                if parameters.defringeGreen == 0 { parameters.defringeGreen = 0.5 }
                lensToolStatus = String(format: "Green range centred on %.0f°", hue)
            }
        } catch {
            reportFailure("Picking a fringe colour", error)
        }
    }

    /// The hue (degrees) of the most saturated pixels of an encoded RGBA
    /// half-float patch, as a circular mean of the five most saturated, in
    /// linear light like the defringe shader. Nil when nothing is coloured.
    static func fringeHue(_ rgba: [Float16]) -> Float? {
        var candidates: [(sat: Float, hue: Float)] = []
        for i in stride(from: 0, to: rgba.count - 3, by: 4) {
            let c = SIMD3<Float>(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
            let lin = SIMD3<Float>(pow(max(c.x, 0), 2.2), pow(max(c.y, 0), 2.2), pow(max(c.z, 0), 2.2))
            let mx = lin.max(), mn = lin.min()
            guard mx > 1e-4 else { continue }
            let d = mx - mn
            let sat = d / mx
            guard sat > 0.15, d > 1e-5 else { continue }
            var h: Float
            if mx == lin.x { h = (lin.y - lin.z) / d }
            else if mx == lin.y { h = 2 + (lin.z - lin.x) / d }
            else { h = 4 + (lin.x - lin.y) / d }
            h = (h * 60).truncatingRemainder(dividingBy: 360)
            if h < 0 { h += 360 }
            candidates.append((sat, h))
        }
        let top = candidates.sorted { $0.sat > $1.sat }.prefix(5)
        guard !top.isEmpty else { return nil }
        var v = SIMD2<Float>(0, 0)
        for c in top {
            let r = c.hue * .pi / 180
            v += SIMD2(cos(r), sin(r)) * c.sat
        }
        var hue = atan2(v.y, v.x) * 180 / .pi
        if hue < 0 { hue += 360 }
        return hue
    }

    // MARK: - Sharpening mask preview

    /// The Masking slider's knob went down (with or without Option) or up.
    func sharpenMaskingPressed(_ pressed: Bool, option: Bool) {
        sharpenMaskPreview = pressed && option && hasImage
    }
}
