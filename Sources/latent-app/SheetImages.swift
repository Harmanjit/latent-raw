import AppKit
import ColorKit
import Catalog
import PixelEngine
import MLKit

// The pictures Print and Contact Sheet put on a page: what each one is,
// renders through ExportWorker at the size a cell needs, small previews
// that never block, and drawing a page from them. Nothing here runs on the
// main actor except gathering the items and asking the Library for
// thumbnails; pages are drawn on the print operation's own thread or a
// GCD worker.

/// One picture to lay out, with everything a render needs taken up front,
/// so a page drawn later draws what was chosen (an edit made meanwhile
/// waits for the next print).
struct SheetItem: Sendable, Equatable {
    var name: String
    var sourceURL: URL
    var editStackJSON: String?
    var userRotation: Int
    var captureDate: Date?
    var camera: String?
    /// For its thumbnail; nil for a file opened on its own.
    var record: ImageRecord?

    /// The same picture looks the same: file, edit and turn.
    var cacheKey: String {
        "\(sourceURL.path)#\(userRotation)#\(editStackJSON?.hashValue ?? 0)"
    }

    func captionLines(_ caption: CaptionContent) -> [String] {
        caption.lines(name: name, date: captureDate, camera: camera)
    }
}

extension SheetItem {
    init(record: ImageRecord, folder: URL, editStackJSON: String?) {
        self.init(name: record.fileName, sourceURL: folder.appendingPathComponent(record.relPath),
                  editStackJSON: editStackJSON, userRotation: record.userRotation,
                  captureDate: record.captureTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                  camera: record.camera, record: record)
    }
}

/// A flag a long job checks between steps; set from any thread.
final class SheetCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Rendered pictures by item and size, least recently used out first once
/// past the byte budget. A request is served by an entry rendered for at
/// least that size, or by one that came out smaller than asked (the whole
/// image is that small), as long as it isn't more than twice the size:
/// larger only costs the page's drawing time.
final class SheetImageCache: @unchecked Sendable {
    private struct Entry {
        var image: CGImage
        var requested: Int
        var bytes: Int
        var lastUse: UInt64
    }

    let byteBudget: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    init(byteBudget: Int) {
        self.byteBudget = byteBudget
    }

    func image(for key: String, longEdge wanted: Int) -> CGImage? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            let longEdge = max(entry.image.width, entry.image.height)
            let complete = longEdge < entry.requested
            guard entry.requested >= wanted || complete, longEdge <= max(wanted * 2, 64) || complete else { return nil }
            clock += 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.image
        }
    }

    func store(_ image: CGImage, for key: String, requested: Int) {
        let cost = image.bytesPerRow * image.height
        lock.withLock {
            if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
            // An image larger than the whole budget is used once, not kept.
            guard cost <= byteBudget else { return }
            clock += 1
            entries[key] = Entry(image: image, requested: requested, bytes: cost, lastUse: clock)
            bytes += cost
            while bytes > byteBudget, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                entries.removeValue(forKey: oldest.key)
                bytes -= oldest.value.bytes
            }
        }
    }

    var cachedBytes: Int { lock.withLock { bytes } }
    var cachedCount: Int { lock.withLock { entries.count } }
}

/// How pictures are rendered for a page: through `ExportWorker`, one at a
/// time (the GPU is one resource, as for the export queue), in the page's
/// colour space, then converted to a printer profile when one is given.
/// Blocking: call it from the print operation's thread or a GCD worker,
/// never the main thread or a Swift concurrency thread.
final class SheetRenderer: @unchecked Sendable {
    /// Renders one item at a long edge; nil when it can't be rendered.
    typealias Render = @Sendable (SheetItem, Int) -> CGImage?

    let cache: SheetImageCache
    private let render: Render
    private let serial = NSLock()
    private let failureLock = NSLock()
    private var failed: [String] = []

    /// Names of the photos that couldn't be rendered, in the order tried.
    var failedNames: [String] { failureLock.withLock { failed } }

    init(cache: SheetImageCache, render: @escaping Render) {
        self.cache = cache
        self.render = render
    }

