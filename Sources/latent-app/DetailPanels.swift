import SwiftUI
import LensKit
import PixelEngine

/// A labelled slider row like the adjustment panel's own: title, value
/// field, a slider that resets on double-click, and a tooltip saying what
/// the control does.
struct DetailSliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.2f"
    var scale: Float = 1
    var defaultValue: Float = 0
    let help: String
    /// What VoiceOver calls it, when the title alone is ambiguous (two
    /// "Detail" sliders in one panel).
    var label: String? = nil
    var onPress: ((_ pressed: Bool, _ option: Bool) -> Void)? = nil

    var body: some View {
        let shown = SliderValueFormat(printf: format, scale: scale)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The field and slider are both named, so VoiceOver skips this.
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: $value, in: range, format: shown, label: label ?? title)
            }
            ResettableSlider(value: $value, in: range, label: label ?? title, format: shown, onPress: onPress) {
                value = defaultValue
            }
            .help(help + " Double-click to reset.")
        }
    }
}

/// Section heading inside a panel, as `ContentView.disclosureLabel`.
struct DetailSubheading: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Detail panel: demosaic, sharpening (with Detail and Masking) and
/// noise reduction (with Detail, Contrast and Smoothness).
struct DetailPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Demosaicing only exists for a raw's mosaic.
            if !model.isRenderedImage {
                Picker("Demosaic", selection: $model.parameters.demosaic) {
                    ForEach(DemosaicMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Demosaic")
                .help("How full-resolution renders turn the sensor's colour mosaic into pixels")

                Text("Only affects full-resolution renders — export and 100% zoom. The fit-to-window preview bins Bayer quads and never interpolates.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DetailSubheading(title: "Sharpening")
            DetailSliderRow(title: "Amount", value: $model.parameters.sharpenAmount, range: 0...2,
                            help: "How strongly edges are sharpened. 0 is off.")
            DetailSliderRow(title: "Radius", value: $model.parameters.sharpenRadius, range: 0.5...3,
                            format: "%.1f px", defaultValue: 1.0,
                            help: "The size of the detail sharpened, in sensor pixels.")
            DetailSliderRow(title: "Threshold", value: $model.parameters.sharpenThreshold, range: 0...0.1,
                            format: "%.3f", defaultValue: 0.01,
                            help: "Detail fainter than this (noise, grain) is left unsharpened.")
            DetailSliderRow(title: "Detail", value: $model.parameters.sharpenDetail, range: 0...1,
                            format: "%.0f", scale: 100, defaultValue: SharpenRefinement.neutralDetail,
                            help: "Lower values hold back the bright and dark halos sharpening leaves along edges; 100 is plain unsharp masking.",
                            label: "Sharpening detail")
            DetailSliderRow(title: "Masking", value: $model.parameters.sharpenMasking, range: 0...1,
                            format: "%.0f", scale: 100, defaultValue: SharpenRefinement.neutralMasking,
                            help: "Higher values sharpen only edges, leaving smooth areas such as sky and skin alone. Hold Option while dragging to see the mask: white is sharpened.",
                            label: "Sharpening masking",
                            onPress: { pressed, option in model.sharpenMaskingPressed(pressed, option: option) })
            if model.sharpenMaskPreview {
                Text("Showing the sharpening mask: white areas are sharpened.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            DetailSubheading(title: "Noise Reduction")
            DetailSliderRow(title: "Luminance", value: $model.parameters.denoiseLuminance, range: 0...1,
                            help: "Smooths brightness noise (the grainy speckle). 0 is off.")
            DetailSliderRow(title: "Detail", value: $model.parameters.noiseDetail.luminanceDetail, range: 0...1,
                            format: "%.0f", scale: 100, defaultValue: 0.5,
                            help: "Higher keeps more fine detail from the luminance smoothing, at the cost of some noise.",
                            label: "Luminance noise detail")
                .disabled(model.parameters.denoiseLuminance == 0)
            DetailSliderRow(title: "Contrast", value: $model.parameters.noiseDetail.luminanceContrast, range: 0...1,
                            format: "%.0f", scale: 100,
                            help: "Puts back texture and local contrast the luminance smoothing flattened, without the noise.",
                            label: "Luminance noise contrast")
                .disabled(model.parameters.denoiseLuminance == 0)
            DetailSliderRow(title: "Colour", value: $model.parameters.denoiseColor, range: 0...1,
                            help: "Removes coloured speckles. 0 is off.")
            DetailSliderRow(title: "Detail", value: $model.parameters.noiseDetail.colourDetail, range: 0...1,
                            format: "%.0f", scale: 100, defaultValue: 0.5,
                            help: "Higher keeps thin coloured edges crisp; lower cleans colour noise harder.",
                            label: "Colour noise detail")
                .disabled(model.parameters.denoiseColor == 0)
            DetailSliderRow(title: "Smoothness", value: $model.parameters.noiseDetail.colourSmoothness, range: 0...1,
                            format: "%.0f", scale: 100,
                            help: "Evens out larger blotches of colour (mottling) that the colour slider is too fine to reach.",
                            label: "Colour noise smoothness")
                .disabled(model.parameters.denoiseColor == 0)
            Text("Judge both at 100% zoom; the fit-to-window preview is scaled to match but hides fine grain.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.hasImage)
    }
}

/// The Lens Corrections panel: the profile (automatic or picked), its
/// three switches, Remove Chromatic Aberration, the manual sliders and
/// defringe with its hue ranges and eyedropper.
struct LensCorrectionsPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.lensProfileDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A rendered file has no lens profile corrections to apply.
            if !model.isRenderedImage {
                profilePicker
                Toggle("Distortion", isOn: $model.parameters.lensDistortion)
                    .help("Straightens the lens's barrel or pincushion distortion, from the profile")
                Toggle("Chromatic aberration", isOn: $model.parameters.lensTCA)
                    .help("Lines up red and blue with green using the profile's measurements")
                Toggle("Vignetting", isOn: $model.parameters.lensVignetting)
                    .help("Brightens the corners the lens darkened, from the profile")
            }
            Toggle("Remove chromatic aberration (automatic)", isOn: Binding(
                get: { model.parameters.autoCA != nil },
                set: { model.setRemoveChromaticAberration($0) }))
                .help("Measures the colour fringes on this photo and lines up red and blue with green, without a profile. Replaces the profile's correction while on.")
                .disabled(model.measuringChromaticAberration)
            if !model.lensToolStatus.isEmpty {
                Text(model.lensToolStatus)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailSubheading(title: "Manual")
            DetailSliderRow(title: "Distortion", value: $model.parameters.manualDistortion, range: -0.1...0.1,
                            format: "%+.3f", help: "Corrects distortion by hand: negative pulls a bulging (barrel) picture in.")
            DetailSliderRow(title: "Vignetting", value: $model.parameters.manualVignetting, range: -1...1,
                            format: "%+.2f", help: "Brightens (positive) or darkens (negative) the corners of the whole frame.")
            DetailSliderRow(title: "Midpoint", value: $model.parameters.manualVignettingMidpoint, range: 0...1,
                            format: "%.0f", scale: 100, defaultValue: ManualVignettingShape.neutralMidpoint,
                            help: "How far in from the corners manual vignetting reaches: lower spreads it towards the centre.")
                .disabled(model.parameters.manualVignetting == 0)

            DetailSubheading(title: "Defringe")
            DetailSliderRow(title: "Purple", value: $model.parameters.defringePurple, range: 0...1,
                            help: "Removes purple and magenta fringes along high-contrast edges.")
            HueRangeRow(title: "Purple hue", low: $model.parameters.defringeHues.purpleLow,
                        high: $model.parameters.defringeHues.purpleHigh, limits: DefringeHueRanges.purpleLimits,
                        reset: {
                            model.parameters.defringeHues.purpleLow = DefringeHueRanges.standard.purpleLow
                            model.parameters.defringeHues.purpleHigh = DefringeHueRanges.standard.purpleHigh
                        })
                .disabled(model.parameters.defringePurple == 0)
            DetailSliderRow(title: "Green", value: $model.parameters.defringeGreen, range: 0...1,
                            help: "Removes green and cyan fringes along high-contrast edges.")
            HueRangeRow(title: "Green hue", low: $model.parameters.defringeHues.greenLow,
                        high: $model.parameters.defringeHues.greenHigh, limits: DefringeHueRanges.greenLimits,
                        reset: {
                            model.parameters.defringeHues.greenLow = DefringeHueRanges.standard.greenLow
                            model.parameters.defringeHues.greenHigh = DefringeHueRanges.standard.greenHigh
                        })
                .disabled(model.parameters.defringeGreen == 0)
            Button {
                if model.defringePickerActive { model.defringePickerActive = false } else { model.armDefringePicker() }
            } label: {
                Label(model.defringePickerActive ? "Click a Fringe…" : "Pick Fringe Colour",
                      systemImage: "eyedropper")
            }
            .controlSize(.small)
            .help("Click a coloured fringe on the image: the purple or green hue range moves to its colour")
            .accessibilityLabel("Pick fringe colour")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!model.hasImage)
    }

    /// Automatic, or a lens picked from the database for this photo, plus
    /// remembering the choice for every photo from this lens.
    @ViewBuilder private var profilePicker: some View {
        if model.hasImage, model.session?.lensCorrectionAlreadyApplied != true {
            let choices = model.lensProfileChoices
            HStack {
                Menu {
                    Button("Automatic") { model.chooseLensProfile(nil) }
                    if !choices.fitting.isEmpty {
                        Section("Fits this camera") { lensMenu(choices.fitting) }
                    }
                    if !choices.others.isEmpty {
                        Section(choices.fitting.isEmpty ? "All lenses" : "Other mounts") { lensMenu(choices.others) }
                    }
                } label: {
                    Text(model.parameters.lensProfile ?? "Automatic profile")
                        .lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton)
                .help("Pick the lens profile by hand when the automatic match is wrong or missing")
                .accessibilityLabel("Lens profile")
                .accessibilityValue(model.parameters.lensProfile ?? "Automatic")
            }
            let remembered = model.rememberedLensProfile
            if model.parameters.lensProfile != nil || remembered != nil {
                Button(model.parameters.lensProfile == nil ? "Forget Profile for This Lens"
                                                           : "Use for All Photos From This Lens") {
                    model.rememberLensProfileForThisLens()
                }
                .controlSize(.small)
                .disabled(model.parameters.lensProfile == remembered && model.parameters.lensProfile != nil)
                .help(model.parameters.lensProfile == nil
                      ? "Go back to the automatic match for every photo from this camera and lens (\(remembered ?? ""))"
                      : "Remember this profile in the catalog for every photo from this camera and lens")
            }
        }
    }

    /// One button per lens, grouped by maker.
    @ViewBuilder private func lensMenu(_ lenses: [LensfunLens]) -> some View {
        let makers = Array(Set(lenses.map(\.maker))).sorted { $0.lowercased() < $1.lowercased() }
        ForEach(makers, id: \.self) { maker in
            Menu(maker) {
                ForEach(lenses.filter { $0.maker == maker }, id: \.model) { lens in
                    Button(lens.model) { model.chooseLensProfile(lens.model) }
                }
            }
        }
    }
}

/// A hue range as two sliders, low and high, over a strip of the hues
/// they span, so the range can be read as colours.
struct HueRangeRow: View {
    let title: String
    @Binding var low: Float
    @Binding var high: Float
    let limits: ClosedRange<Float>
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Spacer()
                Text(String(format: "%.0f°–%.0f°", low, high))
                    .font(.system(size: SliderValueField.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            GeometryReader { geo in
                let span = limits.upperBound - limits.lowerBound
                let x0 = CGFloat((low - limits.lowerBound) / span) * geo.size.width
                let x1 = CGFloat((high - limits.lowerBound) / span) * geo.size.width
                ZStack(alignment: .leading) {
                    LinearGradient(colors: stride(from: limits.lowerBound, through: limits.upperBound, by: 15).map {
                        Color(hue: Double($0.truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.8, brightness: 0.9)
                    }, startPoint: .leading, endPoint: .trailing)
                    .opacity(0.35)
                    Rectangle()
                        .fill(LinearGradient(colors: stride(from: low, through: high, by: max(1, (high - low) / 6)).map {
                            Color(hue: Double($0.truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.8, brightness: 0.9)
                        }, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, x1 - x0))
                        .offset(x: x0)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .accessibilityHidden(true)
            ResettableSlider(value: lowBinding, in: limits, label: "\(title) from",
                             format: SliderValueFormat(decimals: 0, unit: "°"), reset: reset)
                .help("Where the \(title.lowercased()) range starts. Double-click to reset both ends.")
            ResettableSlider(value: highBinding, in: limits, label: "\(title) to",
                             format: SliderValueFormat(decimals: 0, unit: "°"), reset: reset)
                .help("Where the \(title.lowercased()) range ends. Double-click to reset both ends.")
        }
    }

    /// Each end stays at least the minimum width from the other.
    private var lowBinding: Binding<Float> {
        Binding(get: { low }, set: { low = min($0, high - DefringeHueRanges.minimumWidth) })
    }
    private var highBinding: Binding<Float> {
        Binding(get: { high }, set: { high = max($0, low + DefringeHueRanges.minimumWidth) })
    }
}

/// The Effects panel: post-crop vignetting and grain.
struct EffectsPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSubheading(title: "Post-Crop Vignetting")
            Picker("Style", selection: $model.parameters.postCropVignette.style) {
                ForEach(PostCropVignette.Style.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Vignette style")
            .help("Highlight Priority works like exposure and keeps bright areas bright; Colour Priority changes brightness only and keeps colours as they are.")
            DetailSliderRow(title: "Amount", value: $model.parameters.postCropVignette.amount, range: -1...1,
                            format: "%+.0f", scale: 100,
                            help: "Darkens (negative) or lightens (positive) the edges of the cropped picture. 0 is off.")
            Group {
                DetailSliderRow(title: "Midpoint", value: $model.parameters.postCropVignette.midpoint, range: 0...1,
                                format: "%.0f", scale: 100, defaultValue: 0.5,
                                help: "How far in from the corners the vignette reaches; lower reaches closer to the centre.")
                DetailSliderRow(title: "Roundness", value: $model.parameters.postCropVignette.roundness, range: -1...1,
                                format: "%+.0f", scale: 100,
                                help: "Negative follows the crop's rectangle, 0 is an oval fitting the crop, positive becomes a circle.")
                DetailSliderRow(title: "Feather", value: $model.parameters.postCropVignette.feather, range: 0...1,
                                format: "%.0f", scale: 100, defaultValue: 0.5,
                                help: "How soft the vignette's edge is: 0 is a hard edge.")
                DetailSliderRow(title: "Highlights", value: $model.parameters.postCropVignette.highlights, range: 0...1,
                                format: "%.0f", scale: 100,
                                help: "When darkening, how much bright areas such as lights and sky keep their brightness.")
                    .disabled(model.parameters.postCropVignette.amount >= 0)
            }
            .disabled(!model.parameters.postCropVignette.isActive)

            DetailSubheading(title: "Grain")
            DetailSliderRow(title: "Amount", value: $model.parameters.grain.amount, range: 0...1,
                            format: "%.0f", scale: 100,
                            help: "Adds film-like grain. 0 is off. The pattern is fixed to this photo, so the export matches the screen.")
            Group {
                DetailSliderRow(title: "Size", value: $model.parameters.grain.size, range: 0...1,
                                format: "%.0f", scale: 100, defaultValue: 0.25,
                                help: "The size of each grain, relative to the picture.")
                DetailSliderRow(title: "Roughness", value: $model.parameters.grain.roughness, range: 0...1,
                                format: "%.0f", scale: 100, defaultValue: 0.5,
                                help: "Low gives smooth, even grain; high gives clumpier, irregular grain.")
            }
            .disabled(!model.parameters.grain.isActive)
            Text("Judge grain at 100% zoom; zoomed out, the preview shows it softened as a smaller print would.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .disabled(!model.hasImage)
    }
}

/// While the defringe eyedropper is armed: a crosshair cursor over the
/// image, and the click goes to the picker instead of panning.
struct DefringePickerOverlay: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    let scale = geo.size.width > 0 ? model.drawableSize.width / geo.size.width : 2
                    model.defringePick(atScreen: CGPoint(x: location.x * scale, y: location.y * scale))
                }
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .accessibilityElement()
                .accessibilityLabel("Defringe eyedropper: click a coloured fringe")
                .accessibilityAddTraits(.isButton)
        }
    }
}
