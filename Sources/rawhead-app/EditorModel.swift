import Foundation
import Metal
import SwiftUI
import UniformTypeIdentifiers
import RawCore
import ColorKit
import PixelEngine

/// The editor's state: which image is open, what the adjustments are, how
/// the viewport is zoomed and panned, and the most recent rendered result.
///
/// @MainActor because it drives the UI and owns the Metal texture the view
/// draws. Viewport rendering runs synchronously on the main thread, which is
/// defensible only because it measures around 3–11ms — inside a frame.
/// Export is far too slow for that and runs on `ExportService`, an actor
/// that owns its own session so nothing mutable is shared across the
/// boundary.
///
/// Zoom and pan are handled in two layers, because they have very
/// different costs:
///
/// 1. **Presenting** is instant. Every gesture event updates `viewport`,
///    and the Metal view immediately redraws whatever texture it has at the
///    new transform. Pinching never waits on the pipeline.
/// 2. **Rendering** is debounced. After gestures stop for ~80ms, the model
///    picks the cheapest path that gives full detail for the current zoom
///    — the whole image binned when zoomed out, a full-resolution tile of
///    just the visible area near 100% (DESIGN.md §8.2) — and renders it.
///
/// `init` deliberately doesn't throw: SwiftUI's @StateObject takes a
/// non-throwing autoclosure, so a throwing initializer can't be used there
/// without a force-try that would crash on exactly the failure it claims to
/// handle. Setup failure is held in `setupError` and surfaced in the UI.
@MainActor
final class EditorModel: ObservableObject {
    @Published var parameters = EditParameters() {
        didSet { if parameters != oldValue { rerender() } }
    }
    @Published private(set) var texture: MTLTexture?
    /// The sensor rectangle `texture` covers.
    @Published private(set) var coverage: CGRect = .zero
    @Published private(set) var viewport = ViewportTransform(zoom: 1, center: .zero)
    @Published private(set) var histogram: Histogram?
    @Published private(set) var status = "Open a raw file to begin"
    @Published private(set) var imageTitle: String?
    @Published private(set) var lastRenderMs: Double = 0

    /// Export settings persist across exports within a session, so a second
    /// export doesn't mean re-choosing format and quality.
    @Published var exportSettings = ExportSettings()
    @Published private(set) var isExporting = false

    /// The camera's own white balance, for the "As Shot" button and for
    /// showing the user where the camera set things.
    @Published private(set) var asShotWhiteBalance = ColorKit.WhiteBalance()

    /// Non-nil when Metal setup failed, in which case nothing else works.
    let setupError: String?

    private let gpuContext: GPUContext?
    private let pipeline: RenderPipeline?
    private let presenterInstance: Presenter?
    private let histogramCalculator: HistogramCalculator?
    private let exportService: ExportService?
    private var session: ImageSession?
    private var sourceURL: URL?

    /// The viewport's size in device pixels, reported by the Metal view.
    /// Zero until the view first appears.
    private var drawableSize: CGSize = .zero

    /// True until the user zooms. While set, window resizes keep the image
    /// fitted rather than preserving an arbitrary zoom.
    private var fitMode = true

    private var pendingRender: Task<Void, Never>?

    /// Which pooled-texture footprint the last render used. When it
    /// changes — a different bin factor, or a differently sized tile — the
    /// old textures are released rather than left lying around.
    private enum PlanKey: Equatable {
        case binned(Int)
        case tile(Int, Int)
    }
    private var lastPlanKey: PlanKey?

    init() {
        do {
            let gpu = try GPUContext()
            self.gpuContext = gpu
            self.pipeline = RenderPipeline(gpu: gpu)
            self.presenterInstance = Presenter(gpu: gpu)
            self.histogramCalculator = try? HistogramCalculator(gpu: gpu)
            self.exportService = ExportService(gpu: gpu)
            self.setupError = nil
        } catch {
            self.gpuContext = nil
            self.pipeline = nil
            self.presenterInstance = nil
            self.histogramCalculator = nil
            self.exportService = nil
            self.setupError = String(describing: error)
            self.status = "Metal setup failed"
        }
    }

    var isReady: Bool { gpuContext != nil }
    var device: MTLDevice? { gpuContext?.device }
    var presenter: Presenter? { presenterInstance }
    var hasImage: Bool { session != nil }

    /// Full sensor dimensions of the open image.
    private var sensorSize: CGSize {
        guard let session else { return .zero }
        return CGSize(width: session.file.summary.rawWidth,
                      height: session.file.summary.rawHeight)
    }

    /// What the status bar shows: "Fit" or a percentage where 100% means
    /// one sensor pixel per screen pixel.
    var zoomLabel: String {
        guard hasImage else { return "" }
        if fitMode { return "Fit" }
        return String(format: "%.0f%%", viewport.zoom * 100)
    }