    /// Renders through ExportWorker in `colorSpace` at `bitsPerComponent`;
    /// with `profile`, the result is converted into it (perceptual, as the
    /// soft proof shows it) and tagged with it. AI denoise, which takes
    /// seconds per photo, runs for renders at least `aiDenoiseFrom` pixels
    /// on the long edge (0 always, `Int.max` never): a small cell can't show it.
    convenience init(gpu: GPUContext, colorSpace: ColorKit.OutputSpace, bitsPerComponent: Int, aiDenoiseFrom: Int,
                     profile: SheetProfile?, cacheBudget: Int) {
        self.init(cache: SheetImageCache(byteBudget: cacheBudget)) { item, longEdge in
            let request = ExportWorker.ImageRequest(sourceURL: item.sourceURL, editStackJSON: item.editStackJSON,
                                                    userRotation: item.userRotation, colorSpace: colorSpace,
                                                    maxLongEdge: longEdge, bitsPerComponent: bitsPerComponent,
                                                    runsAIDenoise: longEdge >= aiDenoiseFrom)
            let outcome = Self.wait { () -> Result<RenderedImage, any Error> in
                do { return .success(try await ExportWorker.renderImage(request, gpu: gpu)) } catch { return .failure(error) }
            }
            let rendered: RenderedImage
            switch outcome {
            case .success(let image):
                rendered = image
            case .failure(let error):
                // Drawn as an empty cell with its caption, so the rest of
                // the page still prints; the reason goes to the log.
                Log.editor.error("page render of \(item.name, privacy: .private) failed: \(String(describing: error), privacy: .private)")
                return nil
            }
            guard let profile else { return rendered.cgImage }
            return SheetColorConversion.convert(rendered.cgImage, to: profile.colorSpace) ?? rendered.cgImage
        }
    }

    /// The picture for a cell needing `longEdge` pixels, from the cache or
    /// rendered now. A render that shows the picture's shape needs more
    /// than was estimated (a fill of a panorama) is done once more at the
    /// size that shape needs.
    func image(for item: SheetItem, longEdge: Int, neededFor shape: (CGSize) -> Int) -> CGImage? {
        let key = item.cacheKey
        if let cached = cache.image(for: key, longEdge: longEdge) { return cached }
        return serial.withLock { () -> CGImage? in
            if let cached = cache.image(for: key, longEdge: longEdge) { return cached }
            guard var image = render(item, longEdge) else {
                failureLock.withLock { if !failed.contains(item.name) { failed.append(item.name) } }
                return nil
            }
            cache.store(image, for: key, requested: longEdge)
            let size = CGSize(width: image.width, height: image.height)
            let actual = shape(size)
            if max(image.width, image.height) >= longEdge, Double(actual) > Double(longEdge) * 1.15,
               let larger = render(item, actual) {
                cache.store(larger, for: key, requested: actual)
                image = larger
            }
            return image
        }
    }

