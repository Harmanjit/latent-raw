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
    var suffix = ""

    var settings: ExportSettings { ExportSettings(format: format, quality: quality) }
    var colorSpace: ColorKit.OutputSpace { colorSpaceIsP3 ? .displayP3 : .sRGB }

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
        done = 0; total = records.count; failures = []; summary = ""
        preset.save()

        task = Task { [weak self] in
            let start = Date()
            var totalPixels = 0
            for record in records {
                if Task.isCancelled { break }
                let name = record.fileName
                await MainActor.run { self?.currentName = name }

                // Everything the worker needs, gathered on the actor side.
                let json = try? await catalog.editStack(forImageID: record.id ?? -1)
                let keywords = (try? await catalog.keywords(forImageID: record.id ?? -1)) ?? []
                let base = (record.relPath as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "_")
                let file = base + preset.suffix + "." + preset.settings.format.fileExtension
                let request = ExportWorker.Request(
                    sourceURL: root.appendingPathComponent(record.relPath),
                    destinationURL: destination.appendingPathComponent(file),
                    editStackJSON: json, userRotation: record.userRotation,
                    settings: preset.settings, colorSpace: preset.colorSpace,
                    maxLongEdge: preset.resize ? preset.maxLongEdge : nil,
                    keywords: keywords, rating: record.rating)

                let outcome: Result<ExportWorker.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                    do { return .success(try await ExportWorker.export(request, gpu: gpu)) }
                    catch { return .failure(error) }
                }.value

                await MainActor.run {
                    guard let self else { return }
                    self.done += 1
                    switch outcome {
                    case .success(let o): totalPixels += o.pixelWidth * o.pixelHeight
                    case .failure(let e): self.failures.append(Failure(name: name, reason: "\(e)"))
                    }
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            await MainActor.run {
                guard let self else { return }
                self.isRunning = false
                self.currentName = ""
                let cancelled = Task.isCancelled ? " (cancelled)" : ""
                self.summary = String(format: "%d of %d exported%@ in %.1fs · %.1f MP total",
                                      self.done - self.failures.count, self.total, cancelled, elapsed,
                                      Double(totalPixels) / 1_000_000)
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// The export sheet: preset controls and a destination.
struct ExportSheet: View {
    let count: Int
    @State var preset = ExportPreset.load()
    @State private var destination: URL? = UserDefaults.standard.url(forKey: "latent.exportDestination")
    let onExport: (ExportPreset, URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(count) image\(count == 1 ? "" : "s")").font(.headline)

            Picker("Format", selection: $preset.format) {
                ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if preset.format.supportsQuality {
                HStack {
                    Text("Quality")
                    Slider(value: $preset.quality, in: 0.3...1)
                        .resetsOnDoubleClick { preset.quality = 0.92 }
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
            HStack {
                Text("Filename suffix")
                TextField("e.g. -web", text: $preset.suffix).frame(width: 120)
                Text("(original name + suffix)").foregroundStyle(.secondary).font(.caption)
            }
            HStack {
                Text("Destination")
                Text(destination?.path ?? "choose a folder…").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(destination == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                    panel.message = "Folder to export into"
                    if panel.runModal() == .OK, let url = panel.url {
                        destination = url
                        UserDefaults.standard.set(url, forKey: "latent.exportDestination")
                    }
                }
            }
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
        .frame(width: 460)
    }
}
