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

    // Added for Lightroom parity (ExportPreset+Output.swift says what each
    // does). Every one defaults to what an export did before it existed,
    // and an older preset without them decodes to those defaults.
    var fileKind: ExportFileKind = .image
    /// A colour space beyond sRGB and P3; nil uses `colorSpaceIsP3`.
    var profile: ExportProfileChoice?
    var ppiEnabled = false
    var ppi = 300
    var sizingMode: ExportSizing.Mode = .longEdge
    var shortEdge = 1365
    var boxWidth = 2048
    var boxHeight = 2048
    var megapixels = 12.0
    var percentage = 50.0
    var dontEnlarge = true
    var sharpenEnabled = false
    var sharpenMedium: OutputSharpening.Medium = .screen
    var sharpenStrength: OutputSharpening.Strength = .standard
    var sizeLimitEnabled = false
    var sizeLimitKB = 500
    var tiffBitDepth = 16
    var tiffCompression: TIFFCompression = .none
    var location: ExportLocation = .chosenFolder
    var subfolder = ""
    var metadataLevel: ExportMetadataLevel = .all
    var openInApp = false
    var openInAppPath: String?

    var settings: ExportSettings {
        var s = ExportSettings(format: format, quality: quality, hdrGainMap: hdrGainMap,
                               watermark: watermarkEnabled && !watermark.isEmpty ? watermark : nil)
        applyOutputSettings(to: &s)
        return s
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
        fileKind = (try? c.decodeIfPresent(ExportFileKind.self, forKey: .fileKind)) ?? .image
        profile = (try? c.decodeIfPresent(ExportProfileChoice.self, forKey: .profile)) ?? nil
        ppiEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .ppiEnabled)) ?? false
        ppi = min(max((try? c.decodeIfPresent(Int.self, forKey: .ppi)) ?? 300, 1), 9999)
        sizingMode = (try? c.decodeIfPresent(ExportSizing.Mode.self, forKey: .sizingMode)) ?? .longEdge
        shortEdge = (try? c.decodeIfPresent(Int.self, forKey: .shortEdge)) ?? 1365
        boxWidth = (try? c.decodeIfPresent(Int.self, forKey: .boxWidth)) ?? 2048
        boxHeight = (try? c.decodeIfPresent(Int.self, forKey: .boxHeight)) ?? 2048
        megapixels = (try? c.decodeIfPresent(Double.self, forKey: .megapixels)) ?? 12
        percentage = (try? c.decodeIfPresent(Double.self, forKey: .percentage)) ?? 50
        dontEnlarge = (try? c.decodeIfPresent(Bool.self, forKey: .dontEnlarge)) ?? true
        sharpenEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .sharpenEnabled)) ?? false
        sharpenMedium = (try? c.decodeIfPresent(OutputSharpening.Medium.self, forKey: .sharpenMedium)) ?? .screen
        sharpenStrength = (try? c.decodeIfPresent(OutputSharpening.Strength.self, forKey: .sharpenStrength)) ?? .standard
        sizeLimitEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .sizeLimitEnabled)) ?? false
        sizeLimitKB = max((try? c.decodeIfPresent(Int.self, forKey: .sizeLimitKB)) ?? 500, 1)
        tiffBitDepth = (try? c.decodeIfPresent(Int.self, forKey: .tiffBitDepth)) == 8 ? 8 : 16
        tiffCompression = (try? c.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression)) ?? .none
        location = (try? c.decodeIfPresent(ExportLocation.self, forKey: .location)) ?? .chosenFolder
        subfolder = (try? c.decodeIfPresent(String.self, forKey: .subfolder)) ?? ""
        metadataLevel = (try? c.decodeIfPresent(ExportMetadataLevel.self, forKey: .metadataLevel)) ?? .all
        openInApp = (try? c.decodeIfPresent(Bool.self, forKey: .openInApp)) ?? false
        openInAppPath = (try? c.decodeIfPresent(String.self, forKey: .openInAppPath)) ?? nil
    }

    var fileExtension: String {
        let ext = fileKind == .dng ? "dng" : settings.format.fileExtension
        return uppercaseExtension ? ext.uppercased() : ext
    }

    /// What the batch planner needs; the sheet's preview and the queue use
    /// the same, so the names shown are the names written.
    func planOptions(catalogName: String) -> ExportBatchPlanner.Options {
        var options = ExportBatchPlanner.Options(template: template, start: sequenceStart, step: sequenceStep,
                                                 padding: sequencePadding, letterCase: letterCase,
                                                 fileExtension: fileExtension, collision: collision,
                                                 dateSubfolders: dateSubfolders, catalogName: catalogName)
        options.originalFolders = location == .sameAsOriginal
        options.subfolder = subfolder
        options.keepsOriginalExtension = fileKind == .original
        return options
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
    /// Exports that went through with a stand-in model, or with an empty
    /// click-to-select mask when nothing could stand in: the edit names a
    /// model this Mac lacks (`MaskSubstitutions.exportNote`). Shown under
    /// the failures; the summary counts them.
    @Published private(set) var notes: [String] = []
    @Published private(set) var summary = ""

    private var task: Task<Void, Never>?

    /// Another full-size GPU job holds the queue's slot: a Photo Merge
    /// (PhotoMergeQueue). Such a job is as heavy as an export, so for the
    /// reason above the two take turns: an export doesn't start while it
    /// runs, and it doesn't start while an export runs.
    @Published private(set) var slotHeldByOtherJob = false

    /// Prints and contact sheets being rendered. They don't take the slot
    /// (they register with `OutputJobs` instead), but a print or a sheet
    /// renders each photo at full size on the GPU as an export does, so the
    /// queue waits its turn for them too.
    let outputJobs: OutputJobs

    init(outputJobs: OutputJobs = .shared) {
        self.outputJobs = outputJobs
    }

    /// An export or another GPU job is running.
    var isGPUBusy: Bool {
        isRunning || slotHeldByOtherJob
            || outputJobs.running.contains { $0.kind == .print || $0.kind == .contactSheet }
    }

    /// What the summary says when an export is refused because the GPU is
    /// taken. The sheet's Export button is greyed out then, but the job may
    /// have started between the sheet opening and the button being pressed.
    static let busyRefusal = "Export didn’t start: a Photo Merge, dust removal, face search, print or contact sheet "
        + "is using the graphics processor. Try again when it finishes."

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
        start(records: records, library: library, batches: [ExportBatch(preset: preset, destination: destination)],
              gpu: gpu)
    }

    /// Exports `records` once per batch, one batch after another: one
    /// preset, or several for a multi-batch export. Each batch plans its
    /// own names in its own folder.
    func start(records: [ImageRecord], library: Library, batches: [ExportBatch], gpu: GPUContext) {
        guard !isGPUBusy else {
            // Said, rather than the sheet closing on nothing.
            if !isRunning { summary = Self.busyRefusal }
            return
        }
        guard !records.isEmpty, !batches.isEmpty, let catalog = library.catalog, let root = library.folderURL else { return }
        isRunning = true
        stoppingForQuit = false
        done = 0; total = records.count * batches.count; failures = []; notes = []; summary = ""
        if batches.count == 1 { batches[0].preset.save() }
        ExportPrevious.save(batches)
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
            var substituted = 0
            var written: [URL] = []
            var revealed: [URL] = []
            var opened: [(app: URL, files: [URL])] = []
          batches: for batch in batches {
            let preset = batch.preset
            // Same folder as original plans under the catalog's folder,
            // which the images' paths are relative to.
            let destination = preset.location == .sameAsOriginal ? root : batch.destination
            var writtenInBatch: [URL] = []
            // Every name settled before the first file is written, so two
            // images whose template gives the same name never overwrite each
            // other, whatever the collision policy.
            let options = preset.planOptions(catalogName: catalogName)
            let makesDestination = preset.location != .sameAsOriginal
            var plan = await Task.detached(priority: .userInitiated) {
                // A multi-batch preset's own subfolder of the destination.
                if makesDestination, !FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                }
                return ExportBatchPlanner.plan(records, into: destination, options: options)
            }.value
            images: for (index, record) in records.enumerated() {
                if Task.isCancelled { break batches }
                let name = batches.count > 1 ? "\(record.fileName) (\(batch.name ?? "batch"))" : record.fileName
                await MainActor.run { self?.currentName = name }

                // Everything the worker needs, gathered on the actor side. A
                // read failure fails this file; exporting it unedited would
                // be a wrong file with no warning.
                let json: String?
                let keywords: [String]
                var sidecar: XMPSidecar.Fields?
                do {
                    json = try await catalog.editStack(forImageID: record.id ?? -1)
                    keywords = try await catalog.keywords(forImageID: record.id ?? -1)
                    if preset.fileKind == .original {
                        sidecar = try await catalog.sidecarFields(forImageID: record.id ?? -1)
                    }
                } catch {
                    await MainActor.run {
                        self?.failures.append(Failure(name: name, reason: "could not read its edit: \(error)"))
                        self?.done += 1
                    }
                    continue
                }
                // The planned name, checked against the disk once more:
                // earlier files of a long batch take a while, and something
                // may have appeared under this name meanwhile. Off the main
                // actor, with the date folder made there too: on a share
                // that answers slowly each call would stall the window.
                let settled = await Self.settle(plan, index: index, makeFolder: options.makesFolders)
                plan = settled.plan
                let output = settled.output
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
                if let error = settled.folderError {
                    let folder = target.deletingLastPathComponent()
                    await MainActor.run {
                        self?.failures.append(Failure(name: name, reason: "could not create \(folder.lastPathComponent): \(error)"))
                        self?.done += 1
                    }
                    continue
                }
                // Only Replace replaces. Otherwise the file is moved into place
                // only if its name is still free, so one that appeared while
                // the image rendered is kept, and the name is settled again by
                // the policy: numbered (rendered again, rarely), or skipped.
                var outcome: Result<ExportFileResult, Error>
                var attempts = 0
                while true {
                    let request = preset.workerRequest(for: record, root: root, destination: target,
                                                       editStackJSON: json, keywords: keywords)
                    let job = ExportFileJob(kind: preset.fileKind, request: request, sourceHash: record.hashString,
                                            captureTime: record.captureTime ?? 0,
                                            sidecar: sidecar)
                    outcome = await Task.detached(priority: .userInitiated) {
                        do { return .success(try await job.run(gpu: gpu)) }
                        catch { return .failure(error) }
                    }.value
                    attempts += 1
                    guard case .failure(let error) = outcome, error is SafeFileWriter.DestinationExists,
                          attempts < 3, !Task.isCancelled else { break }
                    let resettled = await Self.settle(plan, index: index, makeFolder: false)
                    plan = resettled.plan
                    switch resettled.output.action {
                    case .write, .replace:
                        target = resettled.output.url
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
                    case .success(let o):
                        totalPixels += o.pixelCount
                        written.append(target)
                        writtenInBatch.append(target)
                        if !o.maskSubstitutions.isEmpty {
                            substituted += 1
                            self.notes.append(MaskSubstitutions.exportNote(name: name, missing: o.maskSubstitutions))
                        }
                    case .failure(let e): self.failures.append(Failure(name: name, reason: "\(e)"))
                    }
                }
            }
            if preset.revealWhenDone { revealed += writtenInBatch }
            if let app = preset.openInAppURL, !writtenInBatch.isEmpty { opened.append((app, writtenInBatch)) }
          }
            let elapsed = Date().timeIntervalSince(start)
            let exported = written
            let toReveal = revealed, toOpen = opened
            await MainActor.run {
                guard let self else { return }
                self.isRunning = false
                self.currentName = ""
                let cancelled = Task.isCancelled ? " (cancelled)" : ""
                let skippedNote = skipped > 0 ? " · \(skipped) skipped (already there)" : ""
                // Originals aren't rendered, so they have no pixels to count.
                let rendered = batches.contains { $0.preset.fileKind != .original }
                let pixelsNote = rendered ? String(format: " · %.1f MP total", Double(totalPixels) / 1_000_000) : ""
                self.summary = String(format: "%d of %d exported%@ in %.1fs%@%@%@",
                                      exported.count, self.total, cancelled, elapsed,
                                      pixelsNote, skippedNote,
                                      MaskSubstitutions.summarySuffix(count: substituted))
                guard !self.stoppingForQuit else { return }
                if !toReveal.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(Array(toReveal.prefix(50)))
                }
                for (app, files) in toOpen { Self.open(files, with: app) }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Output `index` of `plan` settled against the disk, and its folder
    /// made when `makeFolder` (date subfolders) and it is to be written. On
    /// a detached task, never the main actor: both ask the file system,
    /// which on a slow or stalled network share takes as long as it takes.
    nonisolated static func settle(
        _ plan: ExportBatchPlan, index: Int, makeFolder: Bool,
        probe: ExportBatchPlanner.Probe = .system,
        makeDirectory: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    ) async -> (plan: ExportBatchPlan, output: ExportBatchPlan.Output, folderError: Error?) {
        await Task.detached(priority: .userInitiated) {
            var plan = plan
            let output = plan.recheck(index, probe: probe)
            var folderError: Error?
            switch output.action {
            case .write, .replace:
                guard makeFolder else { break }
                do { try makeDirectory(output.url.deletingLastPathComponent()) } catch { folderError = error }
            case .skip, .fail:
                break
            }
            return (plan, output, folderError)
        }.value
    }

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
    /// Where the sheet starts. Settings › Export › Default folder says "The
    /// export sheet starts here", so when one is set it wins; the folder
    /// last chosen with the sheet's own Choose… is used only without one.
    /// `lastUsed` is read only then, since resolving a bookmark asks the
    /// file system.
    static func initialDestination(preference: URL?, lastUsed: () -> URL?) -> URL? {
        preference ?? lastUsed()
    }

    let count: Int
    /// The first selected image, for the naming preview.
    var sample: ImageRecord?
    /// Every image to export, in order, for planning the names.
    var records: [ImageRecord] = []
    var catalogName: String = ""
    /// For the size estimate and quality comparison; nil hides both.
    var preview: ExportPreviewSource?
    /// False while another job holds the GPU, when the queue would refuse.
    var canExport = true
    @State var preset = ExportPreset.load()
    @State private var renderer: ExportPreviewRenderer?
    @StateObject private var estimate = ExportEstimateModel()
    @State private var destination: URL? = ExportSheet.initialDestination(
        preference: AppPreferences.shared.defaultExportFolder,
        lastUsed: { BookmarkStore.resolve(key: BookmarkStore.exportDestination) })
    @State private var savedPresets = ExportPresetStore.load()
    @State private var newPresetName = ""
    @State private var showingSavePreset = false
    /// The names the export would write, planned off the main thread each
    /// time the naming or destination changes. The last plan stays shown
    /// until the next arrives, so typing in the template doesn't flicker.
    @State private var plan: ExportBatchPlan?
    /// Saved presets ticked for a multi-batch export; empty for an
    /// ordinary one with the sheet's settings.
    @State private var batchPresetIDs: Set<UUID> = []
    /// The catalog's folder, where Same folder as original writes.
    var catalogRoot: URL?
    let onExport: ([ExportBatch]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            ExportMultiBatchSection(presets: savedPresets, chosen: $batchPresetIDs)

            groupLabel("File")
            ExportFormatPicker(preset: $preset)
            if preset.rendersImage {
                if preset.format.supportsQuality {
                    HStack {
                        Text("Quality").accessibilityHidden(true)
                        ResettableSlider(value: $preset.quality, in: 0.3...1, label: "Quality",
                                         format: SliderValueFormat(decimals: 0, scale: 100)) { preset.quality = 0.92 }
                        Text(String(format: "%.0f", preset.quality * 100)).monospacedDigit().frame(width: 30)
                            .accessibilityHidden(true)
                        Button("Compare…") { compareQualities() }
                            .controlSize(.small)
                            .disabled(renderer == nil || estimateRecords.isEmpty
                                      || !(preset.format == .jpeg || preset.format == .heic))
                            .accessibilityLabel("Compare qualities")
                            .accessibilityHint("Opens a window showing the first image encoded at several qualities side by side.")
                            .help("See the first image encoded at several qualities side by side at 100%, with file sizes.")
                    }
                }
                ExportFileOptionsSection(preset: $preset)
                if preset.format.supportsGainMap {
                    Toggle("HDR gain map", isOn: $preset.hdrGainMap)
                        .accessibilityLabel("HDR gain map")
                        .accessibilityHint("Adds a gain map so HDR screens show highlights brighter than white. Other screens show the normal image.")
                        .help("Highlights up to two stops brighter on HDR screens, as the editor shows them. Every other viewer shows the normal image.")
                }
                ExportColorSpacePicker(preset: $preset)

                groupLabel("Image Sizing")
                ExportSizingSection(preset: $preset)
                ExportSharpeningSection(preset: $preset)
                ExportWatermarkSection(preset: $preset)
                ExportMetadataSection(preset: $preset)
            } else {
                ExportKindNote(kind: preset.fileKind)
            }

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
                                      destination: planFolder, count: records.count)) {
                    await updatePlan()
                }

            groupLabel("Destination")
            ExportLocationSection(preset: $preset, destination: $destination)
            Toggle("Sort into subfolders by capture date", isOn: $preset.dateSubfolders)

            groupLabel("After Export")
            ExportAfterSection(preset: $preset)
            }
            }
            HStack {
                ExportEstimateLabel(model: estimate)
                    .task(id: estimateRequest) {
                        await estimate.update(records: estimateRecords, preset: preset, renderer: renderer)
                    }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard let batches = makeBatches() else { return }
                    // Stopped now rather than when the sheet has gone, so the
                    // export waits for the estimate's render to stop.
                    releaseRender()
                    // Saved here too, as the sheet's own settings, when
                    // the run is a multi-batch one of saved presets.
                    preset.save()
                    onExport(batches)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasDestination || count == 0 || !unknownTokens.isEmpty || !canExport)
                .help(canExport ? "" : ExportQueue.busyRefusal)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 760)
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

    /// The title and the Presets menu, above the scrolling settings.
    private var header: some View {
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
    }

    private var unknownTokens: [String] { ExportNaming.unknownTokens(in: preset.template) }

    /// Whether every batch knows where to go, or can ask (Choose later).
    private var hasDestination: Bool {
        if !batchPresetIDs.isEmpty {
            return destination != nil || !savedPresets.contains {
                batchPresetIDs.contains($0.id) && $0.preset.location == .chosenFolder
            }
        }
        return preset.location != .chosenFolder || destination != nil
    }

    /// The folder the names are planned in: the photos' catalog for Same
    /// folder as original, else the chosen one (nil before one is chosen,
    /// and for Choose later).
    private var planFolder: URL? {
        switch preset.location {
        case .chosenFolder: destination
        case .sameAsOriginal: catalogRoot
        case .chooseLater: nil
        }
    }

    /// What Export runs: the ticked presets, or the sheet's settings into
    /// its destination (asked for now under Choose later). Nil when a
    /// folder panel was cancelled.
    private func makeBatches() -> [ExportBatch]? {
        if !batchPresetIDs.isEmpty {
            return ExportMultiBatchSection.batches(for: savedPresets, chosen: batchPresetIDs, destination: destination)
        }
        switch preset.location {
        case .chosenFolder:
            return destination.map { [ExportBatch(preset: preset, destination: $0)] }
        case .sameAsOriginal:
            let folder = catalogRoot ?? destination ?? URL(fileURLWithPath: "/", isDirectory: true)
            return [ExportBatch(preset: preset, destination: folder)]
        case .chooseLater:
            return ExportQueue.chooseFolder(for: nil).map { [ExportBatch(preset: preset, destination: $0)] }
        }
    }

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
                               imageIDs: estimateRecords.map(\.id), fileKind: preset.fileKind,
                               sizeLimitBytes: preset.sizeLimitBytes, tiffCompression: preset.tiffCompression)
    }

    private struct EstimateRequest: Equatable {
        var render: ExportPreviewRenderer.Key
        var finish: ExportPreviewRenderer.Finish
        var format: ExportSettings.Format
        var quality: Float
        var imageIDs: [Int64?]
        var fileKind: ExportFileKind
        var sizeLimitBytes: Int?
        var tiffCompression: TIFFCompression
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
        let chosen = planFolder
        let folder = chosen ?? URL(fileURLWithPath: "/", isDirectory: true)
        let probe: ExportBatchPlanner.Probe = chosen == nil ? .nothingOnDisk : .system
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

/// Words for masks made with a stand-in model: an export, a print or a
/// contact sheet whose edit names a model this Mac lacks ran the kind's
/// built-in or bundled one instead (docs/Retouch.md §5). `missing` are
/// the display names `ExportWorker` reports.
enum MaskSubstitutions {
    /// " · 2 with substituted masks", or nothing.
    static func summarySuffix(count: Int) -> String {
        count > 0 ? " · \(count) with substituted masks" : ""
    }

    /// "DSC_0107.NEF used Apple Vision because BiRefNet General is not
    /// installed", for the export panel's notes; the empty-mask words
    /// when nothing stood in (`clause(for:registry:)`).
    static func exportNote(name: String, missing: [String], registry: ModelRegistry = .shared) -> String {
        "\(name) \(clause(for: missing, registry: registry))"
    }

    /// The second sentence of a print's or contact sheet's message: "2
    /// photos used Apple Vision because BiRefNet General is not
    /// installed"; nil when no photo needed a stand-in.
    static func pageSentence(photos: Int, missing: [String], registry: ModelRegistry = .shared) -> String? {
        guard photos > 0, !missing.isEmpty else { return nil }
        let subject = photos == 1 ? "1 photo" : "\(photos) photos"
        return "\(subject) \(clause(for: missing, plural: photos != 1, registry: registry))"
    }

    /// What the file name or the photo count is followed by: "used Apple
    /// Vision because BiRefNet General is not installed" when a stand-in
    /// ran, else the empty-mask words. A click-to-select model with no
    /// stand-in masks nothing at all (`ExportWorker.regenerateMasks`
    /// logs "the mask is empty"), so saying a model was used would be
    /// untrue.
    static func clause(for missing: [String], plural: Bool = false,
                       registry: ModelRegistry = .shared) -> String {
        if let empty = emptyMaskClause(missing, plural: plural, registry: registry) { return empty }
        return "used \(standIn(for: missing, registry: registry)) because \(notInstalled(missing))"
    }

    /// "has an empty click-to-select mask because SAM 2.1 Small could
    /// not be loaded" (plural: "have empty click-to-select masks
    /// because …") when every missing model is a click-to-select one
    /// that nothing stood in for; nil when a stand-in ran. Mirrors
    /// `ModelMenus.missingSentence`'s empty-mask wording.
    static func emptyMaskClause(_ missing: [String], plural: Bool = false,
                                registry: ModelRegistry = .shared) -> String? {
        guard !missing.isEmpty else { return nil }
        let entries = missing.map { name in registry.entries().first { $0.manifest.displayName == name } }
        guard entries.allSatisfy({ $0?.manifest.kind == .promptedSegmentation }) else { return nil }
        guard missing.allSatisfy({ standIn(forMissing: $0, registry: registry) == nil }) else { return nil }
        let reason = entries.allSatisfy { $0?.isInstalled == true }
            ? couldNotLoad(missing)
            : "\(notInstalled(missing)) and no click-to-select model is"
        let subject = plural ? "have empty click-to-select masks" : "has an empty click-to-select mask"
        return "\(subject) because \(reason)"
    }

    /// "SAM 2.1 Small could not be loaded" / "A and B could not be
    /// loaded", for a model that is installed but will not open.
    static func couldNotLoad(_ missing: [String]) -> String {
        switch missing.count {
        case 0: return "a model could not be loaded"
        case 1: return "\(missing[0]) could not be loaded"
        default: return missing.dropLast().joined(separator: ", ") + " and \(missing.last!) could not be loaded"
        }
    }

    /// "BiRefNet General is not installed" / "BiRefNet General and SAM 2.1
    /// Large are not installed".
    static func notInstalled(_ missing: [String]) -> String {
        switch missing.count {
        case 0: return "a model is not installed"
        case 1: return "\(missing[0]) is not installed"
        default: return missing.dropLast().joined(separator: ", ") + " and \(missing.last!) are not installed"
        }
    }

    /// What ran instead: Apple Vision for a subject model, the default
    /// click-to-select model for one of those, the installed class model
    /// for a class model; "stand-in models" when several kinds are
    /// missing or the name is not one the registry lists.
    static func standIn(for missing: [String], registry: ModelRegistry = .shared) -> String {
        let standIns = missing.map { standIn(forMissing: $0, registry: registry) }
        guard let first = standIns.first, let name = first, standIns.allSatisfy({ $0 == name }) else {
            return "stand-in models"
        }
        return name
    }

    static func standIn(forMissing name: String, registry: ModelRegistry) -> String? {
        guard let entry = registry.entries().first(where: { $0.manifest.displayName == name }) else { return nil }
        switch entry.manifest.kind {
        case .subjectSegmentation:
            return registry.entry(id: ModelRegistry.builtInSubjectID)?.manifest.displayName ?? "Apple Vision"
        case .promptedSegmentation:
            // The default click-to-select model stands in — unless it is
            // the very model that would not load, or there is none: then
            // nothing ran and the mask is empty.
            guard let fallback = registry.defaultPrompted(), fallback.id != entry.id else { return nil }
            return fallback.manifest.displayName
        case .semanticSegmentation:
            return registry.installed(ModelRef(id: SegmentationModel.modelID, version: 1))?.manifest.displayName
        case .depth:
            // Lens Blur's depth falls back to the subject mask's two planes.
            return LensBlurDepth.displayName(of: LensBlur.subjectDepthVersion, registry: registry)
        case .denoise, .reflectionRemoval:
            return nil
        }
    }
}
