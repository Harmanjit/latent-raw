import SwiftUI
import AppKit
import ImageIO
import PixelEngine
import Catalog
import MLKit

/// The export sheet's quality comparison: the first image rendered once,
/// as the export will render it, then encoded at two to four JPEG or HEIC
/// qualities side by side at 100%, panned together, each with the size of
/// its whole file. Picking one sets the sheet's quality.
///
/// The render comes from the sheet's `ExportPreviewRenderer`, so it is the
/// same pixels the size estimate encodes. Every encode and decode runs off
/// the main thread; panes show tiles cut on the encoder's block grid
/// (`QualityComparePlan`) rather than whole decoded files.
@MainActor
final class QualityCompareModel: ObservableObject {
    struct Pane: Identifiable, Equatable {
        let id: Int
        var quality: Float
    }

    /// A decoded encode of part of the image.
    struct Tile {
        let rect: CGRect
        let image: CGImage
    }

    enum Phase: Equatable {
        case rendering
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .rendering
    @Published private(set) var panes: [Pane]
    /// The shared view centre, in image pixels, whole pixels.
    @Published private(set) var center: CGPoint = .zero
    /// Whole-file sizes and decoded tiles, by quality in percent.
    @Published private(set) var sizes: [Int: Int] = [:]
    @Published private(set) var tiles: [Int: Tile] = [:]
    @Published private(set) var chosenQuality: Float

    let format: ExportSettings.Format
    let imageName: String
    private(set) var imageWidth = 0
    private(set) var imageHeight = 0

    private let renderer: ExportPreviewRenderer
    private let record: ImageRecord
    private let preset: ExportPreset
    private let onChoose: (Float) -> Void
    private var rendered: ExportWorker.Rendered?
    private var viewPixels: CGSize = .zero
    /// The centre before rounding, so slow drags still move.
    private var exactCenter: CGPoint = .zero
    private var renderTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    /// A whole-file encode's byte count; a fake in tests.
    var encodedSize: @Sendable (ExportWorker.Rendered, ExportSettings) throws -> Int = { try $0.encoded(with: $1).count }
    private var tileTask: Task<Void, Never>?

    init(renderer: ExportPreviewRenderer, record: ImageRecord, preset: ExportPreset,
         onChoose: @escaping (Float) -> Void) {
        self.renderer = renderer
        self.record = record
        self.preset = preset
        self.onChoose = onChoose
        format = preset.format
        imageName = record.fileName
        chosenQuality = preset.quality
        panes = QualityComparePlan.defaultQualities(chosen: preset.quality, count: 3)
            .enumerated().map { Pane(id: $0.offset, quality: $0.element) }
    }

    func uses(_ renderer: ExportPreviewRenderer) -> Bool { self.renderer === renderer }

    static func key(_ quality: Float) -> Int { Int((quality * 100).rounded()) }

    /// A line saying what is compared: format, size, colour space.
    var subtitle: String {
        var parts = [format.displayName]
        if imageWidth > 0 { parts.append("\(imageWidth) × \(imageHeight) px") }
        parts.append(preset.colorSpaceIsP3 ? "Display P3" : "sRGB")
        if preset.settings.watermark != nil { parts.append("watermark") }
        return parts.joined(separator: " · ")
    }

    func start() {
        guard renderTask == nil else { return }
        renderTask = Task {
            do {
                let rendered = try await renderer.rendered(record, preset: preset)
                self.rendered = rendered
                imageWidth = rendered.pixelWidth
                imageHeight = rendered.pixelHeight
                exactCenter = CGPoint(x: imageWidth / 2, y: imageHeight / 2)
                updateCenter()
                phase = .ready
                refreshSizes()
                refreshTiles(after: 0)
            } catch is CancellationError {
                // Stopped by the sheet rather than by closing this window
                // (the render was let go): ask for it again.
                guard !Task.isCancelled else { return }
                renderTask = nil
                start()
            } catch {
                phase = .failed("\(error)")
            }
        }
    }