    /// Runs async work to completion from a thread that may block.
    static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

/// A printer or paper profile chosen for Soft Proof, read once.
struct SheetProfile: @unchecked Sendable {
    let url: URL
    let colorSpace: CGColorSpace

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let space = CGColorSpace(iccData: data as CFData) else { return nil }
        self.url = url
        colorSpace = space
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum SheetColorConversion {
    /// `image` converted into `space` by ColorSync, perceptual intent: 16
    /// bits for RGB and grey profiles, 8 for CMYK (all Core Graphics draws
    /// CMYK at). Nil for a space a bitmap can't use.
    static func convert(_ image: CGImage, to space: CGColorSpace) -> CGImage? {
        let bits: Int
        let info: CGBitmapInfo
        switch space.model {
        case .rgb:
            bits = 16
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        case .monochrome:
            bits = 16
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        case .cmyk:
            bits = 8
            info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        default:
            return nil
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bits,
                                      bytesPerRow: 0, space: space, bitmapInfo: info.rawValue) else { return nil }
        context.setRenderingIntent(.perceptual)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// Asks for an item's thumbnail, calling back with it (nil when there is
/// none yet); returns false when it can't be asked for (no record).
typealias SheetThumbnailSource = @MainActor @Sendable (SheetItem, @escaping @MainActor @Sendable (CGImage?) -> Void) -> Bool

/// Small pictures for a preview (the print panel's, the contact sheet
/// dialog's): the Library's thumbnail, which already shows the edit, or
/// for a file without one a small render on a background queue. Reading
/// is thread-safe and never waits; what is missing is asked for, and
/// `onReady` runs on the main actor as pictures arrive.
final class SheetPreviewImages: @unchecked Sendable {
    /// A thumbnail good for a preview cell; the Library's grid size.
    static let pixelSize = Thumbnailer.size

    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []
    private let renderer: SheetRenderer?
    private let fallbackQueue = DispatchQueue(label: "latent.sheet.preview", qos: .userInitiated)
    /// Thumbnails come from here, on the main actor.
    private let thumbnail: SheetThumbnailSource
    private let onReady: @MainActor @Sendable () -> Void

    /// `thumbnail` asks for an item's thumbnail and returns false when it
    /// can't (no record); `renderer` renders what has none.
    init(renderer: SheetRenderer?,
         thumbnail: @escaping SheetThumbnailSource,
         onReady: @escaping @MainActor @Sendable () -> Void) {
        self.renderer = renderer
        self.thumbnail = thumbnail
        self.onReady = onReady
    }

    /// Thumbnails from `library`, for items with a record.
    @MainActor
    static func libraryThumbnails(_ library: Library) -> SheetThumbnailSource {
        { [weak library] item, completion in
            guard let library, let record = item.record else { return false }
            if let cached = library.displayThumbnail(for: record, pixelSize: Self.pixelSize) {
                completion(cached)
                return true
            }
            return library.requestDisplayThumbnail(for: record, pixelSize: Self.pixelSize, completion: completion) != nil
        }
    }

    func image(for item: SheetItem) -> CGImage? {
        lock.withLock { images[item.cacheKey] }
    }

    /// Asks for those of `items` not already here or on their way.
    func request(_ items: [SheetItem]) {
        let wanted = lock.withLock { () -> [SheetItem] in
            var seen = Set<String>()
            let fresh = items.filter { item in
                let key = item.cacheKey
                guard images[key] == nil, !pending.contains(key), !failed.contains(key), seen.insert(key).inserted
                else { return false }
                return true
            }
            fresh.forEach { pending.insert($0.cacheKey) }
            return fresh
        }
        guard !wanted.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                for item in wanted {
                    let asked = thumbnail(item) { [self] image in
                        if let image { finish(item, image) } else { renderFallback(item) }
                    }
                    if !asked { renderFallback(item) }
                }
            }
        }
    }

    private func renderFallback(_ item: SheetItem) {
        guard let renderer else { return finish(item, nil) }
        fallbackQueue.async { [self] in
            let image = renderer.image(for: item, longEdge: Self.pixelSize) { _ in Self.pixelSize }
            finish(item, image)
        }
    }

    private func finish(_ item: SheetItem, _ image: CGImage?) {
        let key = item.cacheKey
        lock.withLock {
            pending.remove(key)
            if let image { images[key] = image } else { failed.insert(key) }
        }
        let ready = onReady
        DispatchQueue.main.async { MainActor.assumeIsolated { ready() } }
    }

    /// For tests and the snapshot harness: nothing is on its way.
    var isIdle: Bool { lock.withLock { pending.isEmpty } }
}

/// Draws pages from items: at print or file quality, rendering what each
/// cell needs, or as a preview from what is at hand.
enum SheetPageDrawer {
    /// Draws `page` with every picture rendered at `pixelsPerUnit` (device
    /// pixels per layout unit), at most `maxLongEdge`. Blocks while
    /// rendering; stops early once `cancel` is set. `prepare` turns each
    /// render into the image drawn (a PDF's JPEG-backed copy); `didDraw`
    /// is told after each cell.
    static func drawPage(_ page: Int, items: [SheetItem], layout: PageLayout, style: PageStyle,
                         pixelsPerUnit: Double, maxLongEdge: Int, renderer: SheetRenderer,
                         preview: SheetPreviewImages? = nil, cancel: SheetCancellation? = nil,
                         prepare: (CGImage) -> CGImage = { $0 }, didDraw: () -> Void = {},
                         in context: CGContext) {
        let pageCount = layout.pageCount(forImageCount: items.count)
        PageRenderer.drawChrome(layout: layout, style: style, page: page, pageCount: pageCount, in: context)
        for cell in layout.cells(onPage: page, imageCount: items.count) {
            if cancel?.isCancelled == true { return }
            let item = items[cell.index]
            let hint = preview?.image(for: item).map { Double($0.width) / Double(max($0.height, 1)) }
            let wanted = layout.renderLongEdge(for: cell.imageArea, aspect: hint, pixelsPerUnit: pixelsPerUnit,
                                               maximum: maxLongEdge)
            var image = renderer.image(for: item, longEdge: wanted) { size in
                layout.renderLongEdge(for: cell.imageArea, aspect: Double(size.width / max(size.height, 1)),
                                      pixelsPerUnit: pixelsPerUnit, maximum: maxLongEdge)
            }
            if let rendered = image { image = prepare(rendered) }
            PageRenderer.drawCell(cell, image: image, caption: item.captionLines(style.caption), layout: layout,
                                  style: style, in: context)
            didDraw()
        }
    }

