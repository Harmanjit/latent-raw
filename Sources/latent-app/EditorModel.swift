import Foundation
import Metal
import SwiftUI
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
/// Export is far too slow for that and runs on `ExportWorker`, off the
/// main thread with its own session so nothing mutable is shared across
/// the boundary.
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

    @Published var aiDenoiseStatus = ""
    @Published var aiDenoiseRunning = false
    var aiDenoiseTask: Task<Void, Never>?
    /// Numbers the runs, so only the current one may report back.
    var aiDenoiseRun = 0
    static var sharedDenoisers: [AIDenoiser.Variant: AIDenoiser] = [:]

    /// Which network to use. Changing it drops the cached result and, if
    /// the strength is up, runs the new one.
    @Published var aiDenoiseVariant: AIDenoiser.Variant = AIDenoiser.preferredVariant {
        didSet {
            guard aiDenoiseVariant != oldValue else { return }
            AIDenoiser.preferredVariant = aiDenoiseVariant
            stopAIDenoise()
            session?.setAIDenoised(nil, model: nil)
            if parameters.aiDenoise > 0 { runAIDenoise() } else { rerender() }
        }
    }

    // Optional high-quality model: download state.
    @Published var modelDownloadProgress: Double?   // 0…1 while downloading
    @Published var modelDownloadStatus = ""
    @Published var highQualityModelInstalled = OptionalModel.nafnetWidth64.isInstalled
    var modelDownloadTask: Task<Void, Never>?

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

    enum HealDrag { case placing(Int), movingTarget(Int, SIMD2<Float>), movingSource(Int, SIMD2<Float>) }
    var healDrag: HealDrag?

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
    var straightenBase: CropParameters?

    // MARK: - Saving

    /// The catalog id of the open image, when it came from a catalog.
    /// Captured into each pending save, so a save that fires after the
    /// user has moved on still lands on the right image.
    var catalogImageID: Int64?
    /// The fresh parameters for this image (as-shot white balance and so
    /// on). A stack equal to these is "no edit" and isn't stored.
    var defaultParameters = EditParameters()
    var pendingSave: Task<Void, Never>?

    /// Called with the edit to persist, or nil when the image is back to
    /// defaults. The library owns the actual write. Set by ContentView.
    var onEditSettled: ((_ imageID: Int64, _ editStackJSON: String?) -> Void)?

    // MARK: - Rendered result and status

    /// The whole image at preview resolution. Always drawn, so the view is
    /// never empty however far the user pans or zooms mid-gesture.
    @Published var preview: PresentLayer?
    /// A full-resolution render of (a margin around) the visible area,
    /// drawn on top of the preview when zoomed in close enough to need it.
    @Published var tile: PresentLayer?
    @Published var viewport = ViewportTransform(zoom: 1, center: .zero)
    @Published var histogram: Histogram?
    @Published var waveform: Waveform?
    @Published var vectorscope: Vectorscope?
    /// Only the visible scope is computed (efficiency rule 2). Switching
    /// re-measures the current analysis texture without re-rendering.
    @Published var scope: ScopeKind = .histogram {
        didSet { if scope != oldValue { updateScopes() } }
    }
    @Published var status = "Open a raw file to begin"
    @Published var imageTitle: String?
    @Published var lastRenderMs: Double = 0
    /// What the last action rendered, for the status bar: "preview 3016×2016
    /// · 3.1 ms", "tile · demosaic cached · 1.2 ms", or "pan · no render".
    @Published var renderReport = ""

    // MARK: - Export

    /// Export settings persist across exports within a session, so a second
    /// export doesn't mean re-choosing format and quality.
    @Published var exportSettings = ExportSettings()
    @Published var isExporting = false

    // MARK: - Display

    /// Show highlights above paper white using the display's EDR range.
    /// Off means the on-screen image matches what an SDR export will look
    /// like, which is useful for judging a file before exporting it.
    @Published var hdrDisplayEnabled = true {
        didSet { if hdrDisplayEnabled != oldValue { rerender() } }
    }
    /// How far above 1.0 the screen could reach with EDR on (its potential
    /// headroom, which doesn't move with brightness). Exactly 1.0 on an
    /// SDR display, in which case the toggle has nothing to do.
    @Published var displayHeadroom: CGFloat = 1
    /// The Loupe on a second display (SecondaryDisplay.swift), while it
    /// shows: its drawable size in pixels and its screen's potential
    /// headroom. It draws this model's preview, so that is rendered for it too.
    var secondaryDrawableSize: CGSize = .zero
    var secondaryDisplayHeadroom: CGFloat?

    // MARK: - Soft proofing

    @Published var proofEnabled = false { didSet { if proofEnabled != oldValue { rebuildProof() } } }
    @Published var proofTarget: SoftProofTarget = .sRGB { didSet { if proofTarget != oldValue { rebuildProof() } } }
    @Published var gamutWarning = false { didSet { if gamutWarning != oldValue { rerender() } } }
    @Published var proofStatus = ""
    var proofLUT: SoftProofLUT?

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
    var isDraggingMask = false {
        didSet { if isDraggingMask != oldValue { rerender() } }
    }
    var lastDab: SIMD2<Float>?

    /// Names of AI locals whose masks are being generated right now.
    @Published var generatingMasks: Set<UUID> = []

    /// Option held during the click: the view passes it through so a
    /// prompt click can mean "exclude this".
    var promptModifierExclude = false

    // MARK: Click-to-select (Segment Anything 2)

    /// The encoded image for SAM 2, built on first use per image. Encoding
    /// is the expensive step (hundreds of ms); every click after it is a
    /// few milliseconds.
    var sam2Session: SAM2Session?
    var sam2Encoding: Task<SAM2Session?, Never>?
    @Published var sam2Status = ""

    // MARK: - GPU and the open image

    /// Non-nil when Metal setup failed, in which case nothing else works.
    private(set) var setupError: String?

    // Set once, when the shared GPU context is ready (see init).
    var gpuContext: GPUContext?
    var pipeline: RenderPipeline?
    private var presenterInstance: Presenter?
    var histogramCalculator: HistogramCalculator?
    var scopeCalculator: ScopeCalculator?
    /// The small render the scopes measure. Kept so switching scope
    /// doesn't need a render; replaced on every preview render.
    var analysisTexture: MTLTexture?
    var session: ImageSession?
    var sourceURL: URL?

    /// The camera's own white balance, for the "As Shot" button and for
    /// showing the user where the camera set things.
    @Published var asShotWhiteBalance = ColorKit.WhiteBalance()

    /// The viewport's size in device pixels, reported by the Metal view.
    /// Zero until the view first appears.
    var drawableSize: CGSize = .zero

    /// True until the user zooms. While set, window resizes keep the image
    /// fitted rather than preserving an arbitrary zoom.
    var fitMode = true

    var pendingRender: Task<Void, Never>?

    /// What the last renders used, so a viewport change can decide whether
    /// anything actually needs re-rendering.
    var previewQuads = 0
    var tileSize = CGSize.zero
    /// The part of the tile that heals as the whole frame does, so a pan
    /// may reuse it (`HealPatch.isSelfContained`).
    var tileHealedCoverage = CGRect.null

    /// An image asked for before the GPU was ready, opened when it is.
    var openWhenGPUReady: (() -> Void)?

    /// Every model shares the process's one GPU context, built off the
    /// main thread (`GPUContext.shared()`), so the window appears without
    /// waiting for shaders. Once it exists, as for Compare's model or once
    /// a caller has awaited `GPUContext.shared()`, a new model is ready on
    /// return, as before; otherwise it isn't `isReady` for the moment the
    /// build takes, and an image opened meanwhile opens when it's done.
    init() {
        if let built = GPUContext.sharedIfBuilt {
            attachGPU(built)
        } else {
            Task { [weak self] in
                do {
                    let gpu = try await GPUContext.shared()
                    self?.attachGPU(.success(gpu))
                } catch {
                    self?.attachGPU(.failure(error))
                }
            }
        }
    }

    private func attachGPU(_ built: Result<GPUContext, any Error>) {
        objectWillChange.send()
        switch built {
        case .success(let gpu):
            gpuContext = gpu
            pipeline = RenderPipeline(gpu: gpu)
            presenterInstance = Presenter(gpu: gpu)
            histogramCalculator = try? HistogramCalculator(gpu: gpu)
            scopeCalculator = try? ScopeCalculator(gpu: gpu)
            if let open = openWhenGPUReady {
                openWhenGPUReady = nil
                open()
            }
        case .failure(let error):
            setupError = String(describing: error)
            status = "Metal setup failed"
            openWhenGPUReady = nil
        }
        watchMemoryPressure()
    }

    var isReady: Bool { gpuContext != nil }
    var gpu: GPUContext? { gpuContext }
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
    var cameraRotation: ImageRotation = .none
    /// Quarter turns the user added on top (kept in the catalog).
    @Published var userRotation = 0
    /// What's actually shown: camera orientation plus the user's turns.
    var rotation: ImageRotation { cameraRotation.rotated(by: userRotation) }

    /// The image as the user sees it — cropped, straightened and rotated.
    /// Zoom, pan and fit all work in this canvas space; the pipeline
    /// never sees it.
    var imageSize: CGSize { frame.canvasSize }

    // MARK: - Scopes

    var lastScopeMeasurement: ContinuousClock.Instant?
    var pendingScopeMeasurement: Task<Void, Never>?

    // MARK: - Compare: linked view

    /// Compare's other pane while Sync is on; ContentView sets it on both.
    /// Every zoom and pan made here is shown there as the same
    /// `RelativeView`, so both panes show the same part of the scene even
    /// when their crops, rotations or pixel sizes differ.
    weak var linkedPane: EditorModel?

    /// Set when this pane has just taken the linked pane's view, until the
    /// main queue next turns. Compare's zoom buttons and Z key send each
    /// command to both panes; once the first has carried it over, the copy
    /// arriving here must not apply it again (Z would toggle straight back
    /// to fit, and + would zoom twice).
    var tookLinkedViewThisTurn = false

    // MARK: - Memory pressure

    var memoryPressureMonitor: MemoryPressureMonitor?

    /// True while this model's image isn't on screen (Compare's Select pane
    /// outside Compare). Under pressure such a model closes its image
    /// outright: Compare loads it again on the way back in anyway.
    var isOffScreen = false

    /// Critical pressure took the neural denoise result; run it again once
    /// memory recovers rather than in the middle of the shortage.
    var aiDenoiseReleasedUnderPressure = false

    // MARK: - Errors

    /// Lets other parts of the app put a message in the status bar.
    func reportError(_ message: String) {
        status = message
    }

    /// A failure the user must see: shown in red in the status bar in
    /// every mode until dismissed, and logged with the full error.
    @Published var lastError: String?

    func reportFailure(_ what: String, _ error: Error) {
        lastError = "\(what) failed: \(error)"
        Log.editor.error("\(what, privacy: .private) failed: \(String(describing: error), privacy: .private)")
    }

    // MARK: - Copy / paste / presets

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

    @Published var presets: [Preset] = PresetStore.load()

    // MARK: - History (undo / redo) and snapshots

    @Published var history = EditHistory(initial: EditStack())
    @Published var snapshots: [EditSnapshot] = []
    /// Set by ContentView so history and snapshots reach the catalog.
    var onHistoryChanged: ((_ imageID: Int64, _ steps: [(stackJSON: String, createdAt: Int64)]) -> Void)?
    var onSnapshotsChanged: ((_ imageID: Int64, _ snapshots: [(name: String, stackJSON: String)]) -> Void)?
    /// True while applying a history/snapshot state so it isn't re-recorded.
    var restoringState = false

    // MARK: - Before / after

    /// While held, the image renders with its defaults so the edit can be
    /// judged against the starting point. Display state, never saved.
    @Published var showingBefore = false {
        didSet { if showingBefore != oldValue { rerender() } }
    }
}
