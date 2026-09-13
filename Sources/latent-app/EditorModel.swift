import Foundation
import Metal
import simd
import SwiftUI
import UniformTypeIdentifiers
import RawCore
import ColorKit
import PixelEngine
import MLKit

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
                if parameters.crop != oldValue.crop { canvasDidChange() }
                rerender()
                scheduleSave()
            }
        }
    }

    // MARK: - Neural denoise

    @Published private(set) var aiDenoiseStatus = ""
    @Published private(set) var aiDenoiseRunning = false
    private var aiDenoiseTask: Task<Void, Never>?
    private static var sharedDenoisers: [AIDenoiser.Variant: AIDenoiser] = [:]
    var aiDenoiseAvailable: Bool { AIDenoiser.isAvailable }
    var hasAIDenoiseResult: Bool { session?.aiDenoisedCameraRGB != nil }

    /// Which network to use. Changing it drops the cached result and, if
    /// the strength is up, runs the new one.
    @Published var aiDenoiseVariant: AIDenoiser.Variant = AIDenoiser.preferredVariant {
        didSet {
            guard aiDenoiseVariant != oldValue else { return }
            AIDenoiser.preferredVariant = aiDenoiseVariant
            aiDenoiseTask?.cancel()
            aiDenoiseRunning = false
            session?.setAIDenoised(nil, model: nil)
            aiDenoiseStatus = ""
            if parameters.aiDenoise > 0 { runAIDenoise() } else { rerender() }
        }
    }

    // Optional high-quality model: download state.
    @Published private(set) var modelDownloadProgress: Double?   // 0…1 while downloading
    @Published private(set) var modelDownloadStatus = ""
    @Published private(set) var highQualityModelInstalled = OptionalModel.nafnetWidth64.isInstalled
    private var modelDownloadTask: Task<Void, Never>?

    func downloadHighQualityModel() {
        guard modelDownloadProgress == nil else { return }
        let model = OptionalModel.nafnetWidth64
        modelDownloadProgress = 0
        modelDownloadStatus = "Downloading \(model.title) (\(model.sizeMB) MB)…"
        modelDownloadTask = Task { [weak self] in
            do {
                try await ModelDownloader.install(model) { [weak self] received, expected in
                    Task { @MainActor in
                        self?.modelDownloadProgress = expected > 0 ? Double(received) / Double(expected) : 0
                    }
                }
                self?.modelDownloadProgress = nil
                self?.highQualityModelInstalled = model.isInstalled
                self?.modelDownloadStatus = "Installed. Choose “High quality” above."
            } catch is CancellationError {
                self?.modelDownloadProgress = nil
                self?.modelDownloadStatus = ""
            } catch {
                self?.modelDownloadProgress = nil
                self?.modelDownloadStatus = "\(error)"
            }
        }
    }

    func cancelModelDownload() { modelDownloadTask?.cancel() }

    func removeHighQualityModel() {
        do { try ModelDownloader.remove(.nafnetWidth64) } catch { reportFailure("Removing the model", error) }
        highQualityModelInstalled = OptionalModel.nafnetWidth64.isInstalled
        Self.sharedDenoisers[.high] = nil
        if aiDenoiseVariant == .high { aiDenoiseVariant = .standard }
        modelDownloadStatus = "Removed."
    }

    /// Runs the network over the open image (once; the result lives with
    /// the session) and re-renders. ~12 s for 24 MP on the GPU.
    func runAIDenoise() {
        guard let session, let pipeline, let gpu = gpuContext, !aiDenoiseRunning else { return }
        guard AIDenoiser.isAvailable else {
            aiDenoiseStatus = "NAFNet model not bundled — see Sources/MLKit/Resources/Models/README.md"
            return
        }
        aiDenoiseRunning = true
        aiDenoiseStatus = "Loading model…"
        let imageID = catalogImageID
        aiDenoiseTask = Task { [weak self] in
            do {
                let variant = AIDenoiser.preferredVariant
                let denoiser: AIDenoiser
                if let d = Self.sharedDenoisers[variant] { denoiser = d } else {
                    denoiser = try await AIDenoiser.load(variant)
                    Self.sharedDenoisers[variant] = denoiser
                }
                let seconds = try await AIDenoiseWorker.run(
                    session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser
                ) { [weak self] done, total in
                    Task { @MainActor in
                        self?.aiDenoiseStatus = "Denoising… \(done) of \(total) tiles"
                    }
                }
                guard let model = self, model.catalogImageID == imageID || model.session === session else { return }
                model.aiDenoiseStatus = String(format: "Denoised in %.1f s (%@)", seconds, denoiser.variant.displayName)
                model.aiDenoiseRunning = false
                if model.parameters.aiDenoise == 0 { model.parameters.aiDenoise = 1 } else { model.rerender() }
            } catch is CancellationError {
                self?.aiDenoiseRunning = false
                self?.aiDenoiseStatus = ""
            } catch {
                self?.aiDenoiseRunning = false
                self?.aiDenoiseStatus = "Denoise failed: \(error)"
            }
        }
    }

    func cancelAIDenoise() {
        aiDenoiseTask?.cancel()
    }

    /// A stored edit with denoise on needs the result recomputed on open.
    private func regenerateAIDenoiseIfNeeded() {
        if parameters.aiDenoise > 0, !hasAIDenoiseResult, !aiDenoiseRunning { runAIDenoise() }
    }

    /// Slider binding: moving it off zero with no result yet starts the run.
    var aiDenoiseStrength: Float {
        get { parameters.aiDenoise }
        set {
            parameters.aiDenoise = newValue
            if newValue > 0 { regenerateAIDenoiseIfNeeded() }
        }
    }

    // MARK: - Spot removal tool

    /// Click a spot to heal it (the source is picked beside it); drag from
    /// a spot to choose the source yourself; drag either circle of an
    /// existing patch to move it.
    @Published var healToolActive = false {
        didSet {
            guard healToolActive != oldValue else { return }
            if healToolActive { cropToolActive = false; maskTool = .none } else { selectedHealIndex = nil }
        }
    }
    @Published var selectedHealIndex: Int?
    /// Defaults for the next patch; editing a selected patch updates these too.
    @Published var healRadius: Float = 0.02
    @Published var healFeather: Float = 0.35
    @Published var healMode: HealPatch.Mode = .heal

    private enum HealDrag { case placing(Int), movingTarget(Int, SIMD2<Float>), movingSource(Int, SIMD2<Float>) }
    private var healDrag: HealDrag?

    var selectedHeal: HealPatch? {
        guard let i = selectedHealIndex, i < parameters.heals.count else { return nil }
        return parameters.heals[i]
    }

    /// Radius of the selected patch (or the default), in sensor pixels.
    var activeHealRadiusPixels: Float {
        get { (selectedHeal?.radius ?? healRadius) * Float(min(sensorSize.width, sensorSize.height)) }
        set {
            let short = Float(min(sensorSize.width, sensorSize.height))
            guard short > 0 else { return }
            let r = max(0.001, min(0.25, newValue / short))
            healRadius = r
            if let i = selectedHealIndex, i < parameters.heals.count { parameters.heals[i].radius = r }
        }
    }
    var activeHealFeather: Float {
        get { selectedHeal?.feather ?? healFeather }
        set {
            healFeather = newValue
            if let i = selectedHealIndex, i < parameters.heals.count { parameters.heals[i].feather = newValue }
        }
    }
    var activeHealMode: HealPatch.Mode {
        get { selectedHeal?.mode ?? healMode }
        set {
            healMode = newValue
            if let i = selectedHealIndex, i < parameters.heals.count { parameters.heals[i].mode = newValue }
        }
    }

    func deleteSelectedHeal() {
        guard let i = selectedHealIndex, i < parameters.heals.count else { return }
        parameters.heals.remove(at: i)
        selectedHealIndex = parameters.heals.isEmpty ? nil : min(i, parameters.heals.count - 1)
    }

    func clearHeals() {
        parameters.heals = []
        selectedHealIndex = nil
    }

    /// Which patch and which of its circles is under `p` (normalized sensor).
    private func hitHeal(_ p: SIMD2<Float>) -> (index: Int, isSource: Bool, offset: SIMD2<Float>)? {
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        // Selected patch first, then the most recent on top.
        var order = Array(parameters.heals.indices.reversed())
        if let s = selectedHealIndex, let k = order.firstIndex(of: s) { order.remove(at: k); order.insert(s, at: 0) }
        for i in order {
            let h = parameters.heals[i]
            let rPx = h.radius * short
            if simd_length((p - h.source) * size) <= rPx { return (i, true, p - h.source) }
            if simd_length((p - h.target) * size) <= rPx { return (i, false, p - h.target) }
        }
        return nil
    }

    func healToolBegan(at screen: CGPoint) {
        guard hasImage else { return }
        let p = sensorNormalized(screen)
        if let hit = hitHeal(p) {
            selectedHealIndex = hit.index
            healDrag = hit.isSource ? .movingSource(hit.index, hit.offset) : .movingTarget(hit.index, hit.offset)
            return
        }
        guard parameters.heals.count < HealPatch.maximumCount else {
            status = "At most \(HealPatch.maximumCount) spot patches per image"
            return
        }
        // Default source: 2.5 radii to the right, or to the left near the edge.
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        var offset = SIMD2(2.5 * healRadius * short / size.x, 0)
        if p.x + offset.x + healRadius * short / size.x > 1 { offset = -offset }
        let source = simd_clamp(p + offset, SIMD2(0, 0), SIMD2(1, 1))
        parameters.heals.append(HealPatch(target: p, source: source, radius: healRadius,
                                          feather: healFeather, mode: healMode))
        selectedHealIndex = parameters.heals.count - 1
        healDrag = .placing(parameters.heals.count - 1)
    }

    func healToolMoved(to screen: CGPoint) {
        guard let healDrag else { return }
        let p = simd_clamp(sensorNormalized(screen), SIMD2(0, 0), SIMD2(1, 1))
        switch healDrag {
        case .placing(let i) where i < parameters.heals.count:
            parameters.heals[i].source = p
        case .movingTarget(let i, let off) where i < parameters.heals.count:
            parameters.heals[i].target = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
        case .movingSource(let i, let off) where i < parameters.heals.count:
            parameters.heals[i].source = simd_clamp(p - off, SIMD2(0, 0), SIMD2(1, 1))
        default:
            break
        }
    }

    func healToolEnded() { healDrag = nil }

    /// Turns off every on-image tool. Called when the viewport is about
    /// to be used for viewing only (Loupe, Compare) and by Escape.
    func disarmTools() {
        healToolActive = false
        cropToolActive = false
        maskTool = .none
        healDrag = nil
    }

    // MARK: - Image tools (dispatch)

    /// Whether drags on the image belong to a tool rather than panning.
    var imageToolActive: Bool { maskToolActive || healToolActive }

    func imageToolBegan(at screen: CGPoint, exclude: Bool) {
        if healToolActive { healToolBegan(at: screen); return }
        promptModifierExclude = exclude
        maskToolBegan(at: screen)
    }
    func imageToolMoved(to screen: CGPoint) {
        if healToolActive { healToolMoved(to: screen) } else { maskToolMoved(to: screen) }
    }
    func imageToolEnded() {
        if healToolActive { healToolEnded() } else { maskToolEnded() }
    }

    // MARK: - Crop and straighten

    /// While on, the viewport shows the whole (straightened) sensor with
    /// the crop rectangle drawn over it; off, it shows only the crop.
    @Published var cropToolActive = false {
        didSet {
            guard cropToolActive != oldValue else { return }
            if !cropToolActive { straightenBase = nil } else { healToolActive = false }
            canvasDidChange()
            rerenderForViewport()
        }
    }
    /// The crop as it was before the straighten slider started moving, so
    /// turning the angle back re-grows the crop instead of leaving it at
    /// whatever the largest angle forced it to.
    private var straightenBase: CropParameters?

    /// The geometry of the stored crop (what export uses).
    private var cropFrame: CropFrame {
        CropFrame(sensorSize: sensorSize, crop: parameters.crop, rotation: rotation)
    }

    /// The geometry the viewport shows: the crop, or with the tool open,
    /// the whole sensor at the crop's angle.
    var frame: CropFrame { cropToolActive ? cropFrame.toolFrame : cropFrame }

    /// The crop rectangle on the tool canvas, in canvas pixels. Setting it
    /// is what the overlay's handles do.
    var cropCanvasRect: CGRect {
        get { cropFrame.toolCanvasRect }
        set {
            guard hasImage else { return }
            straightenBase = nil
            parameters.crop = cropFrame.cropForToolCanvasRect(newValue).constrained(sensorSize: sensorSize)
        }
    }

    /// Bounds the crop rectangle may occupy on the tool canvas. Exact at
    /// 0°; at other angles the sensor is a tilted rectangle inside this
    /// box and `constrained` shrinks the crop to stay on it.
    var cropCanvasBounds: CGRect { CGRect(origin: .zero, size: frame.canvasSize) }

    func setStraighten(_ degrees: Float) {
        guard hasImage else { return }
        var base = straightenBase ?? parameters.crop
        base.angle = max(-45, min(45, degrees))
        straightenBase = base
        parameters.crop = base.constrained(sensorSize: sensorSize)
    }

    /// Locks the crop to `ratio` (width:height as displayed, so a
    /// portrait-oriented image's "3:2" is tall), or frees it with nil.
    func setCropAspect(displayRatio ratio: Float?) {
        guard hasImage else { return }
        straightenBase = nil
        guard let ratio else { parameters.crop.aspect = nil; return }
        let sensorRatio = rotation.swapsAxes ? 1 / ratio : ratio
        parameters.crop = parameters.crop.withAspect(sensorRatio, sensorSize: sensorSize)
    }

    /// The lock as displayed, or nil when free.
    var cropAspectDisplayRatio: Float? {
        guard let a = parameters.crop.aspect else { return nil }
        return rotation.swapsAxes ? 1 / a : a
    }

    /// The image's own ratio as displayed, for the "Original" option.
    var originalDisplayRatio: Float {
        let s = rotation.imageSize(forSensorSize: sensorSize)
        return s.height > 0 ? Float(s.width / s.height) : 1
    }

    /// Output size in pixels after the crop, as displayed.
    var croppedPixelSize: CGSize { cropFrame.canvasSize }

    func resetCrop() {
        guard hasImage else { return }
        straightenBase = nil
        parameters.crop = .none
        parameters.perspective = .none
    }

    /// The canvas changed size or shape (crop, tool, rotation): re-fit if
    /// fitted, else keep the view clamped to the new canvas.
    private func canvasDidChange() {
        guard hasImage, drawableSize.width > 0 else { return }
        if fitMode {
            viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)
        } else {
            viewport = viewport.clamped(imageSize: imageSize, drawableSize: drawableSize)
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
            do {
                onEditSettled?(id, try stack.encodeJSON())
            } catch {
                reportFailure("Encoding the edit", error)
            }
        }
        recordHistoryStep()
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
    /// the presenter can hand it to the EDR layer untouched. While a local
    /// is selected and its mask should be visible, the overlay index rides
    /// along — a display setting, never part of the edit.
    private var displayOutput: RenderOutput {
        // Proofing simulates an SDR file, so the display headroom is
        // dropped to 1 while it's on: an EDR highlight can't be in a JPEG.
        var output = RenderOutput.edrDisplay(headroom: proofLUT == nil ? effectiveHeadroom : 1)
        if showMaskOverlay || isDraggingMask, let i = selectedLocalIndex, i < parameters.locals.count {
            output.maskOverlay = i
        }
        output.proof = proofLUT
        output.gamutWarning = gamutWarning
        return output
    }

    // MARK: - Soft proofing

    @Published var proofEnabled = false { didSet { if proofEnabled != oldValue { rebuildProof() } } }
    @Published var proofTarget: SoftProofTarget = .sRGB { didSet { if proofTarget != oldValue { rebuildProof() } } }
    @Published var gamutWarning = false { didSet { if gamutWarning != oldValue { rerender() } } }
    @Published private(set) var proofStatus = ""
    private(set) var proofLUT: SoftProofLUT?

    /// Builds the proof table (a few ms for a matrix space, tens for an
    /// ICC profile) and re-renders. Off = no table at all, so proofing
    /// costs nothing when it isn't on.
    private func rebuildProof() {
        guard proofEnabled else {
            proofLUT = nil; proofStatus = ""; rerender(); return
        }
        do {
            let lut = try SoftProofLUT.build(proofTarget)
            proofLUT = lut
            proofStatus = String(format: "%@ · %.1f%% of colours out of gamut",
                                 proofTarget.displayName, lut.outOfGamutFraction * 100)
        } catch {
            proofLUT = nil
            proofStatus = "Proof failed: \(error)"
        }
        rerender()
    }

    func chooseProofProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data,
                                     UTType(filenameExtension: "icm") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: "/Library/ColorSync/Profiles")
        panel.message = "Choose an ICC profile to proof against (printer, paper, display)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        proofTarget = .icc(url)
        proofEnabled = true
    }

    // MARK: - Local adjustments

    enum MaskTool: String, CaseIterable { case none, linear, radial, brush, erase, prompt }

    @Published var selectedLocalIndex: Int? {
        didSet { if selectedLocalIndex != oldValue { maskTool = .none; rerender() } }
    }
    @Published var maskTool: MaskTool = .none
    @Published var showMaskOverlay = false {
        didSet { if showMaskOverlay != oldValue { rerender() } }
    }
    @Published var brushRadius: Float = 0.04    // fraction of the short side
    @Published var brushFeather: Float = 0.5
    @Published var brushFlow: Float = 1.0
    private var isDraggingMask = false {
        didSet { if isDraggingMask != oldValue { rerender() } }
    }
    private var lastDab: SIMD2<Float>?

    var selectedLocal: LocalAdjustment? {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return nil }
        return parameters.locals[i]
    }

    /// Adds a local with sensible starting geometry, selects it, and arms
    /// the matching tool so the next drag on the image places it.
    func addLocal(_ kind: MaskTool) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let n = parameters.locals.count + 1
        let local: LocalAdjustment
        switch kind {
        case .linear:
            local = LocalAdjustment(name: "Gradient \(n)", shape: .linear(start: SIMD2(0.5, 0.0), end: SIMD2(0.5, 0.5)))
        case .radial:
            local = LocalAdjustment(name: "Radial \(n)", shape: .radial(centre: SIMD2(0.5, 0.5), radii: SIMD2(0.3, 0.3), feather: 0.5))
        case .brush, .erase:
            local = LocalAdjustment(name: "Brush \(n)", shape: .brush(strokes: []))
        case .prompt:
            addPromptedMask()
            return
        case .none:
            local = LocalAdjustment(name: "Whole image \(n)", shape: .whole)
        }
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        maskTool = kind == .none ? .none : (kind == .erase ? .brush : kind)
    }

    /// Names of AI locals whose masks are being generated right now.
    @Published private(set) var generatingMasks: Set<UUID> = []

    /// Adds a model-generated mask and starts generating its pixels. The
    /// model runs off the main thread on a small sRGB copy of the image
    /// rendered *unrotated*, so the mask lands in sensor coordinates like
    /// every other mask.
    func addAIMask(_ kind: AIMaskKind) {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let local = LocalAdjustment(name: kind.displayName,
                                    shape: .ai(kind: kind.rawValue, modelVersion: kind.modelVersion))
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        showMaskOverlay = true
        generateAIMask(for: local)
    }

    /// Regenerates masks for AI locals that have no pixels yet — after
    /// opening an image whose edit contains them.
    private func regenerateMissingAIMasks() {
        guard let session else { return }
        for local in parameters.locals where local.shape.isModelGenerated {
            if !session.hasAIMask(forLocal: local.id), !generatingMasks.contains(local.id) {
                generateAIMask(for: local)
            }
        }
    }

    /// The image as the models see it: ~1000 px on the long edge, encoded
    /// sRGB, unrotated so masks land in sensor coordinates. Rendered from
    /// the pipeline with the image's defaults (no locals, so a mask never
    /// depends on the edits it will drive).
    private func modelInputImage() throws -> CGImage {
        guard let session, let pipeline, let gpu = gpuContext else { throw AIMaskError.noResult }
        let longEdge = max(session.file.summary.rawWidth, session.file.summary.rawHeight)
        let quads = max(1, Int((Double(longEdge) / 2048.0).rounded(.up)))
        var neutral = defaultParameters
        neutral.locals = []
        let tex = try pipeline.render(session, scale: .binned(quads: quads), parameters: neutral,
                                      output: .file(.sRGB))
        return try Exporter(gpu: gpu).cgImage(from: tex, colorSpace: .sRGB)
    }

    private func generateAIMask(for local: LocalAdjustment) {
        guard let session else { return }
        if case .prompted = local.shape { updatePromptedMask(for: local); return }
        guard case .ai(let kindName, _) = local.shape,
              let kind = AIMaskKind(storedName: kindName) else { return }
        generatingMasks.insert(local.id)
        status = "Generating \(kind.displayName.lowercased()) mask…"

        let image: CGImage
        do {
            image = try modelInputImage()
        } catch {
            generatingMasks.remove(local.id)
            status = "Mask failed: \(error)"
            return
        }
        let input = SendableImage(cgImage: image)
        let localID = local.id
        // Swift 6 concurrency shape: only Sendable values (the image
        // wrapper and the kind) cross into the detached task; the result
        // comes back as a value, and the main-actor task below is the only
        // place that touches the model or the session.
        Task { @MainActor [weak self] in
            let outcome: Result<AIMaskGenerator.Result, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await AIMaskGenerator.generate(kind, from: input.cgImage)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.generatingMasks.remove(localID)
            switch outcome {
            case .success(let result):
                // The user may have moved to another image while the model ran.
                guard self.session === session else { return }
                session.setAIMask(result.mask, forLocal: localID)
                self.status = String(format: "%@ mask: %.0f ms on device, %.0f%% of the frame",
                                     kind.displayName, result.seconds * 1000, result.mask.coverage * 100)
                self.rerender()
            case .failure(let error):
                self.status = "\(kind.displayName) mask failed: \(error)"
            }
        }
    }

    // MARK: Click-to-select (Segment Anything 2)

    /// The encoded image for SAM 2, built on first use per image. Encoding
    /// is the expensive step (hundreds of ms); every click after it is a
    /// few milliseconds.
    private var sam2Session: SAM2Session?
    private var sam2Encoding: Task<SAM2Session?, Never>?
    @Published private(set) var sam2Status = ""

    var sam2Available: Bool { SAM2Models.isAvailable }

    /// Adds a click-to-select mask and arms the prompt tool. The image is
    /// encoded in the background right away so the first click is quick.
    func addPromptedMask() {
        guard hasImage, parameters.locals.count < LocalAdjustment.maximumCount else { return }
        let local = LocalAdjustment(name: "Selection \(parameters.locals.count + 1)",
                                    shape: .prompted(points: [], modelVersion: SAM2Models.modelVersion))
        parameters.locals.append(local)
        selectedLocalIndex = parameters.locals.count - 1
        maskTool = .prompt
        showMaskOverlay = true
        ensureSAM2Session()
    }

    private func ensureSAM2Session() {
        guard sam2Session == nil, sam2Encoding == nil, let session else { return }
        let image: CGImage
        do { image = try modelInputImage() } catch {
            sam2Status = "Click-to-select unavailable: \(error)"
            return
        }
        let input = SendableImage(cgImage: image)
        sam2Status = "Encoding image for click-to-select…"
        sam2Encoding = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> SAM2Session? in
                guard let models = await SAM2Models.shared.value else { return nil }
                return try? SAM2Session(models: models, image: input.cgImage)
            }.value
            guard let self, self.session === session else { return nil }
            self.sam2Session = result
            self.sam2Encoding = nil
            self.sam2Status = result.map { String(format: "Image encoded in %.0f ms — click the subject; option-click to exclude", $0.encodeSeconds * 1000) }
                ?? "Click-to-select unavailable (SAM 2 models not bundled)"
            // Any prompted locals that were waiting for the encoding.
            for local in self.parameters.locals {
                if case .prompted(let pts, _) = local.shape, !pts.isEmpty { self.updatePromptedMask(for: local) }
            }
            return result
        }
    }

    /// A click on the image while the prompt tool is armed.
    func promptClick(at screen: CGPoint, foreground: Bool) {
        guard let i = selectedLocalIndex, i < parameters.locals.count,
              case .prompted(var points, let version) = parameters.locals[i].shape else { return }
        let p = sensorNormalized(screen)
        points.append(MaskPromptPoint(x: p.x, y: p.y, foreground: foreground))
        parameters.locals[i].shape = .prompted(points: points, modelVersion: version)
        updatePromptedMask(for: parameters.locals[i])
    }

    func clearPromptPoints() {
        guard let i = selectedLocalIndex, i < parameters.locals.count,
              case .prompted(_, let version) = parameters.locals[i].shape else { return }
        parameters.locals[i].shape = .prompted(points: [], modelVersion: version)
        session?.setAIMask(nil, forLocal: parameters.locals[i].id)
        rerender()
    }

    private func updatePromptedMask(for local: LocalAdjustment) {
        guard case .prompted(let points, _) = local.shape, let session else { return }
        guard !points.isEmpty else { return }
        guard let sam = sam2Session else { ensureSAM2Session(); return }
        let prompts = points.map { PromptPoint(x: $0.x, y: $0.y, foreground: $0.foreground) }
        let localID = local.id
        generatingMasks.insert(localID)
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try sam.predict(points: prompts) }
            }.value
            guard let self, self.session === session else { return }
            self.generatingMasks.remove(localID)
            switch outcome {
            case .success(let prediction):
                session.setAIMask(prediction.mask, forLocal: localID)
                self.status = String(format: "Selection: %.0f ms, confidence %.2f, %.0f%% of the frame",
                                     prediction.seconds * 1000, prediction.score, prediction.mask.coverage * 100)
                self.rerender()
            case .failure(let error):
                self.status = "Selection failed: \(error)"
            }
        }
    }

    func removeSelectedLocal() {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return }
        parameters.locals.remove(at: i)
        selectedLocalIndex = parameters.locals.isEmpty ? nil : min(i, parameters.locals.count - 1)
    }

    /// Whether drags on the image should shape a mask instead of panning.
    var maskToolActive: Bool { maskTool != .none && selectedLocal != nil && !cropToolActive }

    /// Screen pixel -> normalized sensor coordinate, through the viewport
    /// (rotated image space) and the rotation (back to the sensor).
    private func sensorNormalized(_ screen: CGPoint) -> SIMD2<Float> {
        let canvas = viewport.sensorPoint(forScreenPoint: screen, drawableSize: drawableSize)
        let sensor = frame.sensorPoint(fromCanvasPoint: canvas)
        return SIMD2(Float(sensor.x / sensorSize.width), Float(sensor.y / sensorSize.height))
    }

    /// Option held during the click: the view passes it through so a
    /// prompt click can mean "exclude this".
    var promptModifierExclude = false

    func maskToolBegan(at screen: CGPoint) {
        guard let i = selectedLocalIndex, i < parameters.locals.count else { return }
        if maskTool == .prompt {
            promptClick(at: screen, foreground: !promptModifierExclude)
            return
        }
        let p = sensorNormalized(screen)
        isDraggingMask = true
        switch (maskTool, parameters.locals[i].shape) {
        case (.linear, _):
            parameters.locals[i].shape = .linear(start: p, end: p)
        case (.radial, _):
            parameters.locals[i].shape = .radial(centre: p, radii: SIMD2(0.001, 0.001), feather: currentFeather(i))
        case (.brush, .brush(var strokes)), (.erase, .brush(var strokes)):
            strokes.append(BrushStroke(points: [p], radius: brushRadius, feather: brushFeather,
                                       flow: brushFlow, erase: maskTool == .erase))
            parameters.locals[i].shape = .brush(strokes: strokes)
            lastDab = p
        default:
            break
        }
    }

    func maskToolMoved(to screen: CGPoint) {
        guard isDraggingMask, let i = selectedLocalIndex, i < parameters.locals.count else { return }
        let p = sensorNormalized(screen)
        switch (maskTool, parameters.locals[i].shape) {
        case (.linear, .linear(let start, _)):
            parameters.locals[i].shape = .linear(start: start, end: p)
        case (.radial, .radial(let centre, _, let feather)):
            // Distance in sensor pixels as a fraction of the short side, so
            // the circle is round whatever the aspect ratio.
            let d = (p - centre) * SIMD2(Float(sensorSize.width), Float(sensorSize.height))
            let r = max((d.x * d.x + d.y * d.y).squareRoot() / Float(min(sensorSize.width, sensorSize.height)), 0.005)
            parameters.locals[i].shape = .radial(centre: centre, radii: SIMD2(r, r), feather: feather)
        case (.brush, .brush(var strokes)), (.erase, .brush(var strokes)):
            // Space dabs at a quarter radius so the stroke reads as continuous.
            guard var last = strokes.popLast() else { return }
            let spacing = brushRadius * 0.25
            let scale = SIMD2(Float(sensorSize.width), Float(sensorSize.height)) / Float(min(sensorSize.width, sensorSize.height))
            let from = lastDab ?? p
            let delta = (p - from) * scale
            let dist = (delta.x * delta.x + delta.y * delta.y).squareRoot()
            if dist >= spacing {
                let steps = Int(dist / spacing)
                for k in 1...steps {
                    last.points.append(from + (p - from) * (Float(k) / Float(steps)))
                }
                lastDab = p
            }
            strokes.append(last)
            parameters.locals[i].shape = .brush(strokes: strokes)
        default:
            break
        }
    }

    func maskToolEnded() {
        isDraggingMask = false
        lastDab = nil
        // A gradient or radial is placed once; further drags would move it
        // again, which is rarely what's wanted. Brushes keep painting.
        if maskTool == .linear || maskTool == .radial { maskTool = .none }
    }

    private func currentFeather(_ i: Int) -> Float {
        if case .radial(_, _, let f) = parameters.locals[i].shape { return f }
        return 0.5
    }

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
    private(set) var drawableSize: CGSize = .zero

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

    /// The image as the user sees it — cropped, straightened and rotated.
    /// Zoom, pan and fit all work in this canvas space; the pipeline
    /// never sees it.
    private var imageSize: CGSize { frame.canvasSize }

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
            if let editStackJSON {
                do {
                    let stack = try EditStack.decode(json: editStackJSON)
                    restored = stack.parameters(defaults: fresh)
                    if restored.whiteBalance.isAsShot { restored.whiteBalance = fresh.whiteBalance }
                } catch {
                    // Showing defaults is the only option, but the user must
                    // know the stored edit exists and wasn't applied.
                    reportFailure("Reading the stored edit for \(url.lastPathComponent) (showing defaults; editing will replace it)", error)
                }
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
            sam2Session = nil
            sam2Encoding?.cancel()
            sam2Encoding = nil
            sam2Status = ""
            history = EditHistory(initial: EditStack(parameters: parameters))
            snapshots = []
            aiDenoiseTask?.cancel()
            aiDenoiseRunning = false
            aiDenoiseStatus = ""
            rerender()
            regenerateMissingAIMasks()
            regenerateAIDenoiseIfNeeded()
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

    /// Keyboard version of double-click: fit ↔ 100% about the centre.
    func toggleZoomAtCenter() {
        toggleZoom(at: CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2))
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
        let visibleCanvas = viewport.visibleSensorRect(drawableSize: drawableSize)
        return frame.sensorRect(fromCanvasRect: visibleCanvas)
    }

    private func wantedTileRegion() -> (x: Int, y: Int, width: Int, height: Int) {
        var visible = visibleSensorRect.insetBy(dx: -Self.tileMargin, dy: -Self.tileMargin)
        // Keystone reads pixels from elsewhere in the frame; widen the tile
        // to the source region so the corrected view is complete.
        if !parameters.perspective.isIdentity {
            visible = parameters.perspective.sourceRect(forSensorRect: visible, sensorSize: sensorSize)
                .insetBy(dx: -4, dy: -4)
        }
        // A patch on screen must be able to read its source, which may lie
        // outside the visible area: widen the tile to include it.
        for p in parameters.heals where p.targetBounds(sensorSize: sensorSize).intersects(visible) {
            visible = visible.union(p.sourceBounds(sensorSize: sensorSize).insetBy(dx: -2, dy: -2))
        }
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
    /// What actually renders: the edit, or the defaults while "before"
    /// is held.
    private var renderParameters: EditParameters { showingBefore ? defaultParameters : parameters }

    @discardableResult
    private func renderPreview(session: ImageSession, pipeline: RenderPipeline) throws -> String {
        let quads = wantedPreviewQuads
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
        let rendered = try pipeline.render(session, scale: .binned(quads: quads),
                                            parameters: renderParameters, output: displayOutput,
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
                                              parameters: renderParameters, output: displayOutput)
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
            parameters: renderParameters, output: displayOutput, info: &info)
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

    /// A failure the user must see: shown in red in the status bar in
    /// every mode until dismissed, and logged with the full error.
    @Published var lastError: String?

    func reportFailure(_ what: String, _ error: Error) {
        lastError = "\(what) failed: \(error)"
        Log.editor.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    func resetWhiteBalance() {
        parameters.whiteBalance = asShotWhiteBalance
    }

    func resetAdjustments() {
        parameters = defaultParameters
    }

    // MARK: - Copy / paste / presets

    /// The clipboard is a partial edit stack, kept as JSON on the system
    /// pasteboard so it also crosses app instances. Custom type plus a
    /// plain-text copy for humans.
    static let pasteboardType = NSPasteboard.PasteboardType("com.latent.editstack+json")

    /// Groups to carry on the next paste. Persisted so the checklist
    /// remembers what the user usually wants.
    @Published var pasteGroups: Set<EditGroup> = {
        if let raw = UserDefaults.standard.array(forKey: "latent.pasteGroups") as? [String] {
            return Set(raw.compactMap(EditGroup.init(rawValue:)))
        }
        return EditGroup.lookGroups
    }() {
        didSet { UserDefaults.standard.set(pasteGroups.map(\.rawValue), forKey: "latent.pasteGroups") }
    }

    /// Copies the current edit (restricted to `pasteGroups`).
    func copySettings() {
        guard hasImage else { return }
        let stack = EditStack(parameters: parameters).restricted(to: pasteGroups)
        guard let json = try? stack.encodeJSON() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: Self.pasteboardType)
        pb.setString(json, forType: .string)
        status = "Copied \(pasteGroups.count) group\(pasteGroups.count == 1 ? "" : "s") of settings"
    }

    /// The stack on the pasteboard, if any.
    static func clipboardStack() -> EditStack? {
        let pb = NSPasteboard.general
        guard let json = pb.string(forType: pasteboardType) ?? pb.string(forType: .string),
              let stack = try? EditStack.decode(json: json) else { return nil }
        return stack
    }

    /// Applies a partial stack to the open image.
    func apply(_ stack: EditStack, groups: Set<EditGroup>) {
        guard hasImage else { return }
        let current = EditStack(parameters: parameters)
        var next = current.merged(with: stack, groups: groups).parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        parameters = next
    }

    func pasteSettings() {
        guard let stack = Self.clipboardStack() else { status = "Nothing to paste"; return }
        apply(stack, groups: pasteGroups.intersection(stack.presentGroups).union(pasteGroups.subtracting(stack.presentGroups)))
        status = "Pasted settings"
    }

    @Published var presets: [Preset] = PresetStore.load()

    func applyPreset(_ preset: Preset) {
        apply(preset.stack, groups: preset.groups)
        status = "Applied preset “\(preset.name)”"
    }

    func savePreset(named name: String, groups: Set<EditGroup>) {
        guard hasImage, !name.isEmpty else { return }
        let preset = Preset(name: name, groups: groups, stack: EditStack(parameters: parameters))
        do {
            try PresetStore.save(preset)
            presets = PresetStore.load()
            status = "Saved preset “\(name)”"
        } catch {
            status = "Could not save preset: \(error)"
        }
    }

    func deletePreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        do { try PresetStore.delete(named: preset.name) } catch { reportFailure("Deleting preset “\(preset.name)”", error) }
        presets = PresetStore.load()
    }

    // MARK: - History (undo / redo) and snapshots

    @Published private(set) var history = EditHistory(initial: EditStack())
    @Published private(set) var snapshots: [EditSnapshot] = []
    /// Set by ContentView so history and snapshots reach the catalog.
    var onHistoryChanged: ((_ imageID: Int64, _ steps: [(stackJSON: String, createdAt: Int64)]) -> Void)?
    var onSnapshotsChanged: ((_ imageID: Int64, _ snapshots: [(name: String, stackJSON: String)]) -> Void)?
    /// True while applying a history/snapshot state so it isn't re-recorded.
    private var restoringState = false

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Loads stored history/snapshots after an image opens. The current
    /// edit becomes the cursor position (appended if it isn't the last
    /// stored step, e.g. the sidecar was edited elsewhere).
    func loadHistory(steps: [(stackJSON: String, createdAt: Int64)],
                     snapshots stored: [(name: String, stackJSON: String)]) {
        var entries: [EditHistory.Step] = steps.compactMap { step in
            guard let stack = try? EditStack.decode(json: step.stackJSON) else { return nil }
            return EditHistory.Step(stack: stack, label: "", date: Date(timeIntervalSince1970: Double(step.createdAt) / 1000))
        }
        // Labels are derived, not stored.
        for i in entries.indices {
            entries[i].label = i == 0 ? "Original"
                : EditHistory.describeChange(from: entries[i - 1].stack, to: entries[i].stack)
        }
        let current = EditStack(parameters: parameters)
        if entries.isEmpty { entries = [EditHistory.Step(stack: EditStack(parameters: defaultParameters), label: "Original")] }
        var h = EditHistory(steps: entries, cursor: entries.count - 1)
        h.record(current)
        history = h
        snapshots = stored.compactMap { s in
            (try? EditStack.decode(json: s.stackJSON)).map { EditSnapshot(name: s.name, stack: $0) }
        }
    }

    /// Called when an edit settles: records a step and persists.
    private func recordHistoryStep() {
        guard !restoringState else { return }
        if history.record(EditStack(parameters: parameters)) { persistHistory() }
    }

    private func persistHistory() {
        guard let id = catalogImageID else { return }
        let steps = history.steps.compactMap { step -> (String, Int64)? in
            guard let json = try? step.stack.encodeJSON() else { return nil }
            return (json, Int64(step.date.timeIntervalSince1970 * 1000))
        }
        onHistoryChanged?(id, steps)
    }

    private func restore(_ stack: EditStack) {
        restoringState = true
        var next = stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        parameters = next
        restoringState = false
        // The stored edit must follow the cursor, so save without waiting.
        pendingSave?.cancel(); pendingSave = nil
        if let id = catalogImageID {
            let isDefault = EditStack.isDefault(parameters, relativeTo: defaultParameters)
            do {
                onEditSettled?(id, isDefault ? nil : try EditStack(parameters: parameters).encodeJSON())
            } catch {
                reportFailure("Encoding the edit", error)
            }
        }
        persistHistory()
    }

    func undo() { if let stack = history.undo() { restore(stack) } }
    func redo() { if let stack = history.redo() { restore(stack) } }
    func jumpToHistory(index: Int) { if let stack = history.jump(to: index) { restore(stack) } }

    func saveSnapshot(named name: String) {
        guard hasImage, !name.isEmpty else { return }
        snapshots.removeAll { $0.name == name }
        snapshots.append(EditSnapshot(name: name, stack: EditStack(parameters: parameters)))
        snapshots.sort { $0.name.lowercased() < $1.name.lowercased() }
        persistSnapshots()
        status = "Saved snapshot “\(name)”"
    }

    func restoreSnapshot(_ snapshot: EditSnapshot) {
        guard hasImage else { return }
        restoringState = true
        var next = snapshot.stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        parameters = next
        restoringState = false
        recordHistoryStep()   // restoring a snapshot is itself a history step
        scheduleSave()
    }

    func deleteSnapshot(_ snapshot: EditSnapshot) {
        snapshots.removeAll { $0.name == snapshot.name }
        persistSnapshots()
    }

    private func persistSnapshots() {
        guard let id = catalogImageID else { return }
        onSnapshotsChanged?(id, snapshots.compactMap { s in
            (try? s.stack.encodeJSON()).map { (s.name, $0) }
        })
    }

    // MARK: - Before / after

    /// While held, the image renders with its defaults so the edit can be
    /// judged against the starting point. Display state, never saved.
    @Published var showingBefore = false {
        didSet { if showingBefore != oldValue { rerender() } }
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


/// CGImage is immutable but not marked Sendable; this vouches for it.
private struct SendableImage: @unchecked Sendable { let cgImage: CGImage }