    /// Draws `page` from the preview pictures there are, a grey box for
    /// each still missing, and asks for the missing ones. Never waits.
    static func drawPreviewPage(_ page: Int, items: [SheetItem], layout: PageLayout, style: PageStyle,
                                preview: SheetPreviewImages, in context: CGContext) {
        let pageCount = layout.pageCount(forImageCount: items.count)
        PageRenderer.drawChrome(layout: layout, style: style, page: page, pageCount: pageCount, in: context)
        let cells = layout.cells(onPage: page, imageCount: items.count)
        for cell in cells {
            let item = items[cell.index]
            PageRenderer.drawCell(cell, image: preview.image(for: item), caption: item.captionLines(style.caption),
                                  layout: layout, style: style, in: context)
        }
        preview.request(cells.map { items[$0.index] })
    }
}

/// Gathering what to print or sheet, on the main actor.
@MainActor
enum SheetItems {
    /// The grid's selection in the order the grid shows it, each with its
    /// stored edit. The editor's pending edit is saved first, so the image
    /// being edited prints as it looks.
    static func selection(library: Library, model: EditorModel) async throws -> [SheetItem] {
        guard let folder = library.folderURL else { return [] }
        model.flushPendingSave()
        await library.waitForPendingWork()
        let selected = library.selectedImageIDs
        var records = library.visibleImages.filter { $0.id.map(selected.contains) ?? false }
        if records.isEmpty { records = library.selectedImages }
        var items: [SheetItem] = []
        for record in records {
            let json = try await library.editStack(for: record)
            items.append(SheetItem(record: record, folder: folder, editStackJSON: json))
        }
        return items
    }

    /// The image open in Loupe or Develop with its edit as it is now, saved
    /// or not, as Export Open Image takes it.
    static func openImage(model: EditorModel, library: Library) throws -> SheetItem? {
        guard model.hasImage, let url = model.sourceURL else { return nil }
        let json = EditStack.isDefault(model.parameters, relativeTo: model.defaultParameters)
            ? nil : try model.stackWithProvenance().encodeJSON()
        if let id = model.catalogImageID, let record = library.images.first(where: { $0.id == id }),
           let folder = library.folderURL, folder.appendingPathComponent(record.relPath).standardizedFileURL == url.standardizedFileURL {
            var item = SheetItem(record: record, folder: folder, editStackJSON: json)
            item.userRotation = model.userRotation
            return item
        }
        return SheetItem(name: url.lastPathComponent, sourceURL: url, editStackJSON: json,
                         userRotation: model.userRotation, captureDate: nil, camera: nil, record: nil)
    }
}
