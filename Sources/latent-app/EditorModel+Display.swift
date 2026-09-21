import SwiftUI
import UniformTypeIdentifiers
import PixelEngine

extension EditorModel {
    // MARK: - Display

    /// The ceiling the tone curve actually gets: the potential headroom,
    /// capped (see `DisplayHeadroom`). The viewport fits it to whatever
    /// the screen shows at the moment, so the look stays put as the
    /// brightness changes.
    var effectiveHeadroom: Float {
        DisplayHeadroom.rendered(potential: SecondaryPreview.renderPotential(main: displayHeadroom, secondary: secondaryDisplayHeadroom),
                                 hdrDisplayEnabled: hdrDisplayEnabled)
    }
    /// Whether the viewport is rendered with room above SDR white, so the
    /// histogram's "above SDR white" readout means something.
    var rendersAboveSDRWhite: Bool { displayOutput.headroom > 1 }
    var displayHasHeadroom: Bool { displayHeadroom > 1.001 }

    /// What the pipeline renders for the screen: linear Display P3, so
    /// the presenter can hand it to the EDR layer untouched. While a local
    /// is selected and its mask should be visible, the overlay index rides
    /// along — a display setting, never part of the edit. So do the dust
    /// visualisation and the skin-mask tint: exports never build this.
    var displayOutput: RenderOutput {
        // Proofing simulates an SDR file, so the display headroom is
        // dropped to 1 while it's on: an EDR highlight can't be in a JPEG.
        var output = RenderOutput.edrDisplay(headroom: proofLUT == nil ? effectiveHeadroom : 1)
        if showMaskOverlay || isDraggingMask, let i = selectedLocalIndex, i < parameters.locals.count {
            output.maskOverlay = i
        }
        output.proof = proofLUT
        output.gamutWarning = gamutWarning
        output.spotVisualisation = dustVisualisation
        output.touchUpOverlay = touchUpOverlayWanted
        return output
    }

    /// The Metal view moved to a screen with a different potential
    /// headroom. Renders again only if that changes the ceiling the
    /// pipeline uses: past the cap, or with HDR display off or proofing
    /// on, it doesn't.
    func displayHeadroomDidChange(to headroom: CGFloat) {
        guard headroom != displayHeadroom else { return }
        let renderedBefore = displayOutput.headroom
        displayHeadroom = headroom
        if hasImage && displayOutput.headroom != renderedBefore { rerender() }
    }

    /// The surround grey, in the drawable's linear encoding. 0.12 in sRGB
    /// terms — Lightroom's mid-dark grey — is about 0.0137 linear.
    var backgroundLevel: Float { AppPreferences.shared.surroundLinear }

    // MARK: - Soft proofing

    /// Builds the proof table (a few ms for a matrix space, tens for an
    /// ICC profile) and re-renders. Off = no table at all, so proofing
    /// costs nothing when it isn't on.
    func rebuildProof() {
        guard proofEnabled else {
            proofLUT = nil; proofStatus = ""; rerender(); return
        }
        do {
            let lut = try SoftProofLUT.build(proofTarget)
            proofLUT = lut
            proofStatus = String(format: "%@ · %.1f%% of colours out of gamut",
                                 proofTarget.displayName, lut.outOfGamutFraction * 100)
        } catch {
            proofLUT = nil
            proofStatus = "Proof failed: \(error)"
        }
        rerender()
    }

    func chooseProofProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data,
                                     UTType(filenameExtension: "icm") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: "/Library/ColorSync/Profiles")
        panel.message = "Choose an ICC profile to proof against (printer, paper, display)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        proofTarget = .icc(url)
        proofEnabled = true
    }

    // MARK: - Scopes

    /// Measures the selected scope, at most every `scopeInterval`. A slider
    /// drag renders on every mouse event; the scope only has to keep up
    /// with the eye, and each measurement is a GPU round trip plus a
    /// redraw of the scope view. The last change of a burst is always
    /// measured, just up to one interval late.
    func updateScopes() {
        guard analysisTexture != nil, measuresScopes else { return }
        let now = ContinuousClock.now
        if let last = lastScopeMeasurement, now - last < Self.scopeInterval {
            guard pendingScopeMeasurement == nil else { return }
            pendingScopeMeasurement = Task { [weak self] in
                try? await Task.sleep(until: last + Self.scopeInterval, clock: .continuous)
                guard let self, !Task.isCancelled else { return }
                self.pendingScopeMeasurement = nil
                self.measureScopes()
            }
            return
        }
        pendingScopeMeasurement?.cancel()
        pendingScopeMeasurement = nil
        measureScopes()
    }

    private static let scopeInterval: Duration = .milliseconds(100)

    /// Measures the selected scope from the analysis texture. The texture
    /// is linear EDR; the kernels encode it so the shapes are the familiar
    /// ones and anything above 1.0 counts as SDR clipping.
    private func measureScopes() {
        guard let analysisTexture else { return }
        lastScopeMeasurement = .now
        switch scope {
        case .histogram:
            histogram = histogramCalculator?.compute(from: analysisTexture, inputIsLinear: true)
        case .waveform:
            waveform = scopeCalculator?.computeWaveform(from: analysisTexture, inputIsLinear: true)
        case .vectorscope:
            vectorscope = scopeCalculator?.computeVectorscope(from: analysisTexture, inputIsLinear: true)
        }
    }
}