    /// The temperature slider works in negated mired rather than Kelvin, so
    /// its travel is perceptually even — see ColorKit for the reasoning.
    var temperatureSliderBinding: Binding<Float> {
        Binding(
            get: { ColorKit.sliderValue(forTemperature: self.parameters.whiteBalance.temperature) },
            set: { self.parameters.whiteBalance.temperature = ColorKit.temperature(forSliderValue: $0) }
        )
    }

    /// The slider's range, centred on this image's as-shot temperature so
    /// the starting point is always mid-travel and both directions shift by
    /// equal amounts.
    var temperatureSliderRange: ClosedRange<Float> {
        ColorKit.temperatureSliderRange(asShotTemperature: asShotWhiteBalance.temperature)
    }

    // MARK: - Opening

    func showOpenPanel() {
        guard isReady else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a raw file"
        // Raw formats mostly lack registered UTTypes, so filter loosely and
        // let RawFile reject anything LibRaw can't read.
        panel.allowedContentTypes = [UTType.image]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        guard let gpu = gpuContext else { return }
        status = "Opening \(url.lastPathComponent)…"
        do {
            let file = try RawFile(path: url.path)
            let newSession = try ImageSession(file: file, gpu: gpu)
            session = newSession
            sourceURL = url
            imageTitle = url.lastPathComponent
            asShotWhiteBalance = newSession.asShotWhiteBalance
            lastPlanKey = nil

            // A new image always opens fitted.
            fitMode = true
            viewport = .fit(imageSize: sensorSize, drawableSize: drawableSize)

            // Start from the camera's own white balance, expressed as
            // temperature and tint so the sliders show something meaningful
            // rather than a default the photo was never shot under.
            var fresh = EditParameters()
            fresh.whiteBalance = newSession.asShotWhiteBalance
            parameters = fresh   // triggers rerender via didSet

            if newSession.profile == nil {
                status = "No colour profile for \(file.summary.cameraModel) — cannot render"
            } else {
                status = "\(file.summary.cameraMake) \(file.summary.cameraModel) · " +
                         "\(file.summary.rawWidth)×\(file.summary.rawHeight)"
            }
            rerender()
        } catch {
            session = nil
            sourceURL = nil
            texture = nil
            histogram = nil
            imageTitle = nil
            status = "Could not open: \(error)"
        }
    }

    // MARK: - Viewport

    /// The Metal view's drawable size changed (window resize, or the view
    /// appearing for the first time).
    func viewportDidResize(to size: CGSize) {
        guard size != drawableSize else { return }
        drawableSize = size
        guard hasImage else { return }
        if fitMode {
            viewport = .fit(imageSize: sensorSize, drawableSize: size)
        } else {
            viewport = viewport.clamped(imageSize: sensorSize, drawableSize: size)
        }
        scheduleRender()
    }

    func zoom(by factor: CGFloat, about screenPoint: CGPoint) {
        guard hasImage else { return }
        apply(viewport.zoomed(by: factor, about: screenPoint, drawableSize: drawableSize))
    }

    func pan(by delta: CGSize) {
        guard hasImage, !fitMode else { return }   // nothing to pan when fitted
        apply(viewport.panned(byScreenDelta: delta))
    }

    /// Double-click toggles between fit and 100%, zooming in on the
    /// clicked point so what you clicked is what you end up looking at.
    func toggleZoom(at screenPoint: CGPoint) {
        guard hasImage else { return }
        if fitMode {
            let factor = 1 / viewport.zoom
            apply(viewport.zoomed(by: factor, about: screenPoint, drawableSize: drawableSize))
        } else {
            zoomToFit()
        }
    }

    func zoomToFit() {
        guard hasImage else { return }
        fitMode = true
        viewport = .fit(imageSize: sensorSize, drawableSize: drawableSize)
        rerender()
    }

