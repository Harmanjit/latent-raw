import Foundation
import SwiftUI
import PixelEngine
import ColorKit
import Catalog
import MLKit

/// How a batch should be written. Kept in UserDefaults so the next export
/// starts from the last one.
struct ExportPreset: Codable, Equatable {
    var format: ExportSettings.Format = .jpeg
    var quality: Float = 0.92
    var colorSpaceIsP3 = false
    var resize = false
    var maxLongEdge = 2048
    /// Kept for old saved presets; appended to the template on load.
    var suffix = ""
    /// File naming, see ExportNaming for the tokens.
    var template: String = ExportNaming.defaultTemplate
    var sequenceStart = 1
    var sequenceStep = 1
    var sequencePadding = 3
    var letterCase: ExportNaming.LetterCase = .unchanged
    var uppercaseExtension = false
    var collision: ExportNaming.Collision = .addNumber
    /// Put each image in a yyyy-MM-dd subfolder of the destination.
    var dateSubfolders = false
    var includeMetadata = true
    /// With metadata, also keep the GPS position, place names and the camera
    /// and lens serial numbers (`SourceMetadata.locationTags`). Off by
    /// default, and in presets saved before it existed: those were agreed to
    /// as "camera metadata, keywords and rating", not location.
    var includeLocation = false
    var revealWhenDone = true
    /// JPEG/HEIC: add an HDR gain map. Off by default, and in older presets.
    var hdrGainMap = false
    /// Stamp `watermark` into each file. Off by default, and in older
    /// presets; the text and look are kept while it's off.
    var watermarkEnabled = false
    var watermark = ExportWatermark()

    var settings: ExportSettings {
        ExportSettings(format: format, quality: quality, hdrGainMap: hdrGainMap,
                       watermark: watermarkEnabled && !watermark.isEmpty ? watermark : nil)
    }
    var colorSpace: ColorKit.OutputSpace { colorSpaceIsP3 ? .displayP3 : .sRGB }
    /// What the location switch covers, for its tooltip here and in the
    /// left panel.
    static let locationHelp = "The GPS position, place names, and the camera and lens serial numbers. "
        + "Off, the file doesn't say where the photo was taken or which camera took it."

    // Lenient decoding: every field is optional on the way in, so a preset
    // saved by an older build (or a hand-edited one) still loads.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(ExportSettings.Format.self, forKey: .format) ?? .jpeg
        quality = try c.decodeIfPresent(Float.self, forKey: .quality) ?? 0.92
        colorSpaceIsP3 = try c.decodeIfPresent(Bool.self, forKey: .colorSpaceIsP3) ?? false
        resize = try c.decodeIfPresent(Bool.self, forKey: .resize) ?? false
        maxLongEdge = try c.decodeIfPresent(Int.self, forKey: .maxLongEdge) ?? 2048
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ExportNaming.defaultTemplate
        if !suffix.isEmpty, !template.contains(suffix) { template += suffix; suffix = "" }
        sequenceStart = try c.decodeIfPresent(Int.self, forKey: .sequenceStart) ?? 1
        sequenceStep = try c.decodeIfPresent(Int.self, forKey: .sequenceStep) ?? 1
        sequencePadding = try c.decodeIfPresent(Int.self, forKey: .sequencePadding) ?? 3
        letterCase = (try? c.decodeIfPresent(ExportNaming.LetterCase.self, forKey: .letterCase)) ?? .unchanged
        uppercaseExtension = try c.decodeIfPresent(Bool.self, forKey: .uppercaseExtension) ?? false
        collision = try c.decodeIfPresent(ExportNaming.Collision.self, forKey: .collision) ?? .addNumber
        dateSubfolders = try c.decodeIfPresent(Bool.self, forKey: .dateSubfolders) ?? false
        includeMetadata = try c.decodeIfPresent(Bool.self, forKey: .includeMetadata) ?? true
        includeLocation = try c.decodeIfPresent(Bool.self, forKey: .includeLocation) ?? false
        revealWhenDone = try c.decodeIfPresent(Bool.self, forKey: .revealWhenDone) ?? true
        hdrGainMap = try c.decodeIfPresent(Bool.self, forKey: .hdrGainMap) ?? false
        watermarkEnabled = try c.decodeIfPresent(Bool.self, forKey: .watermarkEnabled) ?? false
        watermark = (try? c.decodeIfPresent(ExportWatermark.self, forKey: .watermark)) ?? ExportWatermark()
    }

    var fileExtension: String {
        uppercaseExtension ? settings.format.fileExtension.uppercased() : settings.format.fileExtension
    }

    /// What the batch planner needs; the sheet's preview and the queue use
    /// the same, so the names shown are the names written.
    func planOptions(catalogName: String) -> ExportBatchPlanner.Options {
        ExportBatchPlanner.Options(template: template, start: sequenceStart, step: sequenceStep,
                                   padding: sequencePadding, letterCase: letterCase, fileExtension: fileExtension,
                                   collision: collision, dateSubfolders: dateSubfolders, catalogName: catalogName)
    }

    static let defaultsKey = "latent.exportPreset"
    static func load() -> ExportPreset {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let p = try? JSONDecoder().decode(ExportPreset.self, from: data) else { return ExportPreset() }
        return p
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

/// Named export presets ("Web 2048 JPEG", "Print TIFF"), like Lightroom's.
struct NamedExportPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var preset: ExportPreset
}

