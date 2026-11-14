import SwiftUI
import PixelEngine

/// Four handles over a gradient of the channel a range reads: where the
/// fade below the band starts, Low, High, and where the fade above it
/// ends. The band's shape is drawn above the gradient, full between Low
/// and High and sloping to nothing at the outer handles. `probe` marks the
/// value under the pointer.
struct RangeControl: View {
    @Binding var band: MaskRangeBand
    let colours: [Color]
    var probe: Float? = nil
    let label: String

    private enum Handle: CaseIterable {
        case lowEdge, low, high, highEdge
        var name: String {
            switch self {
            case .lowEdge: return "Fade below"
            case .low: return "Low"
            case .high: return "High"
            case .highEdge: return "Fade above"
            }
        }
    }

    private static let barHeight: CGFloat = 10
    private static let shapeHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .topLeading) {
                Path { path in
                    let b = band
                    let y0 = Self.shapeHeight, y1: CGFloat = 1
                    path.move(to: CGPoint(x: x(b.lowEdge, w), y: y0))
                    path.addLine(to: CGPoint(x: x(b.low, w), y: y1))
                    path.addLine(to: CGPoint(x: x(b.high, w), y: y1))
                    path.addLine(to: CGPoint(x: x(b.highEdge, w), y: y0))
                    path.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.35))
                LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing)
                    .frame(height: Self.barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                    .offset(y: Self.shapeHeight)
                if let probe {
                    Rectangle().fill(Color.primary)
                        .frame(width: 1.5, height: Self.barHeight + 4)
                        .offset(x: x(probe, w) - 0.75, y: Self.shapeHeight - 2)
                        .accessibilityHidden(true)
                }
                ForEach(Handle.allCases, id: \.self) { handle in
                    handleView(handle, width: w)
                }
            }
            .coordinateSpace(name: "rangeControl")
        }
        .frame(height: Self.shapeHeight + Self.barHeight + 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func x(_ v: Float, _ w: CGFloat) -> CGFloat { CGFloat(min(max(v, 0), 1)) * w }

    private func value(of handle: Handle) -> Float {
        switch handle {
        case .lowEdge: return band.lowEdge
        case .low: return band.low
        case .high: return band.high
        case .highEdge: return band.highEdge
        }
    }

    private func set(_ handle: Handle, to v: Float) {
        var b = band
        switch handle {
        case .lowEdge: b.featherLow = b.low - v
        case .low: b.low = min(v, b.high)
        case .high: b.high = max(v, b.low)
        case .highEdge: b.featherHigh = v - b.high
        }
        band = b.sanitised()
    }

    private func handleView(_ handle: Handle, width w: CGFloat) -> some View {
        let outer = handle == .lowEdge || handle == .highEdge
        let v = value(of: handle)
        return Image(systemName: outer ? "arrowtriangle.up" : "arrowtriangle.up.fill")
            .font(.system(size: 9))
            .foregroundStyle(outer ? Color.secondary : Color.primary)
            .frame(width: 14, height: 10)
            .contentShape(Rectangle())
            .offset(x: x(v, w) - 7, y: Self.shapeHeight + Self.barHeight)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeControl"))
                .onChanged { set(handle, to: Float($0.location.x / w)) })
            .help(handle.name)
            .accessibilityElement()
            .accessibilityLabel(handle.name)
            .accessibilityValue(String(format: "%.2f", v))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(handle, to: v + 0.01)
                case .decrement: set(handle, to: v - 0.01)
                @unknown default: break
                }
            }
    }

    /// The gradient under the handles for a channel (nil: luminance).
    static func colours(for channel: MaskChannel?) -> [Color] {
        switch channel {
        case nil, .lightness?: return [.black, .white]
        case .red?: return [.black, Color(red: 1, green: 0, blue: 0)]
        case .green?: return [.black, Color(red: 0, green: 1, blue: 0)]
        case .blue?: return [.black, Color(red: 0, green: 0, blue: 1)]
        case .saturation?, .labChroma?: return [.gray, Color(red: 1, green: 0.4, blue: 0)]
        case .labA?: return [Color(red: 0, green: 0.7, blue: 0.3), .gray, Color(red: 0.9, green: 0, blue: 0.6)]
        case .labB?: return [Color(red: 0, green: 0.3, blue: 0.9), .gray, Color(red: 0.95, green: 0.85, blue: 0)]
        }
    }
}

