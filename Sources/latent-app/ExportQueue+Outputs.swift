import Foundation
import AppKit
import PixelEngine
import Catalog
import MLKit
import MergeKit

/// One run of the queue over the selection: a preset and the folder it
/// writes into. A multi-batch export is several, run one after another.
struct ExportBatch: Codable, Equatable {
    var preset: ExportPreset
    var destination: URL
    /// The saved preset's name, for a multi-batch export's summary.
    var name: String?
}

/// What one file of an export came to, whatever kind of file it was.
struct ExportFileResult: Sendable {
    var pixelCount: Int
    var maskSubstitutions: [String]
}

/// One photo's file: the work `ExportQueue` hands to a detached task.
/// Everything it needs was read on the queue's side first.
struct ExportFileJob: Sendable {
    var kind: ExportFileKind
    var request: ExportWorker.Request
    /// For a DNG's recipe: the catalog's hash and capture time of the original.
    var sourceHash: String
    var captureTime: Int64
    /// For originals: what the XMP sidecar says (rating, label, keywords,
    /// the edit), as the catalog's own sidecar has it; nil writes none.
    var sidecar: XMPSidecar.Fields?

    func run(gpu: GPUContext) async throws -> ExportFileResult {
        switch kind {
        case .image:
            let outcome = try await ExportWorker.export(request, gpu: gpu)
            return ExportFileResult(pixelCount: outcome.pixelWidth * outcome.pixelHeight,
                                    maskSubstitutions: outcome.maskSubstitutions)
        case .dng:
            let rendered = try await ExportWorker.renderSceneLinear(
                sourceURL: request.sourceURL, editStackJSON: request.editStackJSON,
                userRotation: request.userRotation, gpu: gpu)
            let destination = request.destinationURL
            let source = MergeRecipe.Source(
                path: RenderedDNGExport.relativePath(of: request.sourceURL, from: destination.deletingLastPathComponent()),
                hash: sourceHash, captureTime: captureTime)
            try RenderedDNGExport.write(texture: rendered.texture, commandQueue: gpu.commandQueue,
                                        summary: rendered.summary, cameraToXYZ: rendered.cameraToXYZ,
                                        lensModel: rendered.lensModel, preview: rendered.preview, source: source,
                                        softwareVersion: Self.softwareVersion, to: destination,
                                        replacingExisting: request.replacesExisting)
            return ExportFileResult(pixelCount: rendered.texture.width * rendered.texture.height,
                                    maskSubstitutions: rendered.maskSubstitutions)
        case .original:
            try Self.copyOriginal(request.sourceURL, to: request.destinationURL, sidecar: sidecar,
                                  replacingExisting: request.replacesExisting)
            return ExportFileResult(pixelCount: 0, maskSubstitutions: [])
        }
    }

    static var softwareVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Where an original's sidecar goes: beside it, named as Lightroom,
    /// Bridge and Capture One look for one (`DSC_0107.xmp`).
    static func sidecarURL(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Copies the original under a temporary name and moves it into place
    /// when complete, then writes its sidecar. The copy is a clone on APFS.
    static func copyOriginal(_ source: URL, to destination: URL, sidecar: XMPSidecar.Fields?,
                             replacingExisting: Bool) throws {
        let pending = try SafeFileWriter.begin(destination)
        defer { pending.discard() }
        if FileManager.default.fileExists(atPath: pending.url.path) {
            try FileManager.default.removeItem(at: pending.url)
        }
        try FileManager.default.copyItem(at: source, to: pending.url)
        try pending.commit(replacingExisting: replacingExisting)
        if let sidecar {
            // The sidecar follows its file: written (or replaced) once the
            // file is in place, so a skipped or failed copy leaves none.
            try XMPSidecar.write(sidecar, to: sidecarURL(for: pending.destination))
        }
    }
}

/// The last export's batches, for File › Export With Previous. Kept in
/// UserDefaults with each folder as a security-scoped bookmark, since the
/// sandbox forgets a folder the user chose once the app quits.
enum ExportPrevious {
    static let key = "latent.exportPrevious"

    private struct Stored: Codable {
        var preset: ExportPreset
        var bookmark: Data?
        var name: String?
    }

    static func save(_ batches: [ExportBatch], defaults: UserDefaults = .standard) {
        let stored = batches.map { batch in
            Stored(preset: batch.preset,
                   bookmark: batch.preset.location == .chosenFolder ? BookmarkStore.bookmark(for: batch.destination) : nil,
                   name: batch.name)
        }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }

    /// The previous batches with their folders where those can still be
    /// reached; a nil folder is asked for again (Choose later, or a folder
    /// that has gone).
    static func load(defaults: UserDefaults = .standard) -> [(preset: ExportPreset, folder: URL?, name: String?)] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map { item in
            let folder = item.bookmark.flatMap { BookmarkStore.resolveQuietly($0)?.url }
            // Held for the life of the app, as BookmarkStore's folders are.
            if let folder { _ = folder.startAccessingSecurityScopedResource() }
            return (item.preset, folder, item.name)
        }
    }

    static var exists: Bool { UserDefaults.standard.data(forKey: key) != nil }
}

extension ExportQueue {
    /// Asks for the folder a Choose-later export writes into; nil when
    /// cancelled. `name` says which preset, in a multi-batch export.
    static func chooseFolder(for name: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = name.map { "Folder to export “\($0)” into" } ?? "Folder to export into"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Opens finished files in the chosen app, as Lightroom's "Open in
    /// Other Application" does after an export.
    static func open(_ files: [URL], with app: URL) {
        guard !files.isEmpty else { return }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension ExportQueue {
    /// File › Export with Previous: the selection exported again with the
    /// last export's batches. A folder that can't be reached any more, or a
    /// preset set to Choose later, is asked for; cancelling stops it all.
    func exportWithPrevious(records: [ImageRecord], library: Library, gpu: GPUContext,
                            previous: [(preset: ExportPreset, folder: URL?, name: String?)] = ExportPrevious.load(),
                            choose: (String?) -> URL? = { ExportQueue.chooseFolder(for: $0) }) {
        guard !records.isEmpty, !previous.isEmpty else { return }
        var batches: [ExportBatch] = []
        for item in previous {
            let folder: URL
            switch item.preset.location {
            case .sameAsOriginal:
                folder = library.folderURL ?? URL(fileURLWithPath: "/", isDirectory: true)
            case .chosenFolder:
                guard let known = item.folder ?? choose(item.name) else { return }
                folder = known
            case .chooseLater:
                guard let asked = choose(item.name) else { return }
                folder = asked
            }
            batches.append(ExportBatch(preset: item.preset, destination: folder, name: item.name))
        }
        start(records: records, library: library, batches: batches, gpu: gpu)
    }
}