enum ExportPresetStore {
    static let key = "latent.exportPresets"
    static func load() -> [NamedExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([NamedExportPreset].self, from: data) else { return builtIns }
        return list
    }
    static func save(_ list: [NamedExportPreset]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
    static var builtIns: [NamedExportPreset] {
        var web = ExportPreset(); web.resize = true; web.maxLongEdge = 2048; web.template = "{name}-web"
        var full = ExportPreset(); full.quality = 0.95
        var print = ExportPreset(); print.format = .tiff; print.colorSpaceIsP3 = true
        var contact = ExportPreset(); contact.resize = true; contact.maxLongEdge = 1024
        contact.template = "{date}-{seq}"; contact.dateSubfolders = true
        return [NamedExportPreset(name: "Web (2048 px JPEG)", preset: web),
                NamedExportPreset(name: "Full size JPEG", preset: full),
                NamedExportPreset(name: "Print (16-bit TIFF, P3)", preset: print),
                NamedExportPreset(name: "Proofs by date (1024 px)", preset: contact)]
    }
}

/// Runs exports one after another on a background task and publishes
/// progress. One at a time on purpose: the GPU is a single resource, a
/// full-resolution demosaic already saturates it, and two concurrent
/// jobs would each be slower while doubling peak memory. The UI never
/// waits: every render, readback and encode happens off the main thread
/// and only the counters come back.
@MainActor
final class ExportQueue: ObservableObject {
    struct Failure: Identifiable { let id = UUID(); let name: String; let reason: String }

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""
    @Published private(set) var failures: [Failure] = []
    @Published private(set) var summary = ""

    private var task: Task<Void, Never>?

    /// Another full-size GPU job holds the queue's slot: a Photo Merge
    /// (PhotoMergeQueue). Such a job is as heavy as an export, so for the
    /// reason above the two take turns: an export doesn't start while it
    /// runs, and it doesn't start while an export runs.
    @Published private(set) var slotHeldByOtherJob = false

    /// An export or another GPU job is running.
    var isGPUBusy: Bool { isRunning || slotHeldByOtherJob }

    /// Takes the slot for a job that isn't an export; false, taking
    /// nothing, when an export or another job holds it. Give it back with
    /// `releaseSlot` however the job ends.
    func claimSlot() -> Bool {
        guard !isGPUBusy else { return false }
        slotHeldByOtherJob = true
        return true
    }

    func releaseSlot() {
        slotHeldByOtherJob = false
    }