/// The range control with its eyedropper and the live readout of the
/// value under the pointer, for a Luminance Range (channel nil) or a
/// Channel Range. `probes`: whether the eyedropper and readout serve this
/// range (the selected one does; the mask's own Luminance range only when
/// no component is selected).
struct MaskRangeEditor: View {
    @ObservedObject var model: EditorModel
    @Binding var band: MaskRangeBand
    let channel: MaskChannel?
    let probes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if probes {
                HStack(spacing: 6) {
                    Button(model.maskTool == .lumaSample ? "Picking…" : "Pick Range") { model.maskTool = .lumaSample }
                        .disabled(model.maskTool == .lumaSample)
                        .help("Click the image to centre the range on that spot, or drag a rectangle to span what is inside it")
                    Spacer()
                    Text(model.maskRangeProbe.map { String(format: "Under pointer: %.2f", $0) } ?? "Under pointer: –")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel(model.maskRangeProbe.map { String(format: "Value under the pointer, %.2f", $0) }
                                            ?? "No value under the pointer")
                }
                .controlSize(.small)
            }
            RangeControl(band: $band, colours: RangeControl.colours(for: channel),
                         probe: probes ? model.maskRangeProbe : nil,
                         label: "\(channel?.displayName ?? "Luminance") range")
        }
    }
}

/// A Channel Range component's controls: the channel, the range control
/// and the numeric sliders.
struct ChannelRangeControls: View {
    @ObservedObject var model: EditorModel
    let range: ChannelRange
    let update: (ChannelRange) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Channel", selection: Binding(get: { range.channel }, set: { var r = range; r.channel = $0; update(r) })) {
                ForEach(MaskChannel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .controlSize(.small)
            .help("The channel this component selects by")
            MaskRangeEditor(model: model, band: Binding(get: { range.band }, set: { var r = range; r.band = $0; update(r) }),
                            channel: range.channel, probes: true)
            LocalSliderRow(title: "Low", value: field(\.low), range: 0...1, format: "%.2f", defaultValue: 0.5)
            LocalSliderRow(title: "High", value: field(\.high), range: 0...1, format: "%.2f", defaultValue: 1)
            LocalSliderRow(title: "Feather", value: field(\.bothFeathers), range: 0.01...0.5, format: "%.2f",
                           defaultValue: 0.1, help: "Both fades at once; drag the outer handles above to set them apart")
        }
    }

    private func field(_ key: WritableKeyPath<ChannelRange, Float>) -> Binding<Float> {
        Binding(get: { range[keyPath: key] }, set: { var r = range; r[keyPath: key] = $0; update(r) })
    }
}

/// Show Channel for one range component's row: selects the component and
/// shows what it reads as a grey on the image, or stops showing it.
struct MaskChannelViewButton: View {
    @ObservedObject var model: EditorModel
    let component: UUID
    let title: String

    var body: some View {
        let on = model.showMaskChannel && model.selectedMaskComponentID == component
        Button {
            if on {
                model.showMaskChannel = false
            } else {
                model.selectedMaskComponentID = component
                model.showMaskChannel = true
            }
        } label: {
            Image(systemName: on ? "circle.lefthalf.filled" : "circle.lefthalf.striped.horizontal")
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Show Channel: what this range reads, as a grey on the image")
        .accessibilityLabel(on ? "Stop showing the channel of \(title)" : "Show the channel of \(title)")
    }
}

/// Keep tool armed, under a gradient's or radial's tool hint.
struct MaskShapeToolOptions: View {
    @ObservedObject var model: EditorModel
    @AppStorage(EditorModel.keepMaskToolArmedKey) private var keepArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Keep tool armed", isOn: $keepArmed)
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Stay ready after placing a shape, so the next drag away from it places another")
            if model.maskHandlesActive {
                Text("Drag the handles to reshape it. Scroll over it to change the feather; ⇧-scroll changes Amount.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