    func stop() {
        renderTask?.cancel(); sizeTask?.cancel(); tileTask?.cancel()
    }

    func setPaneCount(_ count: Int) {
        let n = min(max(count, QualityComparePlan.paneCounts.lowerBound), QualityComparePlan.paneCounts.upperBound)
        guard n != panes.count else { return }
        if n < panes.count {
            // Keep the chosen quality's pane when there is one.
            var kept = panes
            while kept.count > n {
                let index = kept.lastIndex { Self.key($0.quality) != Self.key(chosenQuality) } ?? kept.count - 1
                kept.remove(at: index)
            }
            panes = kept.enumerated().map { Pane(id: $0.offset, quality: $0.element.quality) }
        } else {
            var qualities = panes.map(\.quality)
            for q in QualityComparePlan.defaultQualities(chosen: chosenQuality, count: 4)
            where qualities.count < n && !qualities.contains(where: { Self.key($0) == Self.key(q) }) {
                qualities.append(q)
            }
            panes = qualities.sorted().enumerated().map { Pane(id: $0.offset, quality: $0.element) }
        }
        refreshSizes()
        refreshTiles(after: 0)
    }

    func setQuality(_ quality: Float, forPane id: Int) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        let q = min(max((quality * 100).rounded() / 100, QualityComparePlan.qualityRange.lowerBound),
                    QualityComparePlan.qualityRange.upperBound)
        guard Self.key(q) != Self.key(panes[index].quality) else { return }
        panes[index].quality = q
        refreshSizes(after: 0.25)
        refreshTiles(after: 0.25)
    }

    func choose(_ quality: Float) {
        chosenQuality = quality
        onChoose(quality)
    }

    /// The panes' size in device pixels (they are all laid out alike).
    func setViewPixels(_ size: CGSize) {
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard rounded != viewPixels, rounded.width > 0, rounded.height > 0 else { return }
        viewPixels = rounded
        updateCenter()
        refreshTilesIfUncovered()
    }

    /// Moves the view by image pixels (a drag right moves the picture right,
    /// so the centre moves left).
    func pan(dx: CGFloat, dy: CGFloat) {
        exactCenter.x += dx
        exactCenter.y += dy
        updateCenter()
        refreshTilesIfUncovered()
    }

    private func updateCenter() {
        guard imageWidth > 0 else { return }
        let clamped = QualityComparePlan.clampedCenter(exactCenter, view: viewPixels,
                                                       imageWidth: imageWidth, imageHeight: imageHeight)
        // Held to the image, so dragging past an edge doesn't bank movement.
        if viewPixels.width < CGFloat(imageWidth) { exactCenter.x = min(max(exactCenter.x, viewPixels.width / 2), CGFloat(imageWidth) - viewPixels.width / 2) }
        if viewPixels.height < CGFloat(imageHeight) { exactCenter.y = min(max(exactCenter.y, viewPixels.height / 2), CGFloat(imageHeight) - viewPixels.height / 2) }
        if clamped != center { center = clamped }
    }

    private func refreshTilesIfUncovered() {
        guard imageWidth > 0, viewPixels.width > 0 else { return }
        let uncovered = panes.contains { pane in
            guard let tile = tiles[Self.key(pane.quality)] else { return true }
            return !QualityComparePlan.covers(tile.rect, center: center, view: viewPixels,
                                              imageWidth: imageWidth, imageHeight: imageHeight)
        }
        if uncovered { refreshTiles(after: 0.06) }
    }

