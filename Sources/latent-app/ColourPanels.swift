import SwiftUI
import PixelEngine

/// The Develop panel's colour groups after HSL: Black & White, Point
/// Colour, Colour Grading and Calibration, each a disclosure group like the
/// panel's others.
struct ColourSections: View {
    @ObservedObject var model: EditorModel
    @State private var blackAndWhiteExpanded = false
    @State private var pointColourExpanded = false
    @State private var gradingExpanded = false
    @State private var calibrationExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $blackAndWhiteExpanded) {
            BlackAndWhitePanel(model: model).padding(.top, 8)
        } label: {
            HStack {
                ColourSectionLabel(title: "Black & White")
                if model.isBlackAndWhite { badge("B&W") }
            }
        }

        DisclosureGroup(isExpanded: $pointColourExpanded) {
            PointColourPanel(model: model).padding(.top, 8)
        } label: {
            HStack {
                ColourSectionLabel(title: "Point Colour")
                if model.pointColourPicking { badge("ON") }
            }
        }
        .onChange(of: model.pointColourPicking) { _, picking in
            if picking { pointColourExpanded = true }
        }

        DisclosureGroup(isExpanded: $gradingExpanded) {
            ColourGradingPanel(parameters: $model.parameters)
                .disabled(!model.hasImage)
                .padding(.top, 8)
        } label: {
            ColourSectionLabel(title: "Colour Grading")
        }

        DisclosureGroup(isExpanded: $calibrationExpanded) {
            CalibrationPanel(calibration: $model.parameters.colour.calibration)
                .disabled(!model.hasImage)
                .padding(.top, 8)
        } label: {
            ColourSectionLabel(title: "Calibration")
        }
    }

    /// Marks a group that is doing something right now, like the panel's
    /// "ON" for an armed tool.
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
            .accessibilityLabel(text == "ON" ? "picker on" : "black and white")
    }
}

/// The Develop panel's group heading style.
struct ColourSectionLabel: View {
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

/// A titled slider with its value, laid out like the panel's other rows.
/// Double-click resets it.
struct ColourSliderRow: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float> = -1...1
    var format = SliderValueFormat(decimals: 0, signed: true, scale: 100)
    var defaultValue: Float = 0
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).accessibilityHidden(true)
                Spacer()
                SliderValueField(value: $value, in: range, format: format, label: title)
            }
            ResettableSlider(value: $value, in: range, label: title, format: format) { value = defaultValue }
                .help(help + " Double-click to reset.")
        }
    }
}

// MARK: - Black & White

/// The treatment switch and the grey mix: one slider per HSL colour, how
/// light that colour turns in black and white.
struct BlackAndWhitePanel: View {
    @ObservedObject var model: EditorModel

