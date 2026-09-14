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
    var sequencePadding = 3
    var collision: ExportNaming.Collision = .addNumber
    /// Put each image in a yyyy-MM-dd subfolder of the destination.
    var dateSubfolders = false
    var includeMetadata = true
    var revealWhenDone = true

    var settings: ExportSettings { ExportSettings(format: format, quality: quality) }
    var colorSpace: ColorKit.OutputSpace { colorSpaceIsP3 ? .displayP3 : .sRGB }

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
        sequencePadding = try c.decodeIfPresent(Int.self, forKey: .sequencePadding) ?? 3
        collision = try c.decodeIfPresent(ExportNaming.Collision.self, forKey: .collision) ?? .addNumber
        dateSubfolders = try c.decodeIfPresent(Bool.self, forKey: .dateSubfolders) ?? false
        includeMetadata = try c.decodeIfPresent(Bool.self, forKey: .includeMetadata) ?? true
        revealWhenDone = try c.decodeIfPresent(Bool.self, forKey: .revealWhenDone) ?? true
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

    func start(records: [ImageRecord], library: Library, preset: ExportPreset,
               destination: URL, gpu: GPUContext) {
        guard !isRunning, !records.isEmpty, let catalog = library.catalog, let root = library.folderURL else { return }
        isRunning = true
        stoppingForQuit = false
        done = 0; total = records.count; failures = []; summary = ""
        preset.save()

        task = Task { [weak self] in
            let start = Date()
            var totalPixels = 0
            let catalogName = root.lastPathComponent
            var skipped = 0
            var written: [URL] = []
            for (index, record) in records.enumerated() {
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
                // Name, folder and collision policy.
                let stem = ExportNaming.fileName(
                    template: preset.template, record: record,
                    context: .init(index: index, start: preset.sequenceStart,
                                   padding: preset.sequencePadding, catalogName: catalogName))
                var folder = destination
                if preset.dateSubfolders {
                    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                    let date = Date(timeIntervalSince1970: TimeInterval(record.captureTime ?? record.mtime / 1000))
                    folder = destination.appendingPathComponent(df.string(from: date), isDirectory: true)
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
                let proposed = folder.appendingPathComponent(stem).appendingPathExtension(preset.settings.format.fileExtension)
                guard let target = ExportNaming.resolve(proposed, collision: preset.collision) else {
                    skipped += 1
                    await MainActor.run { self?.done += 1 }
                    continue
                }
                let request = ExportWorker.Request(
                    sourceURL: root.appendingPathComponent(record.relPath),
                    destinationURL: target,
                    editStackJSON: json, userRotation: record.userRotation,
                    settings: preset.settings, colorSpace: preset.colorSpace,
                    maxLongEdge: preset.resize ? preset.maxLongEdge : nil,
                    keywords: preset.includeMetadata ? keywords : [],
                    rating: preset.includeMetadata ? record.rating : 0,
                    includeMetadata: preset.includeMetadata)

                let outcome: Result<ExportWorker.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                    do { return .success(try await ExportWorker.export(request, gpu: gpu)) }
                    catch { return .failure(error) }
                }.value

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
    var catalogName: String = ""
    @State var preset = ExportPreset.load()
    @State private var destination: URL? = BookmarkStore.resolve(key: BookmarkStore.exportDestination)
        ?? AppPreferences.shared.defaultExportFolder
    @State private var savedPresets = ExportPresetStore.load()
    @State private var newPresetName = ""
    @State private var showingSavePreset = false
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
                    Text("Quality")
                    ResettableSlider(value: $preset.quality, in: 0.3...1) { preset.quality = 0.92 }
                    Text(String(format: "%.0f", preset.quality * 100)).monospacedDigit().frame(width: 30)
                }
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
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                    ForEach([1024, 2048, 4096], id: \.self) { n in
                        Button("\(n)") { preset.maxLongEdge = n }.controlSize(.small)
                    }
                }
            }
            Toggle("Include camera metadata, keywords and rating", isOn: $preset.includeMetadata)

            groupLabel("Naming")
            HStack {
                Text("Template")
                TextField("{name}", text: $preset.template)
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
                Text("digits")
                Stepper("\(preset.sequencePadding)", value: $preset.sequencePadding, in: 1...6).frame(width: 70)
                Spacer()
                Picker("If the file exists", selection: $preset.collision) {
                    ForEach(ExportNaming.Collision.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 230)
            }
            if let sample {
                let name = ExportNaming.fileName(template: preset.template, record: sample,
                                                 context: .init(index: 0, start: preset.sequenceStart,
                                                                padding: preset.sequencePadding, catalogName: catalogName))
                Text("First file: \(name).\(preset.format.fileExtension)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            groupLabel("Destination")
            HStack {
                Text(destination?.path ?? "choose a folder…").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(destination == nil ? .secondary : .primary)
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
            if preset.resize && preset.format == .tiff {
                Text("Resized exports are written at 8 bits per channel; full-size TIFF keeps 16.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") {
                    if let destination { onExport(preset, destination); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil || count == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
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

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
            .padding(.top, 4)
    }
}