    /// Whole-file encodes for qualities without a size yet, one at a time,
    /// also across calls: an encode can't be stopped once started, so a new
    /// round waits for the one under way before starting its own, rather
    /// than piling whole-image encodes up while a slider moves.
    private func refreshSizes(after delay: Double = 0) {
        guard let rendered else { return }
        let previous = sizeTask
        previous?.cancel()
        guard panes.contains(where: { sizes[Self.key($0.quality)] == nil }) else { return }
        let settings = rendered.settings, format = format, encodedSize = encodedSize
        sizeTask = Task {
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            await previous?.value
            // The panes as they are now; an encode that finished meanwhile
            // still counts.
            for quality in panes.map(\.quality) where sizes[Self.key(quality)] == nil {
                guard !Task.isCancelled else { return }
                var s = settings
                s.format = format; s.quality = quality
                let encodeSettings = s
                let encode = Task.detached(priority: .userInitiated) { try encodedSize(rendered, encodeSettings) }
                // Its size is right whether or not this round was cancelled.
                guard let bytes = try? await encode.value else { return }
                sizes[Self.key(quality)] = bytes
            }
        }
    }


    /// Tiles for the current view at every pane's quality: cut, encoded and
    /// decoded off the main thread. Old tiles stay up until new ones land.
    private func refreshTiles(after delay: Double) {
        guard let rendered, viewPixels.width > 0 else { return }
        tileTask?.cancel()
        let rect = QualityComparePlan.tile(center: center, view: viewPixels, imageWidth: imageWidth, imageHeight: imageHeight)
        let qualities = panes.map(\.quality).filter { tiles[Self.key($0)]?.rect != rect }
        guard !qualities.isEmpty else { return }
        let settings = rendered.settings, format = format
        tileTask = Task {
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            for quality in qualities {
                var s = settings
                s.format = format; s.quality = quality; s.hdrGainMap = false
                let tileSettings = s
                let work = Task.detached(priority: .userInitiated) { () -> Tile? in
                    guard let crop = rendered.image.image.cropping(to: rect),
                          let data = try? Exporter.encode(Exporter.EncodableImage(image: crop), settings: tileSettings),
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let decoded = CGImageSourceCreateImageAtIndex(
                            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    else { return nil }
                    return Tile(rect: rect, image: decoded)
                }
                let tile = await work.value
                guard !Task.isCancelled else { return }
                if let tile { tiles[Self.key(quality)] = tile }
            }
        }
    }
}

// `Tile` crosses from the detached encode back to the main actor; a
// decoded CGImage is immutable.
extension QualityCompareModel.Tile: @unchecked Sendable {}

struct QualityCompareView: View {
    @ObservedObject var model: QualityCompareModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.imageName).font(.headline)
                    Text(model.subtitle + " · 100% · drag to pan").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Panes", selection: Binding(get: { model.panes.count }, set: { model.setPaneCount($0) })) {
                    ForEach(Array(QualityComparePlan.paneCounts), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .accessibilityLabel("Number of qualities to compare")
            }
            .padding(10)
            Divider()
            switch model.phase {
            case .rendering:
                ProgressView("Rendering \(model.imageName) as the export will…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason):
                Label("Couldn't render the image: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                HStack(spacing: 1) {
                    ForEach(model.panes) { pane in
                        QualityPaneView(model: model, pane: pane, displayScale: displayScale)
                    }
                }
                .background(Color(nsColor: .separatorColor))
            }
            Divider()
            Text("Sizes are whole files at these settings. Each pane is encoded for real; "
                 + (model.format == .heic ? "HEIC pane edges can differ slightly from the file's." : "JPEG panes match the file exactly."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

private struct QualityPaneView: View {
    @ObservedObject var model: QualityCompareModel
    let pane: QualityCompareModel.Pane
    let displayScale: CGFloat
    @State private var lastTranslation: CGSize = .zero

    private var percent: Int { QualityCompareModel.key(pane.quality) }
    private var bytes: Int? { model.sizes[percent] }
    private var isChosen: Bool { QualityCompareModel.key(model.chosenQuality) == percent }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quality").accessibilityHidden(true)
                    Slider(value: Binding(get: { Double(pane.quality) },
                                          set: { model.setQuality(Float($0), forPane: pane.id) }),
                           in: Double(QualityComparePlan.qualityRange.lowerBound)...Double(QualityComparePlan.qualityRange.upperBound))
                        .accessibilityLabel("Quality, pane \(pane.id + 1)")
                        .accessibilityValue("\(percent)")
                    Text("\(percent)").monospacedDigit().frame(width: 30, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                HStack {
                    Text(bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Encoding…")
                        .monospacedDigit()
                        .foregroundStyle(bytes == nil ? .secondary : .primary)
                        .accessibilityLabel(bytes.map { "File size " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                                            ?? "Working out the file size")
                    Spacer()
                    Button(isChosen ? "Chosen" : "Use \(percent)") { model.choose(pane.quality) }
                        .controlSize(.small)
                        .disabled(isChosen)
                        .accessibilityLabel(isChosen ? "Quality \(percent) is the export's quality" : "Use quality \(percent) for the export")
                }
            }
            .padding(8)
            .background(.bar)
            GeometryReader { geometry in
                let tile = model.tiles[percent], center = model.center, displayScale = displayScale
                Canvas { context, size in
                    guard let tile else { return }
                    let s = displayScale
                    // Whole device pixels, so the tile lands 1:1 on the screen.
                    let halfWidth = (size.width * s / 2).rounded(.down), halfHeight = (size.height * s / 2).rounded(.down)
                    let x = (tile.rect.minX - center.x + halfWidth) / s
                    let y = (tile.rect.minY - center.y + halfHeight) / s
                    context.draw(Image(decorative: tile.image, scale: s).interpolation(.none),
                                 in: CGRect(x: x, y: y, width: tile.rect.width / s, height: tile.rect.height / s))
                }
                .overlay {
                    if tile == nil { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let dx = value.translation.width - lastTranslation.width
                        let dy = value.translation.height - lastTranslation.height
                        lastTranslation = value.translation
                        model.pan(dx: -dx * displayScale, dy: -dy * displayScale)
                    }
                    .onEnded { _ in lastTranslation = .zero })
                .onChange(of: geometry.size, initial: true) { _, size in
                    model.setViewPixels(CGSize(width: size.width * displayScale, height: size.height * displayScale))
                }
            }
            .clipped()
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel("\(model.imageName) at quality \(percent), 100 percent")
            .accessibilityAction(named: "Pan left") { model.pan(dx: -200, dy: 0) }
            .accessibilityAction(named: "Pan right") { model.pan(dx: 200, dy: 0) }
            .accessibilityAction(named: "Pan up") { model.pan(dx: 0, dy: -200) }
            .accessibilityAction(named: "Pan down") { model.pan(dx: 0, dy: 200) }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The one comparison window, opened from the export sheet and closed
/// with it.
@MainActor
enum QualityCompareWindow {
    private static var window: NSWindow?
    private static var model: QualityCompareModel?
    private static var closeObserver: NSObjectProtocol?

    static var isOpen: Bool { window?.isVisible == true }
    static var currentModel: QualityCompareModel? { model }

    static func show(renderer: ExportPreviewRenderer, record: ImageRecord, preset: ExportPreset,
                     onChoose: @escaping (Float) -> Void) {
        model?.stop()
        let model = QualityCompareModel(renderer: renderer, record: record, preset: preset, onChoose: onChoose)
        self.model = model
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = "Compare Export Quality"
        window.subtitle = record.fileName
        window.contentView = NSHostingView(rootView: QualityCompareView(model: model).motionFollowsAccessibility())
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    /// Closes the window when it shows `renderer`'s image: the sheet that
    /// owns the render is going away.
    static func close(ifUsing renderer: ExportPreviewRenderer) {
        if model?.uses(renderer) == true { close() }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("QualityCompare")
        window.center()
        window.setFrameAutosaveName("QualityCompare")
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                // Let the tiles and the model go; the sheet keeps its render.
                QualityCompareWindow.model?.stop()
                QualityCompareWindow.model = nil
                QualityCompareWindow.window?.contentView = nil
            }
        }
        return window
    }
}
