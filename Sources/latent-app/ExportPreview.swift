import Foundation
import SwiftUI
import PixelEngine
import Catalog
import MLKit

/// What the export sheet needs to render an image the way the export will:
/// the catalog's folder and database, and the GPU.
struct ExportPreviewSource {
    let root: URL
    let catalog: Catalog
    let gpu: GPUContext

    @MainActor init?(library: Library, gpu: GPUContext?) {
        guard let root = library.folderURL, let catalog = library.catalog, let gpu else { return nil }
        self.root = root; self.catalog = catalog; self.gpu = gpu
    }
}

/// One image rendered through `ExportWorker.render` for the export sheet,
/// kept while the sheet is open so the size estimate and the quality
/// comparison can encode it again at another quality or format without
/// rendering it again.
///
/// Only one render is kept, and only settings that change the pixels make
/// a new one (size, colour space, bit depth, gain map, watermark,
/// metadata); quality and JPEG versus HEIC don't. A new render cancels the
/// one under way, which stops at its next phase.
@MainActor
final class ExportPreviewRenderer {
    let source: ExportPreviewSource

    /// Everything that changes an export's pixels or metadata.
    struct Key: Equatable {
        var imageID: Int64?
        var relPath: String
        var bitsPerComponent: Int
        var gainMap: Bool
        var colorSpaceIsP3: Bool
        var maxLongEdge: Int?
        var watermark: ExportWatermark?
        var includeMetadata: Bool
        var includeLocation: Bool

        init(record: ImageRecord, preset: ExportPreset) {
            imageID = record.id; relPath = record.relPath
            bitsPerComponent = preset.format == .tiff ? 16 : 8
            gainMap = preset.settings.writesGainMap
            colorSpaceIsP3 = preset.colorSpaceIsP3
            maxLongEdge = preset.resize ? preset.maxLongEdge : nil
            watermark = preset.settings.watermark
            includeMetadata = preset.includeMetadata
            includeLocation = preset.includeMetadata && preset.includeLocation
        }
    }

    private var cached: (key: Key, rendered: ExportWorker.Rendered)?
    private var inFlight: (key: Key, task: Task<ExportWorker.Rendered, Error>)?

    init(source: ExportPreviewSource) {
        self.source = source
    }

    /// The render for `record` at `preset`, from the cache when it matches.
    func rendered(_ record: ImageRecord, preset: ExportPreset) async throws -> ExportWorker.Rendered {
        let key = Key(record: record, preset: preset)
        if let cached, cached.key == key { return cached.rendered }
        if let inFlight, inFlight.key == key { return try await inFlight.task.value }
        inFlight?.task.cancel()
        // Let the old pixels go before the new ones are made.
        cached = nil
        let source = source
        let task = Task.detached(priority: .userInitiated) { () throws -> ExportWorker.Rendered in
            let id = record.id ?? -1
            let json = try await source.catalog.editStack(forImageID: id)
            let keywords = try await source.catalog.keywords(forImageID: id)
            try Task.checkCancellation()
            let request = preset.workerRequest(for: record, root: source.root,
                                               destination: URL(fileURLWithPath: "/dev/null"),
                                               editStackJSON: json, keywords: keywords)
            return try await ExportWorker.render(request, gpu: source.gpu)
        }
        inFlight = (key, task)
        do {
            let rendered = try await task.value
            if inFlight?.key == key {
                inFlight = nil
                cached = (key, rendered)
            }
            return rendered
        } catch {
            if inFlight?.key == key { inFlight = nil }
            throw error
        }
    }

    /// Stops a render under way and lets the kept one go.
    func discard() {
        inFlight?.task.cancel()
        inFlight = nil
        cached = nil
    }
}

/// The export sheet's estimate of how much the export will write.
@MainActor
final class ExportEstimateModel: ObservableObject {
    enum State: Equatable {
        case none
        case working
        case ready(bytes: Int, images: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .none
    /// The last figure, still shown (dimmed) while a new one is worked out.
    @Published private(set) var lastBytes: Int?

    /// Renders (or reuses) the first image, encodes it at the preset's
    /// settings off the main thread and extrapolates over `records`. Waits
    /// a moment first, so dragging a slider or typing estimates once;
    /// returns quietly when its task is cancelled by a newer request.
    func update(records: [ImageRecord], preset: ExportPreset, renderer: ExportPreviewRenderer?) async {
        guard let renderer, let first = records.first else { state = .none; return }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        state = .working
        do {
            let rendered = try await renderer.rendered(first, preset: preset)
            try Task.checkCancellation()
            var settings = rendered.settings
            settings.format = preset.format
            settings.quality = preset.quality
            let encodeSettings = settings
            let encoding = Task.detached(priority: .userInitiated) { try rendered.encoded(with: encodeSettings).count }
            let bytes = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
            try Task.checkCancellation()
            let total = ExportSizeEstimate.totalBytes(sampleBytes: bytes,
                                                      samplePixels: rendered.pixelWidth * rendered.pixelHeight,
                                                      records: records,
                                                      maxLongEdge: preset.resize ? preset.maxLongEdge : nil)
            lastBytes = total
            state = .ready(bytes: total, images: records.count)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed("\(error)")
        }
    }

    /// "About 12.4 MB", or "About 140 MB for 12 images".
    static func text(bytes: Int, images: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return images == 1 ? "About \(size)" : "About \(size) for \(images) images"
    }
}
