import SwiftUI
import Catalog
import PixelEngine

/// The left-hand panel: which folder is open and how the scan is going.
/// Collections, presets and the navigator arrive here in later phases.
struct LibraryPanel: View {
    @ObservedObject var library: Library
    @ObservedObject var exportQueue: ExportQueue
    @ObservedObject var photoMerge: PhotoMergeQueue
    @ObservedObject var model: EditorModel
    @State private var metadataExpanded = true
    @State private var historyExpanded = false
    @State private var exportExpanded = true
    @AppStorage(OpenImageExportOptions.includeMetadataKey) private var openImageIncludesMetadata = true
    @AppStorage(OpenImageExportOptions.includeLocationKey) private var openImageIncludesLocation = false
    @AppStorage(OpenImageExportOptions.includeWatermarkKey) private var openImageIncludesWatermark = false
    let onOpenFolder: () -> Void
    let onRate: (Int) -> Void
    let onFlag: (ImageFlag) -> Void
    let onExport: () -> Void
    let presets: [Preset]
    let onApplyPreset: (Preset) -> Void
    let onPaste: () -> Void
    /// Export Open Image offered: not in Survey, whose panes aren't the
    /// editor's image.
    var exportsOpenImage = true

    @State private var keywordText = ""
    /// The selected photo's merge recipe, when it is one Photo Merge made;
    /// read from the catalog when the selection settles.
    @State private var mergeSummary: MergeRecipeSummary?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Folder")
            if let url = library.folderURL {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                Text("\(library.images.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No folder open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Folder…", action: onOpenFolder)
                .controlSize(.small)

            if library.isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Working")
            }

            if library.thumbnailsTotal > 0 && library.thumbnailsDone < library.thumbnailsTotal {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thumbnails \(library.thumbnailsDone) of \(library.thumbnailsTotal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(library.thumbnailsDone),
                                 total: Double(library.thumbnailsTotal))
                        .controlSize(.small)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Making thumbnails")
                .accessibilityValue("\(library.thumbnailsDone) of \(library.thumbnailsTotal)")
            }

            if !library.undecidedSubfolders.isEmpty {
                subfolderPrompt
            }

            if let selected = library.selectedImage {
                selectionSection(selected)
                DisclosureGroup(isExpanded: $metadataExpanded) {
                    metadataSection(selected).padding(.top, 6)
                } label: {
                    sectionLabel("Metadata")
                }
            }

            DisclosureGroup(isExpanded: $historyExpanded) {
                HistoryPanel(model: model).padding(.top, 6)
            } label: {
                sectionLabel("History & Snapshots")
            }

            // Above the section, not inside it: a job the user started must
            // always show how far it has got and offer its Cancel, and what
            // it had to say at the end, whether or not Export is folded away.
            runningJob
            mergeNotes