    private static let swatches: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, Color(red: 1, green: 0, blue: 0.6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Treatment", selection: Binding(get: { model.isBlackAndWhite },
                                                   set: { model.setBlackAndWhite($0) })) {
                Text("Color").tag(false)
                Text("Black & White").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Treatment")
            .help("Color, or Black & White with the grey mix below (V)")

            if model.isBlackAndWhite {
                ForEach(0..<8, id: \.self) { band in
                    HStack(spacing: 6) {
                        Circle().fill(Self.swatches[band]).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(HSLAdjustments.bandNames[band]).font(.caption).frame(width: 52, alignment: .leading)
                            .accessibilityHidden(true)
                        ResettableSlider(value: $model.parameters.colour.blackAndWhite.mix[band], in: -1...1,
                                         label: "\(HSLAdjustments.bandNames[band]) grey",
                                         format: SliderValueFormat(decimals: 0, signed: true, scale: 100)) {
                            model.parameters.colour.blackAndWhite.mix[band] = 0
                        }
                        .help("How light \(HSLAdjustments.bandNames[band].lowercased()) turns in black and white. Double-click to reset.")
                        Text(String(format: "%+.0f", model.parameters.colour.blackAndWhite.mix[band] * 100))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
                HStack {
                    Button("Auto") { model.applyAutoBlackAndWhiteMix() }
                        .controlSize(.mini)
                        .help("Set each colour's grey to how light it looks in colour")
                    Spacer()
                    Button("Reset") { model.parameters.colour.blackAndWhite.mix = BlackAndWhite.neutralMix }
                        .controlSize(.mini)
                        .disabled(model.parameters.colour.blackAndWhite.mixIsNeutral)
                        .help("Every colour back to its plain luminance")
                }
            } else {
                Text("Black & White replaces HSL, Point Colour, Saturation and Vibrance with a grey mix. Colour Grading and Split Toning still tint the result.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!model.hasImage)
    }
}

// MARK: - Point Colour

/// Picked colours, each with a shift in hue, saturation and luminance for
/// the colours near it.
struct PointColourPanel: View {
    @ObservedObject var model: EditorModel

    private var swatches: [PointColour] { model.parameters.colour.pointColours }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(model.pointColourPicking ? "Click the photo…" : "Pick a Colour") {
                    if model.pointColourPicking { model.pointColourPicking = false } else { model.beginPointColourPick() }
                }
                .controlSize(.small)
                .help("Then click a colour in the photo to add it as a swatch")
                .disabled(swatches.count >= PointColour.maximumCount && !model.pointColourPicking)
                Spacer()
                ForEach(Array(swatches.enumerated()), id: \.offset) { index, swatch in
                    swatchButton(index, swatch)
                }
            }

            if model.isBlackAndWhite {
                Text("Point Colour has no effect while the treatment is Black & White.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let i = model.selectedPointColour, swatches.indices.contains(i) {
                controls(for: i)
            } else if swatches.isEmpty {
                Text("Pick a colour from the photo, then shift its hue, saturation and luminance. Range sets how alike a colour must be to change with it.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!model.hasImage)
    }

    private func swatchButton(_ index: Int, _ swatch: PointColour) -> some View {
        let selected = index == model.selectedPointColour
        return Button { model.selectedPointColour = index } label: {
            Circle()
                .fill(Color(hue: Double(swatch.hue) / 360, saturation: Double(swatch.saturation),
                            brightness: Double(swatch.value)))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(selected ? Color.accentColor : Color(white: 0.4), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help("Point colour \(index + 1)")
        .accessibilityLabel("Point colour \(index + 1)")
        .accessibilityValue(String(format: "hue %.0f degrees, saturation %.0f, brightness %.0f%@",
                                   swatch.hue, swatch.saturation * 100, swatch.value * 100,
                                   selected ? ", selected" : ""))
    }

    private func controls(for i: Int) -> some View {
        let swatch = $model.parameters.colour.pointColours[i]
        return VStack(alignment: .leading, spacing: 10) {
            ColourSliderRow(title: "Hue", value: swatch.hueShift,
                            help: "Turns the picked colour and those near it round the colour circle, up to 60°.")
            ColourSliderRow(title: "Saturation", value: swatch.saturationShift,
                            help: "Makes the picked colours greyer or more vivid.")
            ColourSliderRow(title: "Luminance", value: swatch.luminanceShift,
                            help: "Makes the picked colours darker or lighter.")
            ColourSliderRow(title: "Range", value: swatch.range, range: 0...1,
                            format: SliderValueFormat(decimals: 0, scale: 100), defaultValue: PointColour.defaultRange,
                            help: "How different a colour may be from the picked one and still change.")
            ColourSliderRow(title: "Variance", value: swatch.variance,
                            help: "Below zero pulls the colours in range together towards the picked one; above zero spreads them apart.")
            HStack {
                Spacer()
                Button("Delete Swatch") { model.deletePointColour(at: i) }
                    .controlSize(.mini)
                    .help("Remove this point colour")
            }
        }
    }
}

// MARK: - Colour Grading

/// Three-way Colour Grading: shadow, midtone and highlight wheels (plus a
/// global one), each a tint and a luminance, with Blending and Balance.
/// The shadow and highlight tints and Balance are Split Toning's own
/// values, so an edit made with the old Split Toning panel shows here
/// unchanged.
struct ColourGradingPanel: View {
    @Binding var parameters: EditParameters
    @State private var view: GradingView = .threeWay

    enum GradingView: String, CaseIterable, Identifiable {
        case threeWay = "3-Way", shadows = "Shadows", midtones = "Midtones", highlights = "Highlights", global = "Global"
        var id: String { rawValue }
        var range: GradingRange? {
            switch self {
            case .threeWay: nil
            case .shadows: .shadows
            case .midtones: .midtones
            case .highlights: .highlights
            case .global: .global
            }
        }
    }

    enum GradingRange: String { case shadows = "Shadows", midtones = "Midtones", highlights = "Highlights", global = "Global" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Wheels", selection: $view) {
                ForEach(GradingView.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .accessibilityLabel("Colour grading wheels")

            if let range = view.range {
                singleWheel(range)
            } else {
                VStack(spacing: 8) {
                    compactWheel(.midtones)
                    HStack(alignment: .top, spacing: 10) {
                        compactWheel(.shadows)
                        compactWheel(.highlights)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            ColourSliderRow(title: "Blending", value: blending, range: 0...1,
                            format: SliderValueFormat(decimals: 0, scale: 100),
                            defaultValue: ColourGrading.defaultBlending,
                            help: "How far shadows, midtones and highlights reach into each other.")
            ColourSliderRow(title: "Balance", value: $parameters.splitToning.balance,
                            help: "Moves the line between shadows and highlights: below zero more of the picture counts as shadow.")
            HStack {
                Spacer()
                Button("Reset") {
                    var p = parameters
                    p.splitToning = .neutral
                    p.colour.grading = .neutral
                    parameters = p
                }
                .controlSize(.mini)
                .disabled(parameters.splitToning == .neutral && parameters.colour.grading.isNeutral)
                .help("Every wheel back to no tint")
            }
        }
    }

    private var blending: Binding<Float> { $parameters.colour.grading.blending }

    /// One range's wheel, written to Split Toning (shadow and highlight
    /// tints) and Colour Grading (the rest) in one change.
    private func wheel(_ range: GradingRange) -> Binding<GradingWheel> {
        Binding(
            get: {
                let st = parameters.splitToning, g = parameters.colour.grading
                switch range {
                case .shadows: return GradingWheel(hue: st.shadowHue, saturation: st.shadowSaturation, luminance: g.shadowLuminance)
                case .highlights: return GradingWheel(hue: st.highlightHue, saturation: st.highlightSaturation,
                                                      luminance: g.highlightLuminance)
                case .midtones: return g.midtones
                case .global: return g.global
                }
            },
            set: { w in
                var p = parameters
                switch range {
                case .shadows:
                    p.splitToning.shadowHue = w.hue; p.splitToning.shadowSaturation = w.saturation
                    p.colour.grading.shadowLuminance = w.luminance
                case .highlights:
                    p.splitToning.highlightHue = w.hue; p.splitToning.highlightSaturation = w.saturation
                    p.colour.grading.highlightLuminance = w.luminance
                case .midtones: p.colour.grading.midtones = w
                case .global: p.colour.grading.global = w
                }
                parameters = p
            })
    }

    private func compactWheel(_ range: GradingRange) -> some View {
        let w = wheel(range)
        return VStack(spacing: 4) {
            Text(range.rawValue).font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            ColourWheel(wheel: w, title: range.rawValue).frame(width: 96, height: 96)
            ResettableSlider(value: w.luminance, in: -1...1, label: "\(range.rawValue) luminance",
                             format: SliderValueFormat(decimals: 0, signed: true, scale: 100)) { w.wrappedValue.luminance = 0 }
                .frame(width: 110)
                .help("\(range.rawValue) luminance: darker or lighter. Double-click to reset.")
        }
    }

    private func singleWheel(_ range: GradingRange) -> some View {
        let w = wheel(range)
        return VStack(alignment: .leading, spacing: 10) {
            ColourWheel(wheel: w, title: range.rawValue)
                .frame(width: 170, height: 170)
                .frame(maxWidth: .infinity)
            ColourSliderRow(title: "Hue", value: w.hue, range: 0...360,
                            format: SliderValueFormat(decimals: 0, unit: "°"), defaultValue: w.wrappedValue.hue,
                            help: "The tint's colour.")
            ColourSliderRow(title: "Saturation", value: w.saturation, range: 0...1,
                            format: SliderValueFormat(decimals: 0, scale: 100),
                            help: "How strong the tint is.")
            ColourSliderRow(title: "Luminance", value: w.luminance,
                            help: "Darkens or lightens this range.")
        }
    }
}

/// A colour wheel: the angle round it is the tint's hue, the distance from
/// the centre its strength. Drag the puck anywhere on the wheel; double-
/// click to take the tint off. VoiceOver adjusts the strength.
struct ColourWheel: View {
    @Binding var wheel: GradingWheel
    let title: String

    private static let rim: [Color] = stride(from: 0, through: 360, by: 30).map {
        // SwiftUI's angular gradient runs clockwise on screen; hue runs
        // anticlockwise from the right, so the colours go in reverse.
        Color(hue: Double((360 - $0) % 360) / 360, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().fill(AngularGradient(colors: Self.rim, center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.55).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: radius))
                Circle().stroke(Color(white: 0.15), lineWidth: 1)
                Circle()
                    .fill(Color(hue: Double(wheel.hue) / 360, saturation: Double(wheel.saturation), brightness: 1))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
                    .position(puck(centre: centre, radius: radius))
            }
            .frame(width: size, height: size)
            .position(centre)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - centre.x, dy = value.location.y - centre.y
                var hue = Float(atan2(-dy, dx) * 180 / .pi)
                if hue < 0 { hue += 360 }
                let strength = Float(min(hypot(dx, dy) / max(radius, 1), 1))
                wheel.hue = (hue * 10).rounded() / 10
                wheel.saturation = (strength * 1000).rounded() / 1000
            })
            .onTapGesture(count: 2) { wheel.saturation = 0 }
        }
        .aspectRatio(1, contentMode: .fit)
        .help("\(title): drag for the tint's colour and strength. Double-click to remove the tint.")
        .accessibilityElement()
        .accessibilityLabel("\(title) tint")
        .accessibilityValue(String(format: "hue %.0f degrees, saturation %.0f", wheel.hue, wheel.saturation * 100))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: wheel.saturation = min(wheel.saturation + 0.05, 1)
            case .decrement: wheel.saturation = max(wheel.saturation - 0.05, 0)
            @unknown default: break
            }
        }
    }

    private func puck(centre: CGPoint, radius: CGFloat) -> CGPoint {
        let a = CGFloat(wheel.hue) * .pi / 180
        let r = CGFloat(wheel.saturation) * radius
        return CGPoint(x: centre.x + cos(a) * r, y: centre.y - sin(a) * r)
    }
}

// MARK: - Calibration

/// Lightroom's Calibration: a shadow tint, and the red, green and blue
/// primaries' hue and saturation.
struct CalibrationPanel: View {
    @Binding var calibration: Calibration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColourSliderRow(title: "Shadows Tint", value: $calibration.shadowTint,
                            help: "Green (left) or magenta (right) in the shadows.")
            primary("Red", hue: $calibration.redHue, saturation: $calibration.redSaturation,
                    hueHelp: "Turns reds towards magenta (left) or orange (right), and every colour made with red with them.")
            primary("Green", hue: $calibration.greenHue, saturation: $calibration.greenSaturation,
                    hueHelp: "Turns greens towards yellow (left) or cyan (right).")
            primary("Blue", hue: $calibration.blueHue, saturation: $calibration.blueSaturation,
                    hueHelp: "Turns blues towards cyan (left) or purple (right).")
            HStack {
                Spacer()
                Button("Reset") { calibration = .neutral }
                    .controlSize(.mini)
                    .disabled(calibration.isNeutral)
                    .help("Calibration back to the camera's own colour")
            }
        }
    }

    private func primary(_ name: String, hue: Binding<Float>, saturation: Binding<Float>, hueHelp: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) Primary").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            ColourSliderRow(title: "\(name) Hue", value: hue, help: hueHelp)
            ColourSliderRow(title: "\(name) Saturation", value: saturation,
                            help: "Makes the \(name.lowercased()) primary, and the colours built from it, duller or richer.")
        }
    }
}
