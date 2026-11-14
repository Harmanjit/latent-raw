import SwiftUI
import AppKit
import PixelEngine
import Catalog

/// Border: pads each exported picture by a border, optionally out to an
/// aspect ratio (a 4:5 canvas for a landscape photo, say), with an inner
/// line, after the resize and before the watermark (ExportBorder.swift).
/// Off by default.
struct ExportBorderSection: View {
    @Binding var preset: ExportPreset

    private var border: Binding<ExportBorder> { $preset.formats.border }

    var body: some View {
        Toggle("Border", isOn: $preset.formats.borderEnabled)
            .accessibilityHint("Adds a border round each exported picture, or enlarges its canvas to an aspect ratio.")
            .help("Pads each file with a border in a colour of your choice, or enlarges the canvas to a shape such "
                  + "as 1:1 or 4:5 without cropping the photo. Drawn after the resize, so the picture keeps the "
                  + "size asked for, and before the watermark.")
        if preset.formats.borderEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Size").accessibilityHidden(true)
                    TextField("5", value: border.size, format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 56)
                        .accessibilityLabel("Border size")
                    Picker("Unit", selection: border.unit) {
                        ForEach(ExportBorder.SizeUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                    .accessibilityLabel("Border size unit")
                    Spacer()
                    ColorPicker("Colour", selection: colorBinding(border.color), supportsOpacity: false)
                        .accessibilityLabel("Border colour")
                }
                HStack {
                    Picker("Canvas", selection: border.aspect) {
                        ForEach(ExportBorder.Aspect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(width: 200)
                    .help("The canvas grows on the short sides until it has this shape; the border is the least "
                          + "it adds on any side.")
                    if preset.formats.border.aspect == .custom {
                        TextField("W", value: border.customWidth, format: .number).frame(width: 40)
                            .accessibilityLabel("Custom ratio width")
                        Text(":").accessibilityHidden(true)
                        TextField("H", value: border.customHeight, format: .number).frame(width: 40)
                            .accessibilityLabel("Custom ratio height")
                    }
                    if preset.formats.border.aspect != .none {
                        Picker("Turned", selection: border.orientation) {
                            ForEach(ExportBorder.Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        .accessibilityLabel("Canvas orientation")
                    }
                    Spacer()
                }
                if preset.formats.border.aspect != .none {
                    HStack {
                        Text("Position").accessibilityHidden(true)
                        Slider(value: border.positionX, in: 0...1) { Text("Across") }
                            .frame(width: 130)
                            .accessibilityLabel("Picture position across")
                        Slider(value: border.positionY, in: 0...1) { Text("Down") }
                            .frame(width: 130)
                            .accessibilityLabel("Picture position down")
                        Button("Centre") { border.wrappedValue.positionX = 0.5; border.wrappedValue.positionY = 0.5 }
                            .controlSize(.small)
                        Spacer()
                    }
                }
                HStack {
                    Text("Inner line").accessibilityHidden(true)
                    TextField("0", value: border.lineWidth, format: .number).frame(width: 44)
                        .accessibilityLabel("Inner line width in pixels")
                    Text("px, gap").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("0", value: border.lineOffset, format: .number).frame(width: 44)
                        .accessibilityLabel("Gap between picture and line in pixels")
                    Text("px").foregroundStyle(.secondary).accessibilityHidden(true)
                    Spacer()
                    ColorPicker("Line colour", selection: colorBinding(border.lineColor), supportsOpacity: false)
                        .disabled(preset.formats.border.lineWidth <= 0)
                        .accessibilityLabel("Inner line colour")
                }
                if preset.hdrGainMap, preset.format.supportsGainMap || preset.format.supportsFullHDR,
                   preset.formats.border.isActive {
                    Text("A bordered file is written in SDR: HDR Output is left out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 20)
        }
    }

    /// A stored sRGB colour as a SwiftUI colour, and back.
    private func colorBinding(_ stored: Binding<SheetColor>) -> Binding<Color> {
        Binding {
            Color(.sRGB, red: stored.wrappedValue.red, green: stored.wrappedValue.green, blue: stored.wrappedValue.blue)
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            stored.wrappedValue = SheetColor(red: min(max(srgb.redComponent, 0), 1),
                                             green: min(max(srgb.greenComponent, 0), 1),
                                             blue: min(max(srgb.blueComponent, 0), 1))
        }
    }
}

/// PDF: the page each photo is drawn on, its margin and caption.
struct ExportPDFSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        HStack {
            Picker("Page", selection: $preset.formats.pdf.pageSize) {
                ForEach(ExportPDFOptions.PageSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 220)
            .help("Fit to image makes the page the photo's own size at 300 ppi (or the Resolution set for images). "
                  + "A4, US Letter and A3 turn to match the photo.")
            Text("Margin").accessibilityHidden(true)
            TextField("10", value: $preset.formats.pdf.marginMM, format: .number).frame(width: 44)
                .accessibilityLabel("Margin in millimetres")
            Text("mm").foregroundStyle(.secondary).accessibilityHidden(true)
            Spacer()
        }
        HStack {
            Text("Caption")
            TextField("none", text: $preset.formats.pdf.captionTemplate)
                .accessibilityLabel("Caption template")
                .help("A line under the photo, in the same tokens as the file name. Leave empty for none.")
            Menu("Insert") {
                ForEach(ExportNaming.tokens, id: \.token) { t in
                    Button("\(t.token)  \(t.meaning)") { preset.formats.pdf.captionTemplate += t.token }
                }
            }
            .fixedSize()
            .accessibilityLabel("Insert a caption token")
        }
    }
}
