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
        didSet {
            if parameters != oldValue {
                rerender()
                scheduleSave()
            }
        }
    }

    /// The catalog id of the open image, when it came from a catalog.
    /// Captured into each pending save, so a save that fires after the
    /// user has moved on still lands on the right image.
    private(set) var catalogImageID: Int64?
    /// The fresh parameters for this image (as-shot white balance and so
    /// on). A stack equal to these is "no edit" and isn't stored.
    private var defaultParameters = EditParameters()
    private var pendingSave: Task<Void, Never>?

    /// Called with the edit to persist, or nil when the image is back to
    /// defaults. The library owns the actual write. Set by ContentView.
    var onEditSettled: ((_ imageID: Int64, _ editStackJSON: String?) -> Void)?

    /// Persists ~1s after the last change (DESIGN.md §5.3: nothing is
    /// written while a slider is being dragged).
    private func scheduleSave() {
        guard catalogImageID != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    /// Saves now if anything is pending. Called before switching images
    /// so an edit made a moment before pressing → isn't lost.
    func flushPendingSave() {
        guard let id = catalogImageID, let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        if EditStack.isDefault(parameters, relativeTo: defaultParameters) {
            onEditSettled?(id, nil)
        } else {
            var stack = EditStack(parameters: parameters)
            if let lens = session?.lensCorrection {
                stack.setLensProvenance(profile: lens.profileName, databaseVersion: lens.databaseVersion)
            }
            onEditSettled?(id, try? stack.encodeJSON())
        }
    }
    /// The whole image at preview resolution. Always drawn, so the view is
    /// never empty however far the user pans or zooms mid-gesture.
    @Published private(set) var preview: PresentLayer?
    /// A full-resolution render of (a margin around) the visible area,
    /// drawn on top of the preview when zoomed in close enough to need it.
    @Published private(set) var tile: PresentLayer?
    @Published private(set) var viewport = ViewportTransform(zoom: 1, center: .zero)
    @Published private(set) var histogram: Histogram?
    @Published private(set) var waveform: Waveform?
    @Published private(set) var vectorscope: Vectorscope?
    /// Only the visible scope is computed (efficiency rule 2). Switching
    /// re-measures the current analysis texture without re-rendering.
    @Published var scope: ScopeKind = .histogram {
        didSet { if scope != oldValue { updateScopes() } }
    }
    @Published private(set) var status = "Open a raw file to begin"
    @Published private(set) var imageTitle: String?
    @Published private(set) var lastRenderMs: Double = 0
    /// What the last action rendered, for the status bar: "preview 3016×2016
    /// · 3.1 ms", "tile · demosaic cached · 1.2 ms", or "pan · no render".
    @Published private(set) var renderReport = ""

    /// Export settings persist across exports within a session, so a second
    /// export doesn't mean re-choosing format and quality.
    @Published var exportSettings = ExportSettings()
    @Published private(set) var isExporting = false

    /// The camera's own white balance, for the "As Shot" button and for
    /// showing the user where the camera set things.
    @Published private(set) var asShotWhiteBalance = ColorKit.WhiteBalance()

    /// Show highlights above paper white using the display's EDR range.
    /// Off means the on-screen image matches what an SDR export will look
    /// like, which is useful for judging a file before exporting it.
    @Published var hdrDisplayEnabled = true {
        didSet { if hdrDisplayEnabled != oldValue { rerender() } }
    }
    /// What the screen reports it can show above 1.0. Exactly 1.0 on an
    /// SDR display, in which case the toggle has nothing to do.
    @Published private(set) var displayHeadroom: CGFloat = 1

    /// The ceiling the tone curve actually gets. Capped: a display that
    /// reports 16x headroom would otherwise render every clipped cloud as
    /// a searchlight. 4x is already very bright.
    private static let maximumHeadroom: CGFloat = 4
    var effectiveHeadroom: Float {
        hdrDisplayEnabled ? Float(min(displayHeadroom, Self.maximumHeadroom)) : 1
    }
    var displayHasHeadroom: Bool { displayHeadroom > 1.001 }

    /// What the pipeline renders for the screen: linear Display P3, so
    /// the presenter can hand it to the EDR layer untouched.
    private var displayOutput: RenderOutput { .edrDisplay(headroom: effectiveHeadroom) }

    /// The surround grey, in the drawable's linear encoding. 0.12 in sRGB
    /// terms — Lightroom's mid-dark grey — is about 0.0137 linear.
    let backgroundLevel: Float = 0.0137

    /// Non-nil when Metal setup failed, in which case nothing else works.
    let setupError: String?

    private let gpuContext: GPUContext?
    private let pipeline: RenderPipeline?
    private let presenterInstance: Presenter?
    private let histogramCalculator: HistogramCalculator?
    private let scopeCalculator: ScopeCalculator?
    /// The small render the scopes measure. Kept so switching scope
    /// doesn't need a render; replaced on every preview render.
    private var analysisTexture: MTLTexture?
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

    /// What the last renders used, so a viewport change can decide whether
    /// anything actually needs re-rendering.
    private var previewQuads = 0
    private var tileSize = CGSize.zero

    /// Extra sensor pixels rendered beyond each edge of the visible area,
    /// so small pans stay inside the tile and need no render at all. Costs
    /// about 25% more pixels per tile on a laptop-sized window.
    private static let tileMargin: CGFloat = 128
    /// Pixels trimmed from the tile's edge when drawing — the demosaic's
    /// neighbourhood reach, where clamped reads produce colour fringes.
    private static let tileInset: CGFloat = 8

    init() {
        do {
            let gpu = try GPUContext()
            self.gpuContext = gpu
            self.pipeline = RenderPipeline(gpu: gpu)
            self.presenterInstance = Presenter(gpu: gpu)
            self.histogramCalculator = try? HistogramCalculator(gpu: gpu)
            self.scopeCalculator = try? ScopeCalculator(gpu: gpu)
            self.exportService = ExportService(gpu: gpu)
            self.setupError = nil
        } catch {
            self.gpuContext = nil
            self.pipeline = nil
            self.presenterInstance = nil
            self.histogramCalculator = nil
            self.scopeCalculator = nil
            self.exportService = nil
            self.setupError = String(describing: error)
            self.status = "Metal setup failed"
        }
    }

    var isReady: Bool { gpuContext != nil }
    var gpu: GPUContext? { gpuContext }

    /// What the lens panel says about the open image.
    var lensProfileDescription: String {
        guard hasImage else { return "" }
        guard let c = session?.lensCorrection else {
            let lens = session?.file.summary.lens
            let spec = lens.map { l -> String in
                l.minFocal > 0 ? String(format: "%.0f-%.0fmm f/%.1f", l.minFocal, l.maxFocal,
                                        l.maxApertureAtMinFocal) : "unknown lens"
            } ?? "unknown lens"
            return "No profile found (\(spec)). Manual sliders still work."
        }
        var parts: [String] = []
        if c.distortion != nil { parts.append("distortion") }
        if c.tca != nil { parts.append("CA") }
        if c.vignetting != nil { parts.append("vignetting") }
        return "\(c.profileName) · \(parts.joined(separator: ", ")) · lensfun \(c.databaseVersion)"
    }
    var hasLensProfile: Bool { session?.lensCorrection != nil }
    var device: MTLDevice? { gpuContext?.device }
    var presenter: Presenter? { presenterInstance }
    var hasImage: Bool { session != nil }

    /// Full sensor dimensions of the open image, as recorded.
    var sensorSize: CGSize {
        guard let session else { return .zero }
        return CGSize(width: session.file.summary.rawWidth,
                      height: session.file.summary.rawHeight)
    }

    /// What the camera says the orientation was.
    private var cameraRotation: ImageRotation = .none
    /// Quarter turns the user added on top (kept in the catalog).
    @Published private(set) var userRotation = 0
    /// What's actually shown: camera orientation plus the user's turns.
    var rotation: ImageRotation { cameraRotation.rotated(by: userRotation) }

    /// The image as the user sees it — rotated. Zoom, pan and fit all
    /// work in this space; the pipeline never sees it.
    private var imageSize: CGSize { rotation.imageSize(forSensorSize: sensorSize) }

    /// Called by the library when the user rotates, and when opening an
    /// image that already has a stored rotation. Re-fits if fitted, else
    /// keeps the same image-space centre; the tile is re-requested since
    /// the visible sensor region changed.
    func setUserRotation(_ quarterTurns: Int) {
        let normalized = ((quarterTurns % 4) + 4) % 4
        guard normalized != userRotation else { return }
        userRotation = normalized
        guard hasImage else { return }
        if fitMode {
            viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)
        } else {
            viewport = viewport.clamped(imageSize: imageSize, drawableSize: drawableSize)
        }
        rerenderForViewport()
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

    /// `userRotation` and `editStackJSON` are the catalog's stored state
    /// for this image, if it came from one; `catalogImageID` lets edits
    /// made here be saved back.
    func open(url: URL, userRotation: Int = 0, catalogImageID: Int64? = nil,
              editStackJSON: String? = nil) {
        guard let gpu = gpuContext else { return }
        flushPendingSave()
        self.catalogImageID = catalogImageID
        status = "Opening \(url.lastPathComponent)…"
        do {
            let file = try RawFile(path: url.path)
            let newSession = try ImageSession(file: file, gpu: gpu)
            session = newSession
            sourceURL = url
            imageTitle = url.lastPathComponent
            asShotWhiteBalance = newSession.asShotWhiteBalance
            preview = nil
            tile = nil
            previewQuads = 0
            tileSize = .zero
            cameraRotation = ImageRotation(libRawFlip: file.summary.orientation)
            self.userRotation = ((userRotation % 4) + 4) % 4

            // A new image always opens fitted.
            fitMode = true
            viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)

            // Start from the camera's own white balance, expressed as
            // temperature and tint so the sliders show something meaningful
            // rather than a default the photo was never shot under. Then
            // lay the stored edit, if any, over that.
            var fresh = EditParameters()
            fresh.whiteBalance = newSession.asShotWhiteBalance
            defaultParameters = fresh
            var restored = fresh
            if let editStackJSON, let stack = try? EditStack.decode(json: editStackJSON) {
                restored = stack.parameters(defaults: fresh)
                if restored.whiteBalance.isAsShot { restored.whiteBalance = fresh.whiteBalance }
            }
            pendingSave?.cancel()   // the assignment below must not save
            pendingSave = nil
            parameters = restored   // triggers rerender via didSet
            pendingSave?.cancel()
            pendingSave = nil

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
            preview = nil
            tile = nil
            histogram = nil
            imageTitle = nil
            status = "Could not open: \(error)"
        }
    }

    // MARK: - Viewport

    /// The Metal view's drawable size changed (window resize, or the view
    /// appearing for the first time).
    func displayHeadroomDidChange(to headroom: CGFloat) {
        guard headroom != displayHeadroom else { return }
        displayHeadroom = headroom
        if hasImage { rerender() }
    }

    func viewportDidResize(to size: CGSize) {
        guard size != drawableSize else { return }
        drawableSize = size
        guard hasImage else { return }
        if fitMode {
            viewport = .fit(imageSize: imageSize, drawableSize: size)
        } else {
            viewport = viewport.clamped(imageSize: imageSize, drawableSize: size)
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
        viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)
        rerenderForViewport()
    }

    func zoomToActualSize() {
        guard hasImage else { return }
        let centre = CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2)
        apply(viewport.zoomed(by: 1 / viewport.zoom, about: centre, drawableSize: drawableSize))
        rerenderForViewport()
    }

    func zoomIn()  { zoomStep(2) }
    func zoomOut() { zoomStep(0.5) }

    private func zoomStep(_ factor: CGFloat) {
        guard hasImage else { return }
        let centre = CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2)
        apply(viewport.zoomed(by: factor, about: centre, drawableSize: drawableSize))
        rerenderForViewport()
    }

    /// Every gesture lands here: clamp, publish (the view redraws at once),
    /// and queue a render for when the gesture settles.
    private func apply(_ proposed: ViewportTransform) {
        let clamped = proposed.clamped(imageSize: imageSize, drawableSize: drawableSize)
        fitMode = clamped.isFit(imageSize: imageSize, drawableSize: drawableSize)
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
            self?.rerenderForViewport()
        }
    }

    // MARK: - Rendering

    /// How many quads to bin for the preview at the current zoom. Zoomed
    /// out, the preview is the only layer and should match the screen;
    /// zoomed in, it's the soft backdrop under the tile, and half-size is
    /// plenty.
    private var wantedPreviewQuads: Int {
        guard drawableSize.width > 0 else { return 1 }
        return max(1, Int((1 / viewport.zoom) / 2))
    }

    /// Whether the current zoom needs a full-resolution tile at all. At 1.5
    /// sensor pixels per screen pixel or more, binning whole quads is both
    /// cheaper and *more* correct than demosaicing — it's a box filter,
    /// which is what a downscale should be.
    private var wantsTile: Bool {
        drawableSize.width > 0 && (1 / viewport.zoom) < 1.5
    }

    /// The tile region for the current view: the visible area plus margin,
    /// sized by zoom alone so panning keeps reusing the same textures.
    /// The visible area in *sensor* space: the viewport's visible rect is
    /// in rotated image space, so it's mapped back before asking for a tile.
    private var visibleSensorRect: CGRect {
        let visibleImage = viewport.visibleSensorRect(drawableSize: drawableSize)
        return rotation.sensorRect(fromImageRect: visibleImage, sensorSize: sensorSize)
    }

    private func wantedTileRegion() -> (x: Int, y: Int, width: Int, height: Int) {
        let visible = visibleSensorRect.insetBy(dx: -Self.tileMargin, dy: -Self.tileMargin)
        let width = min(Int(visible.width.rounded(.up)), Int(sensorSize.width))
        let height = min(Int(visible.height.rounded(.up)), Int(sensorSize.height))
        return (Int(visible.origin.x.rounded(.down)), Int(visible.origin.y.rounded(.down)),
                width, height)
    }

    /// Does the tile on hand still cover what's on screen? If so, a pan
    /// needs no render — the presenter just draws it in the new place.
    private var tileCoversView: Bool {
        guard let tile, tile.texture.width == Int(tileSize.width),
              tile.texture.height == Int(tileSize.height) else { return false }
        let visible = visibleSensorRect
        let usable = tile.coverage.insetBy(dx: Self.tileInset, dy: Self.tileInset)
        // Only the part of the view that's actually over the image matters.
        let sensorBounds = CGRect(origin: .zero, size: sensorSize)
        return usable.contains(visible.intersection(sensorBounds))
    }

    /// Re-renders after a zoom or pan. Cheap when nothing changed: the
    /// preview only re-renders if its bin factor changed, and the tile
    /// only if the view has moved outside it or the zoom changed.
    private func rerenderForViewport() {
        guard let session, let pipeline else { return }
        let start = Date()
        var didWork = false
        var what: [String] = []
        do {
            if previewQuads != wantedPreviewQuads {
                what.append(try renderPreview(session: session, pipeline: pipeline))
                didWork = true
            }
            if wantsTile {
                let region = wantedTileRegion()
                let wantedSize = CGSize(width: region.width, height: region.height)
                if wantedSize != tileSize {
                    // Different zoom: the old tile's textures are the wrong
                    // size and hold hundreds of megabytes. Let them go.
                    session.releasePooledTextures()
                    tileSize = wantedSize
                    tile = nil
                }
                if !tileCoversView {
                    what.append(try renderTile(session: session, pipeline: pipeline, region: region))
                    didWork = true
                }
            } else if tile != nil {
                tile = nil
                session.releasePooledTextures()
                tileSize = .zero
            }
        } catch {
            status = "Render failed: \(error)"
        }
        if didWork {
            lastRenderMs = Date().timeIntervalSince(start) * 1000
            renderReport = what.joined(separator: " + ") + String(format: " · %.1f ms", lastRenderMs)
        } else {
            renderReport = "view moved · no render"
        }
    }

    /// Re-renders after an edit. Both layers show the edit, so both go.
    func rerender() {
        guard let session, let pipeline else { return }
        pendingRender?.cancel()
        let start = Date()
        var what: [String] = []
        do {
            what.append(try renderPreview(session: session, pipeline: pipeline))
            if wantsTile {
                let region = wantedTileRegion()
                let wantedSize = CGSize(width: region.width, height: region.height)
                if wantedSize != tileSize {
                    session.releasePooledTextures()
                    tileSize = wantedSize
                }
                what.append(try renderTile(session: session, pipeline: pipeline, region: region))
            } else {
                tile = nil
            }
        } catch {
            status = "Render failed: \(error)"
        }
        lastRenderMs = Date().timeIntervalSince(start) * 1000
        renderReport = what.joined(separator: " + ") + String(format: " · %.1f ms", lastRenderMs)
    }

    /// Returns a short description of what ran, for the status bar.
    @discardableResult
    private func renderPreview(session: ImageSession, pipeline: RenderPipeline) throws -> String {
        let quads = wantedPreviewQuads
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
        let rendered = try pipeline.render(session, scale: .binned(quads: quads),
                                            parameters: parameters, output: displayOutput,
                                            info: &info)
        preview = PresentLayer(texture: rendered, coverage: info.sensorRect)
        previewQuads = quads

        // Scopes always describe the whole image, whatever's on screen —
        // so they come from a small whole-image render, never from a
        // tile. A few hundred thousand pixels is plenty for statistics,
        // and with the demosaic cached this costs well under a millisecond.
        // Bigger quads than the preview only when the preview is itself
        // large; a tiny preview is already an analysis-sized image.
        let analysisQuads = max(quads, 4)
        analysisTexture = try pipeline.render(session, scale: .binned(quads: analysisQuads),
                                              parameters: parameters, output: displayOutput)
        updateScopes()
        return "preview \(rendered.width)×\(rendered.height)" + (info.demosaicWasCached ? " (cached)" : "")
    }

    /// Measures the selected scope from the analysis texture. The texture
    /// is linear EDR; the kernels encode it so the shapes are the familiar
    /// ones and anything above 1.0 counts as SDR clipping.
    private func updateScopes() {
        guard let analysisTexture else { return }
        switch scope {
        case .histogram:
            histogram = histogramCalculator?.compute(from: analysisTexture, inputIsLinear: true)
        case .waveform:
            waveform = scopeCalculator?.computeWaveform(from: analysisTexture, inputIsLinear: true)
        case .vectorscope:
            vectorscope = scopeCalculator?.computeVectorscope(from: analysisTexture, inputIsLinear: true)
        }
    }

    @discardableResult
    private func renderTile(session: ImageSession, pipeline: RenderPipeline,
                            region: (x: Int, y: Int, width: Int, height: Int)) throws -> String {
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        let rendered = try pipeline.render(
            session,
            scale: .region(x: region.x, y: region.y, width: region.width, height: region.height),
            parameters: parameters, output: displayOutput, info: &info)
        tile = PresentLayer(texture: rendered, coverage: info.sensorRect, inset: Self.tileInset)
        return "tile \(rendered.width)×\(rendered.height)" + (info.demosaicWasCached ? " (cached)" : "")
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
        let userRotation = self.userRotation

        isExporting = true
        status = "Exporting at full resolution…"

        Task {
            do {
                let elapsed = try await exportService.export(from: sourceURL,
                                                              to: destination,
                                                              parameters: params,
                                                              settings: settings,
                                                              userRotation: userRotation)
                isExporting = false
                status = String(format: "Exported %@ in %.1fs",
                                 destination.lastPathComponent, elapsed)
            } catch {
                isExporting = false
                status = "Export failed: \(error)"
            }
        }
    }

    /// Lets other parts of the app put a message in the status bar.
    func reportError(_ message: String) {
        status = message
    }

    func resetWhiteBalance() {
        parameters.whiteBalance = asShotWhiteBalance
    }

    func resetAdjustments() {
        parameters = defaultParameters
    }

    /// Computes a starting point from the image and applies it. Exposure,
    /// contrast and white balance change; everything else stays.
    func autoAdjust() {
        guard let session, let pipeline, let gpuContext else { return }
        do {
            let suggestion = try AutoAdjust.suggest(for: session, pipeline: pipeline,
                                                    gpu: gpuContext, current: parameters)
            var next = parameters
            next.exposureEV = suggestion.exposureEV
            next.contrast = suggestion.contrast
            if let wb = suggestion.whiteBalance { next.whiteBalance = wb }
            parameters = next
        } catch {
            status = "Auto failed: \(error)"
        }
    }
}
