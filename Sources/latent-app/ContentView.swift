import SwiftUI
import Metal
import PixelEngine
import MLKit
import ColorKit
import Catalog
import LensKit
import UniformTypeIdentifiers

/// Which half of the app is showing. Same two-mode shape as Lightroom's
/// Library and Develop modules.
enum AppMode: String, CaseIterable, Identifiable {
    case library, loupe, compare, develop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "Library"
        case .loupe: "Loupe"
        case .compare: "Compare"
        case .develop: "Develop"
        }
    }
    /// Modes that show a rendered image and so support zoom controls.
    var showsImage: Bool { self != .library }
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
    @StateObject private var exportQueue = ExportQueue()
    @State private var mode: AppMode = .library
    @State private var showingExportSheet = false
    /// Compare's left pane ("Select"): its own render, created the first
    /// time Compare opens. The right pane ("Candidate") is the main model,
    /// which follows the selection as arrow keys move it.
    @State private var compareModel: EditorModel?
    @State private var whiteBalanceExpanded = true
    @State private var toneExpanded = true
    @State private var cropExpanded = false
    @State private var presenceExpanded = true
    @State private var healExpanded = false
    @State private var compareRecord: ImageRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LibraryPanel(library: library, exportQueue: exportQueue, model: model,
                             onOpenFolder: showOpenFolderPanel,
                             onRate: rate, onFlag: flag,
                             onExport: { showingExportSheet = true },
                             presets: model.presets,
                             onApplyPreset: { applyPresetToSelection($0) },
                             onPaste: { pasteSettings() })
                Divider()
                switch mode {
                case .library:
                    VStack(spacing: 0) {
                        FilterBar(library: library)
                        Divider()
                        ThumbnailGridView(library: library, onOpen: openInEditor)
                    }
                    .onDisappear { model.flushPendingSave() }
                case .loupe:
                    VStack(spacing: 0) {
                        ImageViewport(model: model, allowsTools: false)
                        Divider()
                        ImageCaption(record: library.selectedImage)
                    }
                case .compare:
                    compareArea
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
        .onChange(of: mode) { old, _ in modeDidChange(from: old) }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(count: library.selectedImageIDs.count) { preset, destination in
                guard let gpu = model.gpu else { return }
                // Flush the editor's pending edit so the export sees it.
                model.flushPendingSave()
                exportQueue.start(records: library.selectedImages, library: library,
                                  preset: preset, destination: destination, gpu: gpu)
            }
        }
        .onAppear {
            LensfunDatabase.warmUp()
            wireEditSaving()
            if let gpu = model.gpu {
                library.thumbnailRenderer = PipelineThumbnailRenderer(gpu: gpu)
            }
            // Developer convenience: `swift run latent-app <folder-or-file>`
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
        load(record)
        mode = .develop
    }

    /// Loads `record` (with its stored edit, history and snapshots) into
    /// the main editor model and makes it the selection. Used by Develop,
    /// Loupe and Compare's candidate pane alike.
    private func load(_ record: ImageRecord) {
        guard let url = library.fileURL(for: record) else { return }
        library.selectedImageID = record.id
        Task {
            let stack = await library.editStack(for: record)
            model.open(url: url, userRotation: record.userRotation,
                       catalogImageID: record.id, editStackJSON: stack)
            // History and snapshots follow, from the catalog.
            let steps = await library.history(for: record)
            let snaps = await library.snapshots(for: record)
            if model.catalogImageID == record.id {
                model.loadHistory(steps: steps, snapshots: snaps)
            }
        }
    }

    /// Loads a record into Compare's left pane. No catalog id is passed,
    /// so that model never writes edits; it's a viewer.
    private func loadCompareSelect(_ record: ImageRecord) {
        guard let url = library.fileURL(for: record) else { return }
        if compareModel == nil { compareModel = EditorModel() }
        compareRecord = record
        Task {
            let stack = await library.editStack(for: record)
            compareModel?.open(url: url, userRotation: record.userRotation,
                               catalogImageID: nil, editStackJSON: stack)
        }
    }

    /// Entering Loupe or Compare from the grid renders the selection;
    /// leaving Develop flushes edits. Compare's Select pane starts as the
    /// other selected image if there is one, else the same image, and
    /// arrow keys then walk the Candidate.
    private func modeDidChange(from old: AppMode) {
        if old == .develop {
            model.flushPendingSave()
            // Loupe and Compare share the viewport; a click there must
            // never place a patch or move a crop.
            model.disarmTools()
        }
        guard mode != .library, let selected = library.selectedImage else { return }
        if model.catalogImageID != selected.id { load(selected) }
        if mode == .compare {
            let other = library.selectedImages.first { $0.id != selected.id }
            loadCompareSelect(other ?? compareRecord ?? selected)
        }
    }

    /// Promote the candidate to the Select side, or swap the two.
    private func compareMakeSelect() {
        guard let candidate = library.selectedImage else { return }
        loadCompareSelect(candidate)
    }

    private func compareSwap() {
        guard let candidate = library.selectedImage, let select = compareRecord else { return }
        loadCompareSelect(candidate)
        load(select)
    }

    private var compareArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                VStack(spacing: 0) {
                    if let compareModel {
                        ImageViewport(model: compareModel, mirror: model, allowsTools: false)
                    } else {
                        Color(white: 0.12)
                    }
                    Divider()
                    ImageCaption(record: compareRecord, title: "Select")
                }
                VStack(spacing: 0) {
                    ImageViewport(model: model, mirror: compareModel, allowsTools: false)
                    Divider()
                    ImageCaption(record: library.selectedImage, title: "Candidate")
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("Make Select") { compareMakeSelect() }
                    .help("Promote the candidate to the left pane (⇧X)")
                    .keyboardShortcut("x", modifiers: .shift)
                Button("Swap") { compareSwap() }
                    .help("Exchange the two panes")
                Text("← → step the candidate · rating and flag keys act on it · zoom and pan move both")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    /// Edits settle in the editor and land in the catalog here; so do
    /// history steps and snapshots.
    private func wireEditSaving() {
        model.onEditSettled = { imageID, json in
            Task {
                try? await library.saveEditStack(json, schemaVersion: EditStack.schemaVersion,
                                                  processVersion: EditStack.processVersion,
                                                  forImageID: imageID)
            }
        }
        model.onHistoryChanged = { imageID, steps in
            Task { try? await library.setHistory(steps, forImageID: imageID) }
        }
        model.onSnapshotsChanged = { imageID, snapshots in
            Task { try? await library.setSnapshots(snapshots, forImageID: imageID) }
        }
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
                if model.hasImage || library.selectedImage != nil { mode = .develop }
            }.keyboardShortcut("d", modifiers: [])
            // Culling views: E for loupe, C for compare, space toggles
            // grid ↔ loupe, Z toggles fit ↔ 100% (Lightroom's keys).
            Button("") {
                if library.selectedImage != nil { mode = .loupe }
            }.keyboardShortcut("e", modifiers: [])
            Button("") {
                if library.selectedImage != nil { mode = .compare }
            }.keyboardShortcut("c", modifiers: [])
            Button("") {
                if mode == .library, library.selectedImage != nil { mode = .loupe }
                else if mode == .loupe { mode = .library }
            }.keyboardShortcut(.space, modifiers: [])
            Button("") {
                guard mode.showsImage else { return }
                model.toggleZoomAtCenter()
                if mode == .compare { compareModel?.toggleZoomAtCenter() }
            }.keyboardShortcut("z", modifiers: [])

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

            // Settings clipboard: copy from the editor, paste to the editor
            // or to the whole Library selection.
            Button("") { copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("") { if model.hasImage { model.showingBefore.toggle() } }
                .keyboardShortcut("\\", modifiers: [])
            Button("") {
                guard mode == .develop, model.hasImage else { return }
                model.cropToolActive.toggle()
                if model.cropToolActive { cropExpanded = true }
            }.keyboardShortcut("r", modifiers: [])
            Button("") {
                guard mode == .develop, model.hasImage else { return }
                model.healToolActive.toggle()
                if model.healToolActive { healExpanded = true }
            }.keyboardShortcut("h", modifiers: [])
            Button("") {
                if model.healToolActive { model.deleteSelectedHeal() }
            }.keyboardShortcut(.delete, modifiers: [])
            Button("") { model.disarmTools() }.keyboardShortcut(.escape, modifiers: [])
            Button("") { model.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - Settings clipboard and presets, in either mode

    private func copySettings() {
        if mode == .develop || library.selectedImageIDs.count <= 1, model.hasImage {
            model.copySettings()
        } else if let first = library.selectedImage {
            // In the grid with nothing open: copy the primary selection's stored edit.
            Task {
                guard let json = await library.editStack(for: first),
                      let stack = try? EditStack.decode(json: json) else { return }
                let restricted = stack.restricted(to: model.pasteGroups)
                if let text = try? restricted.encodeJSON() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: EditorModel.pasteboardType)
                    NSPasteboard.general.setString(text, forType: .string)
                    model.reportError("Copied settings from \(first.fileName)")
                }
            }
        }
    }

    private func pasteSettings() {
        guard let stack = EditorModel.clipboardStack() else { model.reportError("Nothing to paste"); return }
        applyToSelectionOrEditor(stack, groups: model.pasteGroups, what: "Pasted")
    }

    /// Develop: apply to the open image. Library with several selected:
    /// apply to each stored edit, regenerating thumbnails.
    private func applyToSelectionOrEditor(_ stack: EditStack, groups: Set<EditGroup>, what: String) {
        if mode == .develop && model.hasImage {
            model.apply(stack, groups: groups)
            return
        }
        Task {
            let n = try? await library.transformSelectedEdits(
                schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion
            ) { existing in
                let current = existing.flatMap { try? EditStack.decode(json: $0) } ?? EditStack()
                let merged = current.merged(with: stack, groups: groups)
                return merged == EditStack() ? nil : (try? merged.encodeJSON())
            }
            model.reportError("\(what) settings to \(n ?? 0) image\((n ?? 0) == 1 ? "" : "s")")
            // If the open image was among them, reload its sliders.
            if let selected = library.selectedImage, model.imageTitle == selected.fileName,
               library.selectedImageIDs.contains(selected.id ?? -1) {
                model.apply(stack, groups: groups)
            }
        }
    }

    private func applyPresetToSelection(_ preset: Preset) {
        applyToSelectionOrEditor(preset.stack, groups: preset.groups, what: "Applied “\(preset.name)” —")
    }

    private func step(_ offset: Int) {
        guard let record = library.moveSelection(by: offset) else { return }
        if mode.showsImage { load(record) }
    }

    private var imageArea: some View {
        ZStack {
            ImageViewport(model: model)
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

                DisclosureGroup(isExpanded: $whiteBalanceExpanded) {
                    whiteBalanceSection.padding(.top, 8)
                } label: {
                    disclosureLabel("White Balance")
                }

                DisclosureGroup(isExpanded: $toneExpanded) {
                    toneSection.padding(.top, 8)
                } label: {
                    disclosureLabel("Tone")
                }

                DisclosureGroup(isExpanded: $presenceExpanded) {
                    presenceSection.padding(.top, 8)
                } label: {
                    disclosureLabel("Presence")
                }

                DisclosureGroup(isExpanded: $cropExpanded) {
                    cropSection.padding(.top, 8)
                } label: {
                    HStack {
                        disclosureLabel("Crop & Straighten")
                        if model.cropToolActive { activeToolBadge }
                    }
                }

                DisclosureGroup(isExpanded: $healExpanded) {
                    healSection.padding(.top, 8)
                } label: {
                    HStack {
                        disclosureLabel("Spot Removal")
                        if model.healToolActive { activeToolBadge }
                    }
                }

                EmptyView()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        sliderRow(title: "Recovery",
                                   value: $model.parameters.highlightRecovery,
                                   range: 0...1, format: "%.2f", defaultValue: 1.0)
                        sliderRow(title: "Threshold",
                                   value: $model.parameters.highlightThreshold,
                                   range: 0.5...1.0, format: "%.2f", defaultValue: 0.85)
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Highlight Reconstruction")
                }

                DisclosureGroup {
                    PresetsPanel(model: model, onApply: { applyPresetToSelection($0) })
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Presets & Clipboard")
                }

                DisclosureGroup {
                    LocalAdjustmentsPanel(model: model)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Local Adjustments")
                }

                DisclosureGroup {
                    CurveEditor(curve: $model.parameters.toneCurve)
                        .disabled(!model.hasImage)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Tone Curve")
                }

                DisclosureGroup {
                    HSLPanel(hsl: $model.parameters.hsl)
                        .disabled(!model.hasImage)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("HSL / Colour")
                }

                DisclosureGroup {
                    SplitToningPanel(toning: $model.parameters.splitToning)
                        .disabled(!model.hasImage)
                        .padding(.top, 8)
                } label: {
                    disclosureLabel("Split Toning")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.lensProfileDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Distortion", isOn: $model.parameters.lensDistortion)
                        Toggle("Chromatic aberration", isOn: $model.parameters.lensTCA)
                        Toggle("Vignetting", isOn: $model.parameters.lensVignetting)
                        disclosureLabel("Manual")
                        sliderRow(title: "Distortion", value: $model.parameters.manualDistortion,
                                  range: -0.1...0.1, format: "%+.3f")
                        sliderRow(title: "Vignetting", value: $model.parameters.manualVignetting,
                                  range: -1...1, format: "%+.2f")
                        disclosureLabel("Defringe")
                        sliderRow(title: "Purple", value: $model.parameters.defringePurple,
                                  range: 0...1, format: "%.2f")
                        sliderRow(title: "Green", value: $model.parameters.defringeGreen,
                                  range: 0...1, format: "%.2f")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.hasImage)
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Lens Corrections")
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

                        disclosureLabel("Sharpening")
                        sliderRow(title: "Amount", value: $model.parameters.sharpenAmount,
                                  range: 0...2, format: "%.2f")
                        sliderRow(title: "Radius", value: $model.parameters.sharpenRadius,
                                  range: 0.5...3, format: "%.1f px", defaultValue: 1.0)
                        sliderRow(title: "Threshold", value: $model.parameters.sharpenThreshold,
                                  range: 0...0.1, format: "%.3f", defaultValue: 0.01)

                        disclosureLabel("Noise Reduction")
                        sliderRow(title: "Luminance", value: $model.parameters.denoiseLuminance,
                                  range: 0...1, format: "%.2f")
                        sliderRow(title: "Colour", value: $model.parameters.denoiseColor,
                                  range: 0...1, format: "%.2f")
                        Text("Judge both at 100% zoom; the fit-to-window preview is scaled to match but hides fine grain.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Detail")
                }

                DisclosureGroup {
                    aiDenoiseSection.padding(.top, 8)
                } label: {
                    disclosureLabel("AI Noise Reduction")
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Soft proof", isOn: $model.proofEnabled)
                            .toggleStyle(.switch).controlSize(.small)
                        Picker("Target", selection: Binding(
                            get: { model.proofTarget == .sRGB ? 0 : model.proofTarget == .displayP3 ? 1 : 2 },
                            set: { v in
                                if v == 0 { model.proofTarget = .sRGB }
                                else if v == 1 { model.proofTarget = .displayP3 }
                                else { model.chooseProofProfile() }
                            })) {
                            Text("sRGB").tag(0)
                            Text("Display P3").tag(1)
                            Text(model.proofTarget.displayName == "sRGB" || model.proofTarget.displayName == "Display P3"
                                 ? "ICC profile…" : model.proofTarget.displayName + "…").tag(2)
                        }
                        .pickerStyle(.menu).labelsHidden().controlSize(.small)
                        Toggle("Gamut warning (grey = can't be reproduced)", isOn: $model.gamutWarning)
                            .toggleStyle(.checkbox).controlSize(.small)
                        if !model.proofStatus.isEmpty {
                            Text(model.proofStatus).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Shows what the file will look like in the target's gamut. HDR headroom is off while proofing.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(!model.hasImage)
                    .padding(.top, 8)
                } label: {
                    disclosureLabel("Soft Proof")
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
            ResettableSlider(value: model.temperatureSliderBinding,
                             in: model.temperatureSliderRange) { model.resetWhiteBalance() }
                .help("Double-click for the camera's white balance")
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

    private var whiteBalanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {

                    temperatureRow
                    sliderRow(title: "Tint",
                               value: $model.parameters.whiteBalance.tint,
                               range: ColorKit.WhiteBalance.tintRange,
                               format: "%+.0f", defaultValue: model.asShotWhiteBalance.tint)
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
    }

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: 10) {

                    HStack {
                        Button("Auto") { model.autoAdjust() }
                            .controlSize(.small)
                            .keyboardShortcut("u", modifiers: .command)
                            .disabled(!model.hasImage)
                            .help("Estimate exposure, contrast and white balance from the image (⌘U)")
                        Spacer()
                    }
                    sliderRow(title: "Exposure",
                               value: $model.parameters.exposureEV,
                               range: -5...5, format: "%+.2f EV")
                    sliderRow(title: "Contrast",
                               value: $model.parameters.contrast,
                               range: 0.5...3.0, format: "%.2f", defaultValue: 1.5)
                    sliderRow(title: "Mid Grey",
                               value: $model.parameters.greyPoint,
                               range: 0.05...0.5, format: "%.3f", defaultValue: 0.1845)

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
    }

    /// Texture, clarity, dehaze and vibrance: the controls people reach
    /// for on most images, so this group starts open.
    private var presenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(title: "Texture", value: $model.parameters.texture, range: -1...1, format: "%+.2f")
            sliderRow(title: "Clarity", value: $model.parameters.clarity, range: -1...1, format: "%+.2f")
            sliderRow(title: "Dehaze", value: $model.parameters.dehaze, range: -1...1, format: "%+.2f")
            sliderRow(title: "Vibrance", value: $model.parameters.vibrance, range: -1...1, format: "%+.2f")
        }
    }

    /// Neural denoise: one run per image (cached with the session), then
    /// the strength blends it in instantly.
    private var aiDenoiseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(title: "Strength",
                      value: Binding(get: { model.aiDenoiseStrength }, set: { model.aiDenoiseStrength = $0 }),
                      range: 0...1, format: "%.2f")
            HStack {
                if model.aiDenoiseRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelAIDenoise() }
                } else {
                    Button(model.hasAIDenoiseResult ? "Run again" : "Denoise") { model.runAIDenoise() }
                        .disabled(!model.hasImage || !model.aiDenoiseAvailable)
                }
                Spacer()
            }
            .controlSize(.small)
            if !model.aiDenoiseStatus.isEmpty {
                Text(model.aiDenoiseStatus).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Model", selection: $model.aiDenoiseVariant) {
                ForEach(AIDenoiser.Variant.allCases.filter { $0.isAvailable }, id: \.self) { v in
                    Text(v.displayName).tag(v)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            // Optional larger model, fetched on request so the app stays small.
            HStack {
                if let p = model.modelDownloadProgress {
                    ProgressView(value: p).controlSize(.small)
                    Button("Cancel") { model.cancelModelDownload() }
                } else if model.highQualityModelInstalled {
                    Text("High-quality model installed").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { model.removeHighQualityModel() }
                } else {
                    Button("Download high-quality model (\(OptionalModel.nafnetWidth64.sizeMB) MB)") {
                        model.downloadHighQualityModel()
                    }
                }
            }
            .controlSize(.small)
            if !model.modelDownloadStatus.isEmpty {
                Text(model.modelDownloadStatus).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("NAFNet (SIDD) on the GPU, in camera space before colour. Standard: ~11 s per 24 MP frame; high quality: ~2.5× longer, slightly cleaner. The result is kept while the image is open and recomputed on export.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Marks a group whose tool is armed on the image.
    private var activeToolBadge: some View {
        Text("ON")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }

    /// Crop & straighten. R opens and closes the tool; the rectangle is
    /// edited on the image, the angle here.
    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.cropToolActive) {
                    Text(model.cropToolActive ? "Cropping: on" : "Crop…")
                }
                .toggleStyle(.button)
                .help("Show the crop rectangle on the image (R)")
                Picker("Aspect", selection: Binding(
                    get: { CropAspectOption.matching(model.cropAspectDisplayRatio, original: model.originalDisplayRatio) },
                    set: { model.setCropAspect(displayRatio: $0.ratio(original: model.originalDisplayRatio)) })) {
                    ForEach(CropAspectOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)
                Spacer()
                Button("Reset") { model.resetCrop() }
                    .disabled(model.parameters.crop == .none && model.parameters.perspective.isIdentity)
            }
            .controlSize(.small)
            .disabled(!model.hasImage)

            sliderRow(title: "Straighten",
                      value: Binding(get: { model.parameters.crop.angle },
                                     set: { model.setStraighten($0) }),
                      range: -45...45, format: "%.2f°")
            disclosureLabel("Perspective")
            sliderRow(title: "Vertical", value: $model.parameters.perspective.vertical,
                      range: -1...1, format: "%+.2f")
            sliderRow(title: "Horizontal", value: $model.parameters.perspective.horizontal,
                      range: -1...1, format: "%+.2f")

            if model.hasImage {
                let s = model.croppedPixelSize
                Text("\(Int(s.width.rounded())) × \(Int(s.height.rounded())) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Spot removal. H opens the tool; patches are placed on the image.
    private var healSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.healToolActive) {
                    Text(model.healToolActive ? "Healing: on" : "Heal…")
                }
                .toggleStyle(.button)
                .help("Arm the tool, then click a spot to remove it; drag to pick the source (H)")
                Picker("Mode", selection: Binding(get: { model.activeHealMode },
                                                  set: { model.activeHealMode = $0 })) {
                    Text("Heal").tag(HealPatch.Mode.heal)
                    Text("Clone").tag(HealPatch.Mode.clone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                Spacer()
                Button("Delete") { model.deleteSelectedHeal() }
                    .disabled(model.selectedHeal == nil)
                    .help("Remove the selected patch (⌫)")
            }
            .controlSize(.small)
            .disabled(!model.hasImage)

            sliderRow(title: "Size",
                      value: Binding(get: { model.activeHealRadiusPixels },
                                     set: { model.activeHealRadiusPixels = $0 }),
                      range: 4...600, format: "%.0f px")
            sliderRow(title: "Feather",
                      value: Binding(get: { model.activeHealFeather },
                                     set: { model.activeHealFeather = $0 }),
                      range: 0...1, format: "%.2f", defaultValue: 0.35)

            HStack {
                let n = model.parameters.heals.count
                Text(n == 0 ? "No patches. Click a dust spot or blemish to remove it."
                     : "\(n) patch\(n == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if n > 0 {
                    Button("Clear all") { model.clearHeals() }.controlSize(.mini)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            disclosureLabel(title)
            content()
        }
    }

    private func sliderRow(title: String, value: Binding<Float>,
                            range: ClosedRange<Float>, format: String,
                            defaultValue: Float = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ResettableSlider(value: value, in: range) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
        }
        .disabled(!model.hasImage)
    }

    /// In Compare, zoom buttons drive both panes.
    private var mirrorModel: EditorModel? { mode == .compare ? compareModel : nil }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(AppMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 280)

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
                Button("−") { model.zoomOut(); mirrorModel?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Text(model.zoomLabel)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 40)
                Button("+") { model.zoomIn(); mirrorModel?.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Fit") { model.zoomToFit(); mirrorModel?.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("100%") { model.zoomToActualSize(); mirrorModel?.zoomToActualSize() }
                    .keyboardShortcut("1", modifiers: .command)
            }
            .controlSize(.small)
            .disabled(!model.hasImage || !mode.showsImage)

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

/// The aspect menu's entries, as displayed (portrait images see "3:2" tall).
enum CropAspectOption: String, CaseIterable, Identifiable {
    case free, original, square, r3x2, r2x3, r4x3, r3x4, r5x4, r4x5, r16x9, r9x16
    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .r3x2: "3:2"
        case .r2x3: "2:3"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r5x4: "5:4"
        case .r4x5: "4:5"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        }
    }

    func ratio(original: Float) -> Float? {
        switch self {
        case .free: nil
        case .original: original
        case .square: 1
        case .r3x2: 3 / 2
        case .r2x3: 2 / 3
        case .r4x3: 4 / 3
        case .r3x4: 3 / 4
        case .r5x4: 5 / 4
        case .r4x5: 4 / 5
        case .r16x9: 16 / 9
        case .r9x16: 9 / 16
        }
    }

    /// The entry whose ratio matches `ratio` (within a hair), else Free.
    static func matching(_ ratio: Float?, original: Float) -> CropAspectOption {
        guard let ratio else { return .free }
        return allCases.first { option in
            guard let r = option.ratio(original: original) else { return false }
            return abs(r - ratio) < 0.002
        } ?? .free
    }
}
