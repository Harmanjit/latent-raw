import SwiftUI
import AppKit
import PixelEngine
import Catalog

/// The export sheet's watermark settings: a switch, then the text, corner,
/// size, opacity and colour.
struct ExportWatermarkSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        Toggle("Watermark", isOn: $preset.watermarkEnabled)
            .accessibilityHint("Stamps a line of text into a corner of each exported file.")
            .help("Stamps a line of text into a corner of each file. The photo in the catalog stays clean.")
        if preset.watermarkEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Text").accessibilityHidden(true)
                    TextField(ExportWatermark.defaultText, text: $preset.watermark.text)
                        .accessibilityLabel("Watermark text")
                    Menu("Insert") {
                        ForEach(ExportWatermark.tokens, id: \.token) { t in
                            Button("\(t.token)  \(t.meaning)") { preset.watermark.text += t.token }
                        }
                    }
                    .fixedSize()
                    .accessibilityLabel("Insert a watermark token")
                }
                HStack {
                    Picker("Corner", selection: $preset.watermark.corner) {
                        ForEach(ExportWatermark.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                    Spacer()
                    ColorPicker("Colour", selection: colorBinding, supportsOpacity: false)
                        .accessibilityLabel("Watermark colour")
                }
                HStack {
                    Text("Size").accessibilityHidden(true)
                    ResettableSlider(value: $preset.watermark.size, in: ExportWatermark.sizeRange, label: "Watermark size",
                                     format: SliderValueFormat(decimals: 1, unit: "%", scale: 100)) {
                        preset.watermark.size = ExportWatermark().size
                    }
                    Text(String(format: "%.1f%%", preset.watermark.size * 100)).monospacedDigit().frame(width: 44)
                        .accessibilityHidden(true)
                    Text("Opacity").accessibilityHidden(true)
                    ResettableSlider(value: $preset.watermark.opacity, in: ExportWatermark.opacityRange,
                                     label: "Watermark opacity", format: SliderValueFormat(decimals: 0, unit: "%", scale: 100)) {
                        preset.watermark.opacity = ExportWatermark().opacity
                    }
                    Text(String(format: "%.0f%%", preset.watermark.opacity * 100)).monospacedDigit().frame(width: 38)
                        .accessibilityHidden(true)
                }
                Text("Size is a share of the picture's short edge. {year} and {name} are filled in per image.")
                    .font(.caption).foregroundStyle(.secondary)
                if preset.watermark.isEmpty {
                    Label("The watermark has no text, so nothing is stamped.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.leading, 20)
        }
    }

    /// The stored sRGB components as a colour, and back.
    private var colorBinding: Binding<Color> {
        Binding {
            Color(.sRGB, red: Double(preset.watermark.red), green: Double(preset.watermark.green),
                  blue: Double(preset.watermark.blue))
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            preset.watermark.red = Float(min(max(srgb.redComponent, 0), 1))
            preset.watermark.green = Float(min(max(srgb.greenComponent, 0), 1))
            preset.watermark.blue = Float(min(max(srgb.blueComponent, 0), 1))
        }
    }
}

/// The estimated size of the export, as it is worked out.
struct ExportEstimateLabel: View {
    @ObservedObject var model: ExportEstimateModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.state {
            case .none:
                EmptyView()
            case .working:
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text(model.lastBytes.map { "Estimating… (was \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" }
                     ?? "Estimating size…")
                    .foregroundStyle(.secondary)
            case .ready(let bytes, let images):
                Text("Estimated size: " + ExportEstimateModel.text(bytes: bytes, images: images).lowercasedFirst)
                    .help(images == 1
                          ? "The first image rendered and encoded at these settings."
                          : "The first image rendered and encoded at these settings, scaled by each image's pixel count. "
                            + "Detail and crops vary, so the real total will differ.")
            case .failed(let reason):
                Text("Size estimate unavailable").foregroundStyle(.secondary).help(reason)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch model.state {
        case .none: ""
        case .working: "Estimating export size"
        case .ready(let bytes, let images): "Estimated export size: " + ExportEstimateModel.text(bytes: bytes, images: images)
        case .failed: "Size estimate unavailable"
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
