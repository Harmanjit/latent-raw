import SwiftUI
import PixelEngine

/// The selected mask's Curve, Point Colour and Grain, each in a group
/// that starts closed and opens once used (LocalToneColour.swift has
/// where they render).
struct MaskToneColourControls: View {
    @ObservedObject var model: EditorModel
    let index: Int
    @State private var curveOpen = false
    @State private var colourOpen = false
    @State private var grainOpen = false
    @State private var selectedSwatch: Int?

    private var local: Binding<LocalAdjustment> { $model.parameters.locals[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: Binding(get: { curveOpen || curveUsed }, set: { curveOpen = $0 })) {
                ToneCurvePanel(master: masterCurve, channels: channelCurves)
                    .frame(maxWidth: 220)
                    .padding(.top, 4)
            } label: { Text("Curve").font(.caption.weight(.semibold)) }
            .accessibilityLabel("Curve inside the mask")

            DisclosureGroup(isExpanded: Binding(get: { colourOpen || !local.wrappedValue.pointColours.isEmpty },
                                                set: { colourOpen = $0 })) {
                pointColour.padding(.top, 4)
            } label: { Text("Point Colour").font(.caption.weight(.semibold)) }
            .accessibilityLabel("Point Colour inside the mask")

            DisclosureGroup(isExpanded: Binding(get: { grainOpen || local.wrappedValue.grain != nil },
                                                set: { grainOpen = $0 })) {
                VStack(alignment: .leading, spacing: 8) {
                    LocalSliderRow(title: "Grain", value: grainBinding(\.amount), range: 0...1, format: "%.2f",
                                   help: "Film-like grain inside the mask, on top of any global grain")
                    LocalSliderRow(title: "Size", value: grainBinding(\.size), range: 0...1, format: "%.2f",
                                   defaultValue: Grain().size, help: "How big each grain is")
                    LocalSliderRow(title: "Roughness", value: grainBinding(\.roughness), range: 0...1, format: "%.2f",
                                   defaultValue: Grain().roughness, help: "Even grain (left) or clumpier grain (right)")
                }
                .padding(.top, 4)
            } label: { Text("Grain").font(.caption.weight(.semibold)) }
            .accessibilityLabel("Grain inside the mask")
        }
    }

    private var curveUsed: Bool {
        local.wrappedValue.curve.map { !$0.isIdentity } == true
            || local.wrappedValue.channelCurves.map { !$0.isIdentity } == true
    }

    /// A straight line is stored as no curve, so an untouched mask writes nothing.
    private var masterCurve: Binding<ToneCurve> {
        Binding(get: { local.wrappedValue.curve ?? .identity },
                set: { local.wrappedValue.curve = $0.isIdentity ? nil : $0 })
    }

    private var channelCurves: Binding<RGBCurves> {
        Binding(get: { local.wrappedValue.channelCurves ?? .identity },
                set: { local.wrappedValue.channelCurves = $0.isIdentity ? nil : $0 })
    }

    /// Grain with no amount is stored as none, keeping its size and
    /// roughness only while it is on.
    private func grainBinding(_ key: WritableKeyPath<Grain, Float>) -> Binding<Float> {
        Binding(get: { (local.wrappedValue.grain ?? Grain())[keyPath: key] },
                set: { value in
                    var g = local.wrappedValue.grain ?? Grain()
                    g[keyPath: key] = value
                    local.wrappedValue.grain = g.isActive ? g : nil
                })
    }

    @ViewBuilder
    private var pointColour: some View {
        let swatches = local.wrappedValue.pointColours
        let localID = local.wrappedValue.id
        let picking = model.pointColourPicking && model.pointColourPickLocal == localID
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(picking ? "Click the photo…" : "Pick a Colour") {
                    if picking { model.pointColourPicking = false } else { model.beginLocalPointColourPick(localID) }
                }
                .controlSize(.small)
                .help("Then click a colour in the photo; only that colour inside this mask changes")
                .disabled(swatches.count >= LocalAdjustment.maximumPointColours && !picking)
                Spacer()
                ForEach(Array(swatches.enumerated()), id: \.offset) { i, swatch in
                    Button { selectedSwatch = i } label: {
                        Circle()
                            .fill(Color(hue: Double(swatch.hue) / 360, saturation: Double(swatch.saturation),
                                        brightness: Double(swatch.value)))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(i == currentSwatch ? Color.accentColor : Color(white: 0.4),
                                                     lineWidth: i == currentSwatch ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mask point colour \(i + 1)")
                    .accessibilityAddTraits(i == currentSwatch ? .isSelected : [])
                }
            }
            if let i = currentSwatch {
                let swatch = local.pointColours[i]
                LocalSliderRow(title: "Hue", value: swatch.hueShift, range: -1...1, format: "%+.2f",
                               help: "Turns the picked colour round the colour circle, up to 60°")
                LocalSliderRow(title: "Saturation", value: swatch.saturationShift, range: -1...1, format: "%+.2f")
                LocalSliderRow(title: "Luminance", value: swatch.luminanceShift, range: -1...1, format: "%+.2f")
                LocalSliderRow(title: "Range", value: swatch.range, range: 0...1, format: "%.2f",
                               defaultValue: PointColour.defaultRange,
                               help: "How different a colour may be from the picked one and still change")
                LocalSliderRow(title: "Variance", value: swatch.variance, range: -1...1, format: "%+.2f",
                               help: "Below zero pulls the colours in range together; above zero spreads them apart")
                HStack {
                    Spacer()
                    Button("Delete Swatch") {
                        local.wrappedValue.pointColours.remove(at: i)
                        selectedSwatch = local.wrappedValue.pointColours.isEmpty ? nil : max(0, i - 1)
                    }
                    .controlSize(.mini)
                }
            } else if swatches.isEmpty {
                Text("Pick a colour from the photo to shift it inside this mask only.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The selected swatch, or the newest when none is (a pick just added it).
    private var currentSwatch: Int? {
        let count = local.wrappedValue.pointColours.count
        guard count > 0 else { return nil }
        if let s = selectedSwatch, s < count { return s }
        return count - 1
    }
}