            DisclosureGroup(isExpanded: $exportExpanded) {
                exportSection.padding(.top, 6)
            } label: {
                sectionLabel("Export")
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        }
        .frame(width: 220, alignment: .leading)
        .onChange(of: library.selectedKeywords, initial: true) { _, keywords in
            keywordText = keywords.joined(separator: ", ")
        }
    }

    /// Export the selection, and how the current batch is going.
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let n = library.selectedImageIDs.count
            Button(n <= 1 ? "Export selection…" : "Export \(n) images…", action: onExport)
                .controlSize(.small)
                .disabled(n == 0 || exportQueue.isGPUBusy)

            // The open image, straight from the editor's render.
            Picker("Format", selection: $model.exportSettings.format) {
                ForEach(ExportSettings.Format.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            if model.exportSettings.format.supportsQuality {
                HStack {
                    Text("Quality").font(.caption)
                    ResettableSlider(value: $model.exportSettings.quality, in: 0.3...1.0, label: "Export quality",
                                     format: SliderValueFormat(decimals: 2)) {
                        model.exportSettings.quality = 0.92
                    }
                    Text(String(format: "%.2f", model.exportSettings.quality))
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .controlSize(.small)
            }
            Toggle("Include camera metadata", isOn: $openImageIncludesMetadata)
                .controlSize(.small)
                .help("Camera and lens details, capture time, artist, copyright, keywords and rating.")
            Toggle("Include location", isOn: $openImageIncludesLocation)
                .controlSize(.small)
                .disabled(!openImageIncludesMetadata)
                .accessibilityHint(ExportPreset.locationHelp)
                .help(ExportPreset.locationHelp)
            Toggle("Add watermark", isOn: $openImageIncludesWatermark)
                .controlSize(.small)
                .accessibilityHint(ExportPreset.openImageWatermarkHelp)
                .help(ExportPreset.openImageWatermarkHelp)
            Button("Export open image…") { Self.exportOpenImage(model: model, library: library) }
                .controlSize(.small)
                .disabled(!model.hasImage || model.isExporting || !exportsOpenImage)
            // How long the last job took. What a running one is doing, and
            // anything the last one had to say, are above the section
            // (`runningJob`, `mergeNotes`).
            if !photoMerge.isRunning, !photoMerge.summary.isEmpty {
                Text(photoMerge.summary).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !exportQueue.isRunning, !exportQueue.summary.isEmpty {
                Text(exportQueue.summary).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(exportQueue.failures) { f in
                    Text("✗ \(f.name): \(f.reason)").font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Failed: \(f.name): \(f.reason)")
                }
            }
        }
    }

    /// What the last Photo Merge had to say for itself: a photo Auto Align
    /// left out, exposures that disagree with their EXIF, a first edit that
    /// couldn't be worked out. The merge worked, so these are notes —
    /// orange, wrapped and whole — not the red one-line status bar, which
    /// VoiceOver announces as an error.
    ///
    /// Beside the progress and outside the Export group for the same
    /// reason: HDR Merge Without Dialog has no other channel for them, and
    /// a folded-away section would swallow them.
    @ViewBuilder private var mergeNotes: some View {
        if !photoMerge.isRunning, !photoMerge.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(photoMerge.notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Note: \(note)")
                }
            }
        }
    }

    /// The export or Photo Merge under way, with its Cancel. They take
    /// turns over one GPU slot, so only one of the two is ever running.
    ///
    /// Outside the Export disclosure group on purpose: the panel is the
    /// only place either job's progress and its only Cancel appear, and a
    /// folded-away section would hide them (and leave Export and Photo
    /// Merge greyed out with nothing on screen to say why).
    @ViewBuilder private var runningJob: some View {
        if photoMerge.isRunning {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(photoMerge.kind.title).font(.caption2)
                    Spacer()
                    Button("Cancel") { photoMerge.cancel() }
                        .controlSize(.mini)
                        .accessibilityLabel("Cancel \(photoMerge.kind.title.lowercased())")
                }
                ProgressView(value: photoMerge.progress?.fraction ?? 0, total: 1)
                    .controlSize(.small)
                    .accessibilityLabel("\(photoMerge.kind.title) progress")
                    .accessibilityValue(PhotoMergeQueue.spokenProgress(photoMerge.progress))
                Text(photoMerge.progress?.stage ?? "Starting…").font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityHidden(true)
                Text(photoMerge.name).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else if exportQueue.isRunning {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(exportQueue.done) of \(exportQueue.total)").font(.caption2)
                    Spacer()
                    Button("Cancel") { exportQueue.cancel() }.controlSize(.mini)
                }
                ProgressView(value: Double(exportQueue.done), total: Double(max(exportQueue.total, 1)))
                    .controlSize(.small)
                    .accessibilityLabel("Export progress")
                    .accessibilityValue("\(exportQueue.done) of \(exportQueue.total)")
                Text(exportQueue.currentName).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// Exports the image open in the editor, which need not be the
    /// selection, with the metadata switches above. Its keywords and rating
    /// come from the catalog, so the file carries the same metadata a
    /// queued export of it would. A file opened outside this catalog has
    /// neither, and still gets its camera metadata; the file name check
    /// matters because the editor keeps its image when another folder is
    /// opened, and the same id there is a different photo.
    static func exportOpenImage(model: EditorModel, library: Library) {
        guard !model.isExporting, let source = model.sourceURL,
              let destination = model.chooseExportDestination() else { return }
        // The panel's name came from `source`. An image that finished
        // loading while the panel was up would be written under that name.
        guard model.sourceURL == source else {
            model.status = "Export cancelled: another image opened while choosing where to save it"
            return
        }
        let options = OpenImageExportOptions.load()
        guard let id = model.catalogImageID, let catalog = library.catalog,
              let record = library.images.first(where: { $0.id == id && $0.fileName == model.imageTitle }) else {
            model.export(to: destination, options: options, rating: 0, readKeywords: nil)
            return
        }
        model.export(to: destination, options: options, rating: record.rating,
                     readKeywords: { try await catalog.keywords(forImageID: id) })
    }

    /// Rating, flag and keywords for the selected image. Keys do the same
    /// (0-5, P/X/U); this is the visible, clickable version.
    private func selectionSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Selected")
            Text(image.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            onRate(star == image.rating ? 0 : star)
                        } label: {
                            Text(star <= image.rating ? "★" : "☆")
                                .foregroundStyle(star <= image.rating ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // One adjustable rating rather than five star glyphs.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rating")
                .accessibilityValue(SpokenText.stars(image.rating))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if image.rating < 5 { onRate(image.rating + 1) }
                    case .decrement: if image.rating > 0 { onRate(image.rating - 1) }
                    @unknown default: break
                    }
                }
                Spacer()
                Picker("Flag", selection: Binding(
                    get: { ImageFlag(rawValue: image.flag) ?? .none },
                    set: { onFlag($0) })) {
                    Text("–").tag(ImageFlag.none).accessibilityLabel(SpokenText.flag(0))
                    Text("✓").tag(ImageFlag.picked).accessibilityLabel(SpokenText.flag(1))
                    Text("✗").tag(ImageFlag.rejected).accessibilityLabel(SpokenText.flag(-1))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 80)
                .accessibilityValue(SpokenText.flag(image.flag))
            }

            TextField("Keywords, comma separated", text: $keywordText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Keywords")
                .controlSize(.small)
                .onSubmit {
                    let keywords = keywordText.split(separator: ",").map(String.init)
                    library.perform("Saving keywords") { try await library.setKeywords(keywords) }
                }

            if image.finderTags != nil {
                FinderTagList(tags: image.tags)
            }

            if image.userRotation != 0 {
                Text("rotated \(image.userRotation * 90)°")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Presets and pasted settings apply to the whole selection.
            HStack {
                Menu("Apply preset") {
                    ForEach(presets) { preset in
                        Button(preset.name) { onApplyPreset(preset) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Paste settings", action: onPaste)
                    .help("Paste the copied settings onto every selected image (⌘⇧V)")
            }
            .controlSize(.small)
        }
    }

    /// EXIF summary of the selected image, straight from the catalog row:
    /// no file is touched when the selection changes. Rows with no value
    /// are omitted by `metadataRows`, so the section shrinks rather than
    /// showing dashes for files with sparse metadata.
    private func metadataSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let exposure = image.exposureLine
            if !exposure.isEmpty {
                Text(exposure)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(image.metadataRows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.value)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption2)
            mergeSection
        }
        // A merge result's recipe, from the catalog's own row: no file is
        // touched when the selection changes, as for the rows above.
        .task(id: image.id) {
            mergeSummary = nil
            guard let json = try? await library.mergeRecipe(for: image) else { return }
            mergeSummary = MergeRecipeSummary(json: json)
        }
    }

    /// What Photo Merge made this photo from, for a photo it made. Read
    /// only: the recipe records how the file came about, so there is
    /// nothing here to change.
    @ViewBuilder private var mergeSection: some View {
        if let summary = mergeSummary {
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(summary.rows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.value)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo Merge")
            .accessibilityValue(summary.spoken)
            .help("What Photo Merge made this photo from. Photos listed as left out couldn’t be used: "
                  + "they wouldn’t line up, or wouldn’t join the panorama.")
        }
    }

    /// DESIGN.md §5.2: a subfolder with no recorded mode is asked about
    /// rather than silently swallowed or ignored.
    private var subfolderPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Subfolders found")
            ForEach(library.undecidedSubfolders, id: \.self) { name in
                Text(name).font(.caption).lineLimit(1)
            }
            Text("Include them in this catalog, or keep them as separate catalogs of their own?")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Include") { decide(true) }
                Button("Keep separate") { decide(false) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func decide(_ include: Bool) {
        library.perform("Applying the subfolder decision") {
            try await library.decideUndecidedSubfolders(include: include)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}
