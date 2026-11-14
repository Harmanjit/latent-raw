import SwiftUI
import PixelEngine

/// The clipping overlay's options, in a popover from the clipping
/// triangles under the histogram: what counts as clipped, where, and in
/// which colours. Reset puts back what J has always drawn.
struct ClippingOptionsPopover: View {
    @ObservedObject var settings: ViewingSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clipping Warning").font(.headline)
            Picker("Mode", selection: $settings.clippingOptions.mode) {
                ForEach(ClippingOptions.Mode.allCases) { Text($0.title).tag($0) }
            }
            thresholdRow("Shadows at or below", value: $settings.clippingOptions.shadowThreshold,
                         range: ClippingOptions.shadowRange)
            thresholdRow("Highlights at or above", value: $settings.clippingOptions.highlightThreshold,
                         range: ClippingOptions.highlightRange)
            Picker("Colours", selection: $settings.clippingOptions.scheme) {
                ForEach(ClippingOptions.Scheme.allCases) { Text($0.title).tag($0) }
            }
            Text(settings.clippingOptions.mode == .saturation
                 ? "Saturation marks colours pressed against the gamut: a channel at the top while the colour is strong, or outside Display P3."
                 : "Shows on the image while the triangles (or J) are on.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Reset") { settings.clippingOptions = .standard }
                    .disabled(settings.clippingOptions == .standard)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func thresholdRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: "%.1f%%", value.wrappedValue * 100))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.001)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.1f percent", value.wrappedValue * 100))
        }
    }
}

/// Settings › Viewing: focus peaking's colour and sensitivity, Colour
/// Assessment's border, and the high-quality preview.
struct ViewingSettingsTab: View {
    @ObservedObject private var settings = ViewingSettings.shared

    var body: some View {
        Form {
            Section("Focus peaking") {
                Picker("Colour", selection: $settings.peakingColour) {
                    ForEach(ViewingSettings.PeakingColour.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Sensitivity", selection: $settings.peakingSensitivity) {
                    ForEach(PresentFocusPeaking.Sensitivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("View › Focus Peaking marks sharp edges in Develop, Loupe, Compare and Survey. High also marks softer edges; Low only the crispest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Colour assessment") {
                LabeledContent("Border") {
                    HStack {
                        Slider(value: $settings.assessmentInset, in: ViewingSettings.insetRange, step: 0.01)
                            .accessibilityLabel("Colour assessment border")
                            .accessibilityValue("\(Int((settings.assessmentInset * 100).rounded())) percent")
                        Text("\(Int((settings.assessmentInset * 100).rounded()))%")
                            .font(.system(.body, design: .monospaced)).frame(width: 44, alignment: .trailing)
                    }
                }
                Text("View › Colour Assessment shrinks the image by this share of the view on every side, over 18% grey with a thin white frame, as ISO 12646 asks for judging colour. Your surround comes back when it is off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HighQualityPreviewSettingsSection()
        }
        .formStyle(.grouped)
    }
}

/// View › High Quality Preview, in Settings › Viewing and Settings ›
/// Performance, with what it costs.
struct HighQualityPreviewSettingsSection: View {
    @ObservedObject private var settings = ViewingSettings.shared

    var body: some View {
        Section("High quality preview") {
            Toggle("Render the fitted view at full resolution", isOn: Binding(
                get: { settings.highQualityPreview },
                set: { on in
                    guard on != settings.highQualityPreview else { return }
                    settings.highQualityPreview = on
                    let editor = MainWindowModels.shared.model
                    settings.setPrimaryEditor(editor)
                    editor.highQualityPreviewSettingChanged()
                }))
            Text("Off by default. On, Develop and Loupe redraw the fitted view from a full-resolution render shrunk with the export's Lanczos filter, half a second after an edit settles: sharper, and closer to what an export gives. Each one briefly needs several hundred megabytes of GPU memory for a 24 MP photo (more for larger sensors), which on a 16 GB Mac can push other apps into swap; leave it off there if things slow down.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