    func zoomToActualSize() {
        guard hasImage else { return }
        let centre = CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2)
        apply(viewport.zoomed(by: 1 / viewport.zoom, about: centre, drawableSize: drawableSize))
        rerender()
    }

    func zoomIn()  { zoomStep(2) }
    func zoomOut() { zoomStep(0.5) }

    private func zoomStep(_ factor: CGFloat) {
        guard hasImage else { return }
        let centre = CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2)
        apply(viewport.zoomed(by: factor, about: centre, drawableSize: drawableSize))
        rerender()
    }

    /// Every gesture lands here: clamp, publish (the view redraws at once),
    /// and queue a render for when the gesture settles.
    private func apply(_ proposed: ViewportTransform) {
        let clamped = proposed.clamped(imageSize: sensorSize, drawableSize: drawableSize)
        fitMode = clamped.isFit(imageSize: sensorSize, drawableSize: drawableSize)
        guard clamped != viewport else { return }
        viewport = clamped
        scheduleRender()
    }

    /// Coalesces a burst of gesture events into one render, shortly after
    /// the last of them. 80ms is long enough that a continuous pinch never
    /// renders mid-gesture, short enough that the sharpened result appears
    /// before the eye has settled.
    private func scheduleRender() {
        pendingRender?.cancel()
        pendingRender = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.rerender()
        }
    }

    // MARK: - Rendering

    /// Picks the render path for the current zoom.
    ///
    /// The dividing line is how many sensor pixels each screen pixel
    /// covers. At 1.5 or more, binning whole quads is both cheaper and
    /// *more* correct than demosaicing (it's a box filter, which is what a
    /// downscale should be). Below that, a full-resolution tile of the
    /// visible area is needed, with a margin so small pans don't reveal an
    /// unrendered edge before the next render lands.
    private func plan() -> (scale: RenderScale, key: PlanKey) {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return (.binned(quads: 1), .binned(1))   // view not up yet
        }
        let sensorPerScreen = 1 / viewport.zoom
        if sensorPerScreen >= 1.5 {
            let quads = max(1, Int(sensorPerScreen / 2))
            return (.binned(quads: quads), .binned(quads))
        }

        let margin: CGFloat = 32
        let visible = viewport.visibleSensorRect(drawableSize: drawableSize)
            .insetBy(dx: -margin, dy: -margin)
        // Size is a function of zoom alone, so it stays constant while
        // panning and the texture pool keeps reusing the same buffers.
        let width = min(Int(visible.width.rounded(.up)), Int(sensorSize.width))
        let height = min(Int(visible.height.rounded(.up)), Int(sensorSize.height))
        return (.region(x: Int(visible.origin.x.rounded(.down)),
                        y: Int(visible.origin.y.rounded(.down)),
                        width: width, height: height),
                .tile(width, height))
    }

    func rerender() {
        guard let session, let pipeline else { return }
        pendingRender?.cancel()

        let (scale, key) = plan()
        if key != lastPlanKey {
            // A tile at full resolution holds hundreds of megabytes of
            // intermediates; don't keep last zoom level's around too.
            session.releasePooledTextures()
            lastPlanKey = key
        }

        let start = Date()
        do {
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1,
                                  isFullResolution: false)
            let rendered = try pipeline.render(session, scale: scale,
                                                parameters: parameters, info: &info)
            texture = rendered
            coverage = info.sensorRect
            lastRenderMs = Date().timeIntervalSince(start) * 1000

            // The histogram describes the whole image, not just the tile
            // on screen. When zoomed in, measure a small binned render
            // instead — about 1ms, and always whole-image.
            if info.isFullResolution {
                let overview = try pipeline.render(session, scale: .binned(quads: 4),
                                                    parameters: parameters)
                histogram = histogramCalculator?.compute(from: overview)
            } else {
                histogram = histogramCalculator?.compute(from: rendered)
            }
        } catch {
            status = "Render failed: \(error)"
        }
    }

    // MARK: - Export

    func showExportPanel() {
        guard hasImage, let sourceURL else { return }

        let panel = NSSavePanel()
        panel.message = "Export image"
        panel.allowedContentTypes = [exportSettings.format.contentType]
        panel.nameFieldStringValue = sourceURL
            .deletingPathExtension().lastPathComponent
            + "." + exportSettings.format.fileExtension

        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    /// Hands the work to `ExportService`, which opens its own copy of the
    /// file so the viewport's session is untouched.
    ///
    /// Only plain values cross the actor boundary — two URLs, the edit
    /// parameters and the export settings, all Sendable. Nothing mutable is
    /// shared, which is what makes this safe rather than merely quiet.
    func export(to destination: URL) {
        guard let exportService, let sourceURL else { return }
        let settings = exportSettings
        let params = parameters

        isExporting = true
        status = "Exporting at full resolution…"

        Task {
            do {
                let elapsed = try await exportService.export(from: sourceURL,
                                                              to: destination,
                                                              parameters: params,
                                                              settings: settings)
                isExporting = false
                status = String(format: "Exported %@ in %.1fs",
                                 destination.lastPathComponent, elapsed)
            } catch {
                isExporting = false
                status = "Export failed: \(error)"
            }
        }
    }

    func resetWhiteBalance() {
        parameters.whiteBalance = asShotWhiteBalance
    }

    func resetAdjustments() {
        var fresh = EditParameters()
        fresh.whiteBalance = asShotWhiteBalance
        parameters = fresh
    }
}
