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
/// Only one render is kept, and only settings that change what the GPU
/// renders make a new one (size, colour space, bit depth, gain map). The
/// watermark and the metadata switches don't: the render is made without
/// the watermark and with the metadata read, and each caller gets a copy
/// finished with the sheet's (`ExportWorker.Rendered.finished`), so typing
/// a watermark or dragging its sliders encodes again but never renders.
@MainActor
final class ExportPreviewRenderer {
    /// Renders `record` at a preset whose watermark is off and metadata on.
    typealias RenderPlain = @Sendable (ImageRecord, ExportPreset) async throws -> ExportWorker.Rendered

    /// Everything that changes an export's rendered pixels.
    struct Key: Equatable, Sendable {
        var imageID: Int64?
        var relPath: String
        var bitsPerComponent: Int
        var gainMap: Bool
        var colorSpaceIsP3: Bool
        var maxLongEdge: Int?

        init(record: ImageRecord, preset: ExportPreset) {
            imageID = record.id; relPath = record.relPath
            bitsPerComponent = preset.format == .tiff ? 16 : 8
            gainMap = preset.settings.writesGainMap
            colorSpaceIsP3 = preset.colorSpaceIsP3
            maxLongEdge = preset.resize ? preset.maxLongEdge : nil
        }
    }

    /// What is applied to a render before it is encoded: the watermark,
    /// stamped into a copy, and the metadata the file carries.
    struct Finish: Equatable, Sendable {
        var watermark: ExportWatermark?
        var includeMetadata: Bool
        var includeLocation: Bool

        init(preset: ExportPreset) {
            watermark = preset.settings.watermark
            includeMetadata = preset.includeMetadata
            includeLocation = preset.includeMetadata && preset.includeLocation
        }
    }

    private let renders = SharedRender<Key, ExportWorker.Rendered>()
    private let renderPlain: RenderPlain
    /// Renders started so far; for tests.
    var renderCount: Int { renders.started }

    /// Renders let go with their sheet that are still stopping; see
    /// `waitForDiscardedRenders`.
    private static var discarded: Task<Void, Never>?

    convenience init(source: ExportPreviewSource) {
        self.init { record, preset in
            let id = record.id ?? -1
            let json = try await source.catalog.editStack(forImageID: id)
            let keywords = try await source.catalog.keywords(forImageID: id)
            try Task.checkCancellation()
            let request = preset.workerRequest(for: record, root: source.root,
                                               destination: URL(fileURLWithPath: "/dev/null"),
                                               editStackJSON: json, keywords: keywords)
            return try await ExportWorker.render(request, gpu: source.gpu)
        }
    }

    init(renderPlain: @escaping RenderPlain) {
        self.renderPlain = renderPlain
    }

    /// The render for `record` at `preset`, from the cache when it matches,
    /// finished with `preset`'s watermark and metadata.
    func rendered(_ record: ImageRecord, preset: ExportPreset) async throws -> ExportWorker.Rendered {
        // Made once for every watermark and metadata choice.
        var plain = preset
        plain.watermarkEnabled = false
        plain.includeMetadata = true
        plain.includeLocation = true
        let renderPlain = renderPlain
        let rendered = try await renders.value(for: Key(record: record, preset: preset)) { [plain] in
            try await renderPlain(record, plain)
        }
        let finish = Finish(preset: preset)
        return try await Task.detached(priority: .userInitiated) {
            try rendered.finished(watermark: finish.watermark, includeMetadata: finish.includeMetadata,
                                  includeLocation: finish.includeLocation)
        }.value
    }

    /// Stops a render under way and lets the kept one go.
    func discard() {
        guard let stopping = renders.discard() else { return }
        let before = Self.discarded
        Self.discarded = Task {
            await before?.value
            _ = await stopping.result
        }
    }

    /// Returns once renders discarded with an export sheet have stopped
    /// (a render only stops between phases), so the export that sheet
    /// started doesn't render beside one.
    static func waitForDiscardedRenders() async {
        await discarded?.value
    }
}

/// One render at a time, shared: callers asking for the same key wait on
/// the same render, and the last one made is kept.
///
/// A render for another key doesn't start until the one before has ended,
/// so two full-size renders are never on the GPU together. The one before
/// is cancelled (it stops at its next phase) unless a caller is still
/// waiting for it: the quality comparison asks once and waits, and must
/// not be left spinning because the size estimate moved on. It is
/// cancelled later if that caller stops waiting.
@MainActor
final class SharedRender<Key: Equatable & Sendable, Value: Sendable> {
    /// A caller waiting on a render; cancelled when its task is.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// `@unchecked Sendable`: only touched on the main actor.
    private final class Render: @unchecked Sendable {
        let key: Key
        let task: Task<Value, Error>
        var waiters: [Waiter] = []
        init(key: Key, task: Task<Value, Error>) { self.key = key; self.task = task }
        var isWanted: Bool { waiters.contains { !$0.isCancelled } }
    }

    /// The render before, until the next has waited for it; then let go,
    /// so its pixels don't live on through the next render.
    private final class Previous: @unchecked Sendable {
        private var task: Task<Value, Error>?
        init(_ task: Task<Value, Error>?) { self.task = task }
        func waitForEnd() async {
            _ = await task?.result
            task = nil
        }
    }

    private var cached: (key: Key, value: Value)?
    private var inFlight: Render?
    /// Renders started so far; for tests.
    private(set) var started = 0

    func value(for key: Key, make: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let cached, cached.key == key { return cached.value }
        let render: Render
        if let inFlight, inFlight.key == key {
            render = inFlight
        } else {
            if let old = inFlight, !old.isWanted { old.task.cancel() }
            // Let the old pixels go before the new ones are made.
            cached = nil
            let previous = Previous(inFlight?.task)
            render = Render(key: key, task: Task.detached(priority: .userInitiated) {
                await previous.waitForEnd()
                try Task.checkCancellation()
                return try await make()
            })
            inFlight = render
            started += 1
        }
        let waiter = Waiter()
        render.waiters.append(waiter)
        do {
            let value = try await withTaskCancellationHandler {
                try await render.task.value
            } onCancel: {
                waiter.cancel()
                Task { @MainActor [weak self] in self?.cancelIfUnwanted(render) }
            }
            if inFlight === render {
                inFlight = nil
                cached = (key, value)
            }
            return value
        } catch {
            if inFlight === render { inFlight = nil }
            throw error
        }
    }

    /// A render superseded by another that nobody waits for any more.
    private func cancelIfUnwanted(_ render: Render) {
        if inFlight !== render, !render.isWanted { render.task.cancel() }
    }

    /// Stops the render under way, whoever waits for it, and lets the kept
    /// one go. Returns the stopped render, which ends at its next phase.
    @discardableResult
    func discard() -> Task<Value, Error>? {
        let stopping = inFlight?.task
        stopping?.cancel()
        inFlight = nil
        cached = nil
        return stopping
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
