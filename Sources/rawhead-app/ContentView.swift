import SwiftUI
import Metal
import PixelEngine
import ColorKit

/// Layout follows Lightroom's Develop module, which is what people expect:
/// image centred on a neutral surround, histogram at the top of the right
/// panel, adjustments below it, status along the bottom. Panel order also
/// follows Lightroom — white balance first, then tone — because that's the
/// order the adjustments actually want to be made in.
///
/// Sections that aren't reached for often are collapsed by default. As more
/// panels arrive (lens corrections, detail, grading) the same pattern keeps
/// the panel from becoming a wall of sliders.
///
/// Left-hand panel (navigator, presets, collections) is deliberately absent
/// until there's something to put in it — that's Phase 2, when catalogs
/// arrive.
struct ContentView: View {
    @StateObject private var model = EditorModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                imageArea
                Divider()
                adjustmentPanel
                    .frame(width: 280)
            }
            Divider()
            statusBar
        }
        .onAppear {
            // Developer convenience: `swift run rawhead-app photo.nef` opens
            // the file straight away, skipping the Open dialog.
            if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                model.open(url: URL(fileURLWithPath: path))
            }
        }
    }

    private var imageArea: some View {
        ZStack {
            Color(white: 0.12)

            if let device = model.device, let presenter = model.presenter,
               let preview = model.preview {
                MetalImageView(preview: preview,
                                tile: model.tile,
                                transform: model.viewport,
                                presenter: presenter,
                                device: device,
                                onResize: { model.viewportDidResize(to: $0) },
                                onHeadroomChange: { model.displayHeadroomDidChange(to: $0) },
                                backgroundLevel: model.backgroundLevel,
                                onZoom: { model.zoom(by: $0, about: $1) },
                                onPan: { model.pan(by: $0) },
                                onDoubleClick: { model.toggleZoom(at: $0) })
            } else {
                VStack(spacing: 12) {
                    Text(model.isReady ? "No image open" : "Metal unavailable")
                        .foregroundStyle(.secondary)
                    if model.isReady {
                        Button("Open Raw File…") { model.showOpenPanel() }
                    }
                }
            }

            if model.isExporting {
                Color.black.opacity(0.4)
                ProgressView("Exporting…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var adjustmentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    HistogramView(histogram: model.histogram)
                    ClippingReadout(histogram: model.histogram)
                }

                if let title = model.imageTitle {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                section("White Balance") {
                    temperatureRow
                    sliderRow(title: "Tint",
                               value: $model.parameters.whiteBalance.tint,
                               range: ColorKit.WhiteBalance.tintRange,
                               format: "%+.0f")
                    HStack {
                        Button("As Shot") { model.resetWhiteBalance() }
                            .controlSize(.small)
                            .disabled(!model.hasImage)
                        Spacer()
                        Text(String(format: "camera: %.0fK %+.0f",
                                     model.asShotWhiteBalance.temperature,
                                     model.asShotWhiteBalance.tint))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Tone") {
                    sliderRow(title: "Exposure",
                               value: $model.parameters.exposureEV,
                               range: -5...5, format: "%+.2f EV")
                    sliderRow(title: "Contrast",
                               value: $model.parameters.contrast,
                               range: 0.5...3.0, format: "%.2f")
                    sliderRow(title: "Mid Grey",
                               value: $model.parameters.greyPoint,
                               range: 0.05...0.5, format: "%.3f")

                    Toggle(isOn: $model.hdrDisplayEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HDR display")
                                .font(.subheadline)
                            Text(model.displayHasHeadroom
                                 ? String(format: "this screen: %.1f× above white", model.displayHeadroom)
                                 : "this screen has no HDR headroom")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.hasImage || !model.displayHasHeadroom)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        sliderRow(title: "Recovery",
                                   value: $model.parameters.highlightRecovery,
                                   range: 0...1, format: "%.2f")
                        sliderRow(title: "Threshold",
                                   value: $model.parameters.highlightThreshold,
                                   range: 0.5...1.0, format: "%.2f")
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Highlight Reconstruction")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Demosaic", selection: $model.parameters.demosaic) {
                            ForEach(DemosaicMethod.allCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        Text("Only affects full-resolution renders — export and 100% zoom. The fit-to-window preview bins Bayer quads and never interpolates.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Detail")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Format", selection: $model.exportSettings.format) {
                            ForEach(ExportSettings.Format.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if model.exportSettings.format.supportsQuality {
                            sliderRow(title: "Quality",
                                       value: $model.exportSettings.quality,
                                       range: 0.3...1.0, format: "%.2f")
                        }

                        Button("Export…") { model.showExportPanel() }
                            .disabled(!model.hasImage || model.isExporting)
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Export")
                }

                Button("Reset All") { model.resetAdjustments() }
                    .disabled(!model.hasImage)

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    /// Temperature gets its own row because the slider travels in mired
    /// while reading out in Kelvin, and its range is centred on this
    /// image's as-shot value rather than being fixed — see ColorKit.
    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Temperature").font(.subheadline)
                Spacer()
                Text(String(format: "%.0f K", model.parameters.whiteBalance.temperature))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: model.temperatureSliderBinding,
                    in: model.temperatureSliderRange)
        }
        .disabled(!model.hasImage)
    }

    private func disclosureLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func section<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            disclosureLabel(title)
            content()
        }
    }

    private func sliderRow(title: String, value: Binding<Float>,
                            range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .disabled(!model.hasImage)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button("Open…") { model.showOpenPanel() }
                .controlSize(.small)
                .disabled(!model.isReady)

            Text(model.setupError ?? model.status)
                .font(.caption)
                .foregroundStyle(model.setupError == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Zoom controls. Pinch, option-scroll and double-click do the
            // same things from the image itself; these exist for the
            // keyboard and for people who like buttons.
            HStack(spacing: 6) {
                Button("−") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Text(model.zoomLabel)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 40)
                Button("+") { model.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Fit") { model.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("100%") { model.zoomToActualSize() }
                    .keyboardShortcut("1", modifiers: .command)
            }
            .controlSize(.small)
            .disabled(!model.hasImage)

            if !model.renderReport.isEmpty {
                // What the last action rendered and how long it took, on
                // screen during development: the Phase 1 exit criterion is
                // under 16ms at fit-to-window, and having it visible while
                // dragging a slider is the only honest way to judge that.
                // "no render" means the presenter just redrew, which is
                // the cheap path pans are supposed to take.
                Text(model.renderReport)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.lastRenderMs < 16 ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
