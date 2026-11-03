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
            .accessibilityHint("Stamps a line of text or a graphic into a corner of each exported file.")
            .help("Stamps a line of text, or a logo from a PNG, into a corner of each file. The photo in the catalog stays clean.")
        if preset.watermarkEnabled {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Style", selection: $preset.watermark.style) {
                    ForEach(ExportWatermark.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel("Watermark style")
                .help("Text with the tokens below, or a graphic: a PNG logo, transparency kept.")
                if preset.watermark.style == .text {
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
                    WatermarkFontPicker(fontName: $preset.watermark.fontName)
                } else {
                    WatermarkGraphicPicker(watermark: $preset.watermark)
                }
                HStack {
                    Picker("Corner", selection: $preset.watermark.corner) {
                        ForEach(ExportWatermark.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                    Picker("Rotation", selection: $preset.watermark.rotation) {
                        Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                    }
                    .frame(width: 150)
                    .help("Turns the watermark clockwise; 270° runs text up the side of the picture.")
                    Spacer()
                    if preset.watermark.style == .text {
                        ColorPicker("Colour", selection: colorBinding, supportsOpacity: false)
                            .accessibilityLabel("Watermark colour")
                    }
                }
                HStack {
                    Text("Size").accessibilityHidden(true)
                    if preset.watermark.style == .text {
                        ResettableSlider(value: $preset.watermark.size, in: ExportWatermark.sizeRange, label: "Watermark size",
                                         format: SliderValueFormat(decimals: 1, unit: "%", scale: 100)) {
                            preset.watermark.size = ExportWatermark().size
                        }
                        Text(String(format: "%.1f%%", preset.watermark.size * 100)).monospacedDigit().frame(width: 44)
                            .accessibilityHidden(true)
                    } else {
                        ResettableSlider(value: $preset.watermark.imageSize, in: ExportWatermark.imageSizeRange,
                                         label: "Watermark graphic size",
                                         format: SliderValueFormat(decimals: 0, unit: "%", scale: 100)) {
                            preset.watermark.imageSize = ExportWatermark().imageSize
                        }
                        Text(String(format: "%.0f%%", preset.watermark.imageSize * 100)).monospacedDigit().frame(width: 44)
                            .accessibilityHidden(true)
                    }
                    Text("Opacity").accessibilityHidden(true)
                    ResettableSlider(value: $preset.watermark.opacity, in: ExportWatermark.opacityRange,
                                     label: "Watermark opacity", format: SliderValueFormat(decimals: 0, unit: "%", scale: 100)) {
                        preset.watermark.opacity = ExportWatermark().opacity
                    }
                    Text(String(format: "%.0f%%", preset.watermark.opacity * 100)).monospacedDigit().frame(width: 38)
                        .accessibilityHidden(true)
                }
                Text(preset.watermark.style == .text
                     ? "Size is a share of the picture's short edge. {year} and {name} are filled in per image."
                     : "Size is the graphic's longer side as a share of the picture's short edge.")
                    .font(.caption).foregroundStyle(.secondary)
                if preset.watermark.isEmpty {
                    Label(preset.watermark.style == .text ? "The watermark has no text, so nothing is stamped."
                          : "No graphic is chosen, so nothing is stamped.",
                          systemImage: "exclamationmark.triangle.fill")
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

/// The watermark text's font: the system font, or an installed family.
struct WatermarkFontPicker: View {
    @Binding var fontName: String?
    @State private var families: [String] = []

    var body: some View {
        Picker("Font", selection: Binding { fontName ?? "" } set: { fontName = $0.isEmpty ? nil : $0 }) {
            Text("System font").tag("")
            if let fontName, !families.contains(fontName) { Text(fontName).tag(fontName) }
            Divider()
            ForEach(families, id: \.self) { Text($0).tag($0) }
        }
        .frame(width: 300)
        .accessibilityLabel("Watermark font")
        .help("The typeface the text is set in. A font later removed from this Mac falls back to the system font.")
        .onAppear { if families.isEmpty { families = NSFontManager.shared.availableFontFamilies } }
    }
}

/// The watermark graphic: a PNG chosen from disk, kept in the preset.
struct WatermarkGraphicPicker: View {
    @Binding var watermark: ExportWatermark
    @State private var problem: String?

    var body: some View {
        HStack {
            if let data = watermark.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 32)
                    .background(Color.gray.opacity(0.3))
                    .accessibilityLabel("Watermark graphic")
            } else {
                Text("No graphic chosen").foregroundStyle(.secondary)
            }
            Button("Choose PNG…") { choose() }
                .accessibilityHint("Picks a PNG logo to stamp on each exported file.")
                .help("A PNG with transparency works best: only its opaque parts are stamped. Up to 4 MB.")
            if watermark.imageData != nil {
                Button("Remove") { watermark.imageData = nil }.controlSize(.small)
            }
            Spacer()
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = "Choose a PNG to use as the watermark"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count <= ExportWatermark.maximumImageBytes,
              ExportWatermark.graphicImage(data) != nil else {
            problem = "That file isn't a PNG of 4 MB or less."
            return
        }
        problem = nil
        watermark.imageData = data
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