    func start(records: [ImageRecord], library: Library, preset: ExportPreset,
               destination: URL, gpu: GPUContext) {
        guard !isGPUBusy, !records.isEmpty, let catalog = library.catalog, let root = library.folderURL else { return }
        isRunning = true
        stoppingForQuit = false
        done = 0; total = records.count; failures = []; summary = ""
        preset.save()
        // Held until the loop below finishes, however it finishes.
        let activity = ExportActivity(reason: "Exporting \(records.count) image\(records.count == 1 ? "" : "s")")

        task = Task { [weak self] in
            defer { activity.end() }
            // One full-size render on the GPU at a time.
            await ExportPreviewRenderer.waitForDiscardedRenders()
            let start = Date()
            var totalPixels = 0
            let catalogName = root.lastPathComponent
            var skipped = 0
            var written: [URL] = []
            // Every name settled before the first file is written, so two
            // images whose template gives the same name never overwrite each
            // other, whatever the collision policy.
            let options = preset.planOptions(catalogName: catalogName)
            var plan = await Task.detached(priority: .userInitiated) {
                ExportBatchPlanner.plan(records, into: destination, options: options)
            }.value
            images: for (index, record) in records.enumerated() {
                if Task.isCancelled { break }
                let name = record.fileName
                await MainActor.run { self?.currentName = name }

                // Everything the worker needs, gathered on the actor side. A
                // read failure fails this file; exporting it unedited would
                // be a wrong file with no warning.
                let json: String?
                let keywords: [String]
                do {
                    json = try await catalog.editStack(forImageID: record.id ?? -1)
                    keywords = try await catalog.keywords(forImageID: record.id ?? -1)
                } catch {
                    await MainActor.run {
                        self?.failures.append(Failure(name: name, reason: "could not read its edit: \(error)"))
                        self?.done += 1
                    }
                    continue
                }
                // The planned name, checked against the disk once more:
                // earlier files of a long batch take a while, and something
                // may have appeared under this name meanwhile.
                let output = plan.recheck(index)
                switch output.action {
                case .write, .replace:
                    break
                case .skip:
                    skipped += 1
                    await MainActor.run { self?.done += 1 }
                    continue
                case .fail(let reason):
                    await MainActor.run {
                        self?.failures.append(Failure(name: name, reason: reason))
                        self?.done += 1
                    }
                    continue
                }
                var target = output.url
                let folder = target.deletingLastPathComponent()
                if preset.dateSubfolders {
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    } catch {
                        await MainActor.run {
                            self?.failures.append(Failure(name: name, reason: "could not create \(folder.lastPathComponent): \(error)"))
                            self?.done += 1
                        }
                        continue
                    }
                }
                // Only Replace replaces. Otherwise the file is moved into place
                // only if its name is still free, so one that appeared while
                // the image rendered is kept, and the name is settled again by
                // the policy: numbered (rendered again, rarely), or skipped.
                var outcome: Result<ExportWorker.Outcome, Error>
                var attempts = 0
                while true {
                    let request = preset.workerRequest(for: record, root: root, destination: target,
                                                       editStackJSON: json, keywords: keywords)

                    outcome = await Task.detached(priority: .userInitiated) {
                        do { return .success(try await ExportWorker.export(request, gpu: gpu)) }
                        catch { return .failure(error) }
                    }.value
                    attempts += 1
                    guard case .failure(let error) = outcome, error is SafeFileWriter.DestinationExists,
                          attempts < 3, !Task.isCancelled else { break }
                    let settled = plan.recheck(index)
                    switch settled.action {
                    case .write, .replace:
                        target = settled.url
                    case .skip:
                        skipped += 1
                        await MainActor.run { self?.done += 1 }
                        continue images
                    case .fail(let reason):
                        await MainActor.run {
                            self?.failures.append(Failure(name: name, reason: reason))
                            self?.done += 1
                        }
                        continue images
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    self.done += 1
                    switch outcome {
                    case .success(let o): totalPixels += o.pixelWidth * o.pixelHeight; written.append(target)
                    case .failure(let e): self.failures.append(Failure(name: name, reason: "\(e)"))
                    }
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            let exported = written
            await MainActor.run {
                guard let self else { return }
                self.isRunning = false
                self.currentName = ""
                let cancelled = Task.isCancelled ? " (cancelled)" : ""
                let skippedNote = skipped > 0 ? " · \(skipped) skipped (already there)" : ""
                self.summary = String(format: "%d of %d exported%@ in %.1fs · %.1f MP total%@",
                                      exported.count, self.total, cancelled, elapsed,
                                      Double(totalPixels) / 1_000_000, skippedNote)
                if preset.revealWhenDone, !exported.isEmpty, !self.stoppingForQuit {
                    NSWorkspace.shared.activateFileViewerSelecting(Array(exported.prefix(50)))
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Set when quitting stops the run, so it doesn't bring Finder forward
    /// as the app goes away.
    private var stoppingForQuit = false

    /// For quitting: stops the run after the file being written and
    /// returns once that file is complete (at once when nothing is
    /// running). Cancelling only stops the loop from starting the next
    /// image; the render and write run in a detached task, which
    /// cancellation doesn't reach, so a file is never left half-written.
    func stopAfterCurrentFile() async {
        guard let task else { return }
        stoppingForQuit = true
        task.cancel()
        await task.value
    }
}

/// The export sheet: saved presets, format and size, naming and
/// destination, with a live preview of the first file name.
struct ExportSheet: View {
    let count: Int
    /// The first selected image, for the naming preview.
    var sample: ImageRecord?
    /// Every image to export, in order, for planning the names.
    var records: [ImageRecord] = []
    var catalogName: String = ""
    /// For the size estimate and quality comparison; nil hides both.
    var preview: ExportPreviewSource?
    @State var preset = ExportPreset.load()
    @State private var renderer: ExportPreviewRenderer?
    @StateObject private var estimate = ExportEstimateModel()
    @State private var destination: URL? = BookmarkStore.resolve(key: BookmarkStore.exportDestination)
        ?? AppPreferences.shared.defaultExportFolder
    @State private var savedPresets = ExportPresetStore.load()
    @State private var newPresetName = ""
    @State private var showingSavePreset = false
    /// The names the export would write, planned off the main thread each
    /// time the naming or destination changes. The last plan stays shown
    /// until the next arrives, so typing in the template doesn't flicker.
    @State private var plan: ExportBatchPlan?
    let onExport: (ExportPreset, URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Export \(count) image\(count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Menu("Presets") {
                    ForEach(savedPresets) { saved in
                        Button(saved.name) { preset = saved.preset }
                    }
                    Divider()
                    Button("Save current as preset…") { showingSavePreset = true }
                    if !savedPresets.isEmpty {
                        Menu("Delete preset") {
                            ForEach(savedPresets) { saved in
                                Button(saved.name, role: .destructive) {
                                    savedPresets.removeAll { $0.id == saved.id }
                                    ExportPresetStore.save(savedPresets)
                                }
                            }
                        }
                    }
                }
                .fixedSize()
            }

            groupLabel("File")
            Picker("Format", selection: $preset.format) {
                ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if preset.format.supportsQuality {
                HStack {
                    Text("Quality").accessibilityHidden(true)
                    ResettableSlider(value: $preset.quality, in: 0.3...1, label: "Quality",
                                     format: SliderValueFormat(decimals: 0, scale: 100)) { preset.quality = 0.92 }
                    Text(String(format: "%.0f", preset.quality * 100)).monospacedDigit().frame(width: 30)
                        .accessibilityHidden(true)
                    Button("Compare…") { compareQualities() }
                        .controlSize(.small)
                        .disabled(renderer == nil || estimateRecords.isEmpty)
                        .accessibilityLabel("Compare qualities")
                        .accessibilityHint("Opens a window showing the first image encoded at several qualities side by side.")
                        .help("See the first image encoded at several qualities side by side at 100%, with file sizes.")
                }
            }
            if preset.format.supportsGainMap {
                Toggle("HDR gain map", isOn: $preset.hdrGainMap)
                    .accessibilityLabel("HDR gain map")
                    .accessibilityHint("Adds a gain map so HDR screens show highlights brighter than white. Other screens show the normal image.")
                    .help("Highlights up to two stops brighter on HDR screens, as the editor shows them. Every other viewer shows the normal image.")
            }
            Picker("Colour space", selection: $preset.colorSpaceIsP3) {
                Text("sRGB (safe everywhere)").tag(false)
                Text("Display P3 (wider, modern screens)").tag(true)
            }
            Toggle("Resize to fit", isOn: $preset.resize)
            if preset.resize {
                HStack {
                    Text("Long edge")
                    TextField("px", value: $preset.maxLongEdge, format: .number).frame(width: 80)
                        .accessibilityLabel("Long edge in pixels")
                    Text("px").foregroundStyle(.secondary).accessibilityHidden(true)
                    Spacer()
                    ForEach([1024, 2048, 4096], id: \.self) { n in
                        Button("\(n)") { preset.maxLongEdge = n }.controlSize(.small)
                            .accessibilityLabel("\(n) pixels")
                    }
                }
            }
            ExportWatermarkSection(preset: $preset)
            Toggle("Include camera metadata, keywords and rating", isOn: $preset.includeMetadata)
            Toggle("Include location", isOn: $preset.includeLocation)
                .disabled(!preset.includeMetadata)
                .padding(.leading, 20)
                .accessibilityHint(ExportPreset.locationHelp)
                .help(ExportPreset.locationHelp)

            groupLabel("Naming")
            HStack {
                Text("Template")
                TextField("{name}", text: $preset.template)
                    .accessibilityLabel("File name template")
                Menu("Insert") {
                    ForEach(ExportNaming.tokens, id: \.token) { t in
                        Button("\(t.token)  \(t.meaning)") { preset.template += t.token }
                    }
                }
                .fixedSize()
            }
            HStack {
                Text("Sequence starts at")
                TextField("1", value: $preset.sequenceStart, format: .number).frame(width: 60)
                    .accessibilityLabel("Sequence starts at")
                Text("step")
                TextField("1", value: $preset.sequenceStep, format: .number).frame(width: 44)
                    .accessibilityLabel("Sequence step")
                Text("digits")
                Stepper("\(preset.sequencePadding)", value: $preset.sequencePadding, in: 1...6).frame(width: 70)
                    .accessibilityLabel("Sequence digits")
                    .accessibilityValue("\(preset.sequencePadding)")
                Spacer()
            }
            HStack {
                Picker("Letter case", selection: $preset.letterCase) {
                    ForEach(ExportNaming.LetterCase.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 210)
                Picker("Extension", selection: $preset.uppercaseExtension) {
                    Text(".\(preset.settings.format.fileExtension.lowercased())").tag(false)
                    Text(".\(preset.settings.format.fileExtension.uppercased())").tag(true)
                }
                .frame(width: 150)
                Spacer()
            }
            Picker("If the file exists", selection: $preset.collision) {
                ForEach(ExportNaming.Collision.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 260)
            namingNotes
                .task(id: PlanRequest(options: preset.planOptions(catalogName: catalogName),
                                      destination: destination, count: records.count)) {
                    await updatePlan()
                }

            groupLabel("Destination")
            HStack {
                Text(destination?.path ?? "choose a folder…").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(destination == nil ? .secondary : .primary)
                    .accessibilityLabel("Destination")
                    .accessibilityValue(destination?.path ?? "none chosen")
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    panel.message = "Folder to export into"
                    if panel.runModal() == .OK, let url = panel.url {
                        destination = url
                        BookmarkStore.save(url, key: BookmarkStore.exportDestination)
                    }
                }
            }
            Toggle("Sort into subfolders by capture date", isOn: $preset.dateSubfolders)
            Toggle("Show in Finder when done", isOn: $preset.revealWhenDone)
            HStack {
                ExportEstimateLabel(model: estimate)
                    .task(id: estimateRequest) {
                        await estimate.update(records: estimateRecords, preset: preset, renderer: renderer)
                    }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard let destination else { return }
                    // Stopped now rather than when the sheet has gone, so the
                    // export waits for the estimate's render to stop.
                    releaseRender()
                    onExport(preset, destination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil || count == 0 || !unknownTokens.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if renderer == nil, let preview { renderer = ExportPreviewRenderer(source: preview) }
        }
        .onDisappear { releaseRender() }
        .sheet(isPresented: $showingSavePreset) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save export preset").font(.headline)
                TextField("Name", text: $newPresetName)
                HStack {
                    Spacer()
                    Button("Cancel") { showingSavePreset = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let name = newPresetName.trimmingCharacters(in: .whitespaces)
                        savedPresets.removeAll { $0.name == name }
                        savedPresets.append(NamedExportPreset(name: name, preset: preset))
                        ExportPresetStore.save(savedPresets)
                        newPresetName = ""; showingSavePreset = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(width: 320)
        }
    }

    private var unknownTokens: [String] { ExportNaming.unknownTokens(in: preset.template) }

    /// The render and the comparison belong to this sheet.
    private func releaseRender() {
        if let renderer {
            QualityCompareWindow.close(ifUsing: renderer)
            renderer.discard()
        }
    }

    /// The images the estimate covers, the first being the one rendered.
    private var estimateRecords: [ImageRecord] { records.isEmpty ? (sample.map { [$0] } ?? []) : records }

    /// Only what changes the estimate, so typing a file name doesn't encode again.
    private var estimateRequest: EstimateRequest? {
        guard let first = estimateRecords.first, renderer != nil else { return nil }
        return EstimateRequest(render: ExportPreviewRenderer.Key(record: first, preset: preset),
                               finish: ExportPreviewRenderer.Finish(preset: preset),
                               format: preset.format, quality: preset.quality,
                               imageIDs: estimateRecords.map(\.id))
    }

    private struct EstimateRequest: Equatable {
        var render: ExportPreviewRenderer.Key
        var finish: ExportPreviewRenderer.Finish
        var format: ExportSettings.Format
        var quality: Float
        var imageIDs: [Int64?]
    }

    private func compareQualities() {
        guard let renderer, let first = estimateRecords.first else { return }
        QualityCompareWindow.show(renderer: renderer, record: first, preset: preset) { quality in
            preset.quality = quality
        }
    }

    private struct PlanRequest: Equatable {
        var options: ExportBatchPlanner.Options
        var destination: URL?
        var count: Int
    }

    private func updatePlan() async {
        // A short pause while typing, so a burst of keystrokes plans once.
        // The first plan comes at once, so the preview is there on opening.
        if plan != nil {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        let options = preset.planOptions(catalogName: catalogName)
        // Before a destination is chosen, the names alone: nothing on disk
        // to collide with yet.
        let folder = destination ?? URL(fileURLWithPath: "/", isDirectory: true)
        let probe: ExportBatchPlanner.Probe = destination == nil ? .nothingOnDisk : .system
        let records = records.isEmpty ? (sample.map { [$0] } ?? []) : records
        let result = await Task.detached(priority: .userInitiated) {
            ExportBatchPlanner.plan(records, into: folder, options: options, probe: probe)
        }.value
        if !Task.isCancelled { plan = result }
    }

    /// The first file's name, and what the plan found: unknown tokens (which
    /// stop the export), images sharing a name, names already taken, and
    /// images that can't be written.
    @ViewBuilder private var namingNotes: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let first = plan?.outputs.first, let plan {
                Text("First file: \(first.relativePath(to: plan.destination))")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            let unknown = unknownTokens
            if !unknown.isEmpty {
                note("\(unknown.joined(separator: ", ")) \(unknown.count == 1 ? "isn’t a token" : "aren’t tokens"). "
                     + "Fix the template to export; Insert lists the tokens.", color: .red)
            }
            if let plan {
                let shared = plan.sharedNameCount
                if shared > 0 {
                    note("\(images(shared)) would get the same name as another image in this export, "
                         + "so \(shared == 1 ? "it gets" : "they get") a number (-1, -2…).")
                }
                switch plan.collision {
                case .addNumber where plan.existingCount > 0:
                    note("\(images(plan.existingCount)) would take a name already in the folder, "
                         + "so \(plan.existingCount == 1 ? "it gets" : "they get") a number.")
                case .replace where plan.count(.replace) > 0:
                    let n = plan.count(.replace)
                    note("\(n) existing file\(n == 1 ? "" : "s") will be replaced.")
                case .skip where plan.count(.skip) > 0:
                    let n = plan.count(.skip)
                    note("\(images(n)) will be skipped: \(n == 1 ? "its file is" : "their files are") already there.")
                default:
                    EmptyView()
                }
                let failures = plan.failures
                if let firstFailure = failures.first, case .fail(let reason) = firstFailure.action {
                    note("\(images(failures.count)) can’t be written: \(reason).", color: .red)
                }
            }
        }
        .font(.caption)
    }

    private func images(_ n: Int) -> String { n == 1 ? "1 image" : "\(n) images" }

    private func note(_ text: String, color: Color = .orange) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
