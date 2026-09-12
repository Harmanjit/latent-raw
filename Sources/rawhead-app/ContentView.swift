import SwiftUI
import Metal
import PixelEngine
import ColorKit
import Catalog
import UniformTypeIdentifiers

/// Which half of the app is showing. Same two-mode shape as Lightroom's
/// Library and Develop modules.
enum AppMode: String, CaseIterable, Identifiable {
    case library, develop
    var id: String { rawValue }
    var title: String { self == .library ? "Library" : "Develop" }
}

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
    @StateObject private var library = Library()
    @State private var mode: AppMode = .library

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LibraryPanel(library: library, onOpenFolder: showOpenFolderPanel,
                             onRate: rate, onFlag: flag)
                Divider()
                switch mode {
                case .library:
                    ThumbnailGridView(library: library, onOpen: openInEditor)
                case .develop:
                    imageArea
                    Divider()
                    adjustmentPanel
                        .frame(width: 280)
                }
            }
            Divider()
            statusBar
        }
        .background(navigationShortcuts)
        .onAppear {
            // Developer convenience: `swift run rawhead-app <folder-or-file>`
            // opens it straight away, skipping the dialogs.
            if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                if isDir.boolValue {
                    openFolder(URL(fileURLWithPath: path, isDirectory: true))
                } else {
                    model.open(url: URL(fileURLWithPath: path))
                    mode = .develop
                }
            }
        }
    }

    // MARK: - Library wiring

    private func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of raw files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    private func openFolder(_ url: URL) {
        mode = .library
        Task {
            do { try await library.open(folder: url) }
            catch { model.reportError("Could not open folder: \(error)") }
        }
    }

    private func openInEditor(_ record: ImageRecord) {
        guard let url = library.fileURL(for: record) else { return }
        library.selectedImageID = record.id
        model.open(url: url, userRotation: record.userRotation)
        mode = .develop
    }

    // MARK: - Metadata shortcuts (both modes)

    private func rate(_ stars: Int) {
        Task { try? await library.setRating(stars) }
    }

    private func flag(_ flag: ImageFlag) {
        Task { try? await library.setFlag(flag) }
    }

    /// Rotates the selected image in the catalog and, if it's the one in
    /// the editor, on screen too.
    private func rotate(by quarterTurns: Int) {
        Task {
            try? await library.rotateSelected(by: quarterTurns)
            if let selected = library.selectedImage,
               model.imageTitle == selected.fileName {
                model.setUserRotation(selected.userRotation)
            }
        }
    }

    /// Left/right arrows step through the catalog; in Develop that also
    /// loads the image, so you can flick through a shoot without going
    /// back to the grid. Return opens the selection. Hidden buttons are
    /// the least fussy way to get app-wide key handling in SwiftUI.
    private var navigationShortcuts: some View {
        Group {
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") {
                if let selected = library.selectedImage { openInEditor(selected) }
            }.keyboardShortcut(.return, modifiers: [])
            Button("") { mode = .library }.keyboardShortcut("g", modifiers: [])
            Button("") {
                if model.hasImage { mode = .develop }
            }.keyboardShortcut("d", modifiers: [])

            // Ratings 0-5, flags P/X/U, rotation Cmd-[ / Cmd-] — the same
            // keys Lightroom uses, so muscle memory carries over.
            ForEach(0...5, id: \.self) { stars in
                Button("") { rate(stars) }
                    .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: [])
            }
            Button("") { flag(.picked) }.keyboardShortcut("p", modifiers: [])
            Button("") { flag(.rejected) }.keyboardShortcut("x", modifiers: [])
            Button("") { flag(.none) }.keyboardShortcut("u", modifiers: [])
            Button("") { rotate(by: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("") { rotate(by: 1) }.keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func step(_ offset: Int) {
        guard let record = library.moveSelection(by: offset) else { return }
        if mode == .develop { openInEditor(record) }
    }

    private var imageArea: some View {
        ZStack {
            Color(white: 0.12)

            if let device = model.device, let presenter = model.presenter,
               let preview = model.preview {
                MetalImageView(preview: preview,
                                tile: model.tile,
                                transform: model.viewport,
                                rotation: model.rotation,
                                sensorSize: model.sensorSize,
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
                ScopePanel(model: model)

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

                    // Only offered on screens that can actually show more
                    // than paper white; on an SDR display it would be a
                    // switch that does nothing.
                    if model.displayHasHeadroom {
                        Toggle(isOn: $model.hdrDisplayEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HDR display")
                                    .font(.subheadline)
                                Text(String(format: "this screen: %.1f× above white",
                                            model.displayHeadroom))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!model.hasImage)
                    }
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
            Picker("Mode", selection: $mode) {
                ForEach(AppMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)

            Button("Open File…") { model.showOpenPanel(); mode = .develop }
                .controlSize(.small)
                .disabled(!model.isReady)

            HStack(spacing: 4) {
                Button("↺") { rotate(by: -1) }
                Button("↻") { rotate(by: 1) }
            }
            .controlSize(.small)
            .disabled(library.selectedImage == nil)
            .help("Rotate the selected image (⌘[ and ⌘]). Remembered in the catalog.")

            Text(model.setupError ?? (mode == .library ? library.statusText : model.status))
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
            .disabled(!model.hasImage || mode != .develop)

            if !model.renderReport.isEmpty && mode == .develop {
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
