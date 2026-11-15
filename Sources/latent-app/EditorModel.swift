import Foundation
import Combine
import Metal
import SwiftUI
import RawCore
import ColorKit
import PixelEngine
import LensKit
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
@Observable
final class EditorModel {
    var parameters = EditParameters() {
        didSet {
            parametersSubject.send(parameters)
            if parameters != oldValue {
                // Undo, Reset All or a paste can take the selected mask
                // away; a selection past the end would have the mask
                // panel's parts read a mask that isn't there.
                if let i = selectedLocalIndex, i >= parameters.locals.count { selectedLocalIndex = nil }
                if parameters.crop != oldValue.crop { canvasDidChange() }
                // An open renders once, itself, when everything is in place.
                if !applyingOpenedImage {
                    // An edit: the high-quality preview waits for it to settle.
                    highQualityPreviewFollowsOpen = false
                    rerender()
                }
                scheduleSave()
                touchUpParametersDidChange(from: oldValue)
                modelMaskParametersDidChange(from: oldValue)
                lensBlurParametersDidChange(from: oldValue)
                reflectionParametersDidChange(from: oldValue)
            }
        }
    }

    // MARK: - Neural denoise

    var aiDenoiseStatus = ""
    var aiDenoiseRunning = false { didSet { aiDenoiseRunningSubject.send(aiDenoiseRunning) } }
    @ObservationIgnored var aiDenoiseTask: Task<Void, Never>?
    /// Numbers the runs, so only the current one may report back.
    @ObservationIgnored var aiDenoiseRun = 0
    static var sharedDenoisers: [AIDenoiser.Variant: AIDenoiser] = [:]

    /// Which network to use. Changing it drops the cached result and, if
    /// the strength is up, runs the new one.
    var aiDenoiseVariant: AIDenoiser.Variant = AIDenoiser.preferredVariant {
        didSet {
            guard aiDenoiseVariant != oldValue else { return }
            AIDenoiser.preferredVariant = aiDenoiseVariant
            stopAIDenoise()
            session?.setAIDenoised(nil, model: nil)
            if parameters.aiDenoise > 0 { runAIDenoise() } else { rerender() }
        }
    }

    // MARK: - Spot removal tool

    /// Click a spot to heal it (the source is picked beside it); drag from
    /// a spot to choose the source yourself; drag either circle of an
    /// existing patch to move it.
    var healToolActive = false {
        didSet {
            guard healToolActive != oldValue else { return }
            if healToolActive {
                cropToolActive = false; maskTool = .none; redEyeToolActive = false; toneTool = .none
                dustToolActive = false; touchUpToolActive = false
            } else {
                selectedHealIndex = nil
                healPinSelection = []
            }
        }
    }
    var selectedHealIndex: Int?
    /// Patches selected alongside `selectedHealIndex` (Select All, ⌘-click
    /// in the pin list), deleted with it (RemoveToolPins.swift).
    var healPinSelection: Set<UUID> = []
    /// The Option-drag marquee in progress, screen points; spots inside it
    /// are deleted when the mouse is let go.
    var healMarquee: CGRect?
    /// When the tool's pins are drawn: Lightroom's Tool Overlay setting.
    var healToolOverlay: HealToolOverlay = .saved {
        didSet { if healToolOverlay != oldValue { healToolOverlay.save() } }
    }
    /// Whether the pointer is over the image, for Tool Overlay's Auto.
    var pointerOverImage = false
    /// Defaults for the next patch; editing a selected patch updates these too.
    var healRadius: Float = 0.02
    var healFeather: Float = 0.35
    var healMode: HealPatch.Mode = .heal
    /// Opacity of the next patch, 0…1.
    var healOpacity: Float = 1

    enum HealDrag {
        case placing(Int), movingTarget(Int, SIMD2<Float>), movingSource(Int, SIMD2<Float>), painting
        /// An Option-drag from this screen point: the delete marquee.
        case marquee(CGPoint)
    }
    @ObservationIgnored var healDrag: HealDrag?
    /// Whether a drag on empty image paints a stroke instead of placing a circle.
    var healShape: HealShape = .spot
    /// The stroke being painted, in normalized sensor coordinates. Drawn by
    /// the overlay and committed as one patch when the drag ends, so the
    /// image isn't re-rendered for every mouse move.
    var paintingHealStroke: [SIMD2<Float>] = []

    // MARK: - Point Colour picker (EditorModel+Colour.swift)

    /// Armed by Point Colour's Pick button: the next click on the image
    /// adds a swatch. Takes that click before any other tool.
    var pointColourPicking = false
    /// The Point Colour swatch whose sliders the panel shows.
    var selectedPointColour: Int?
    /// The mask a pick adds its swatch to, or nil for the global panel.
    var pointColourPickLocal: UUID?

    // MARK: - Content-aware Remove (EditorModel+Remove.swift)

    /// Whether a new Remove patch is refined to the outline of the object
    /// under it (Detect Objects).
    var removeDetectsObjects = true
    /// Remove patches whose object is being detected, by id.
    var detectingObjectIDs: Set<UUID> = []

    // MARK: - Red-eye tool (EditorModel+RedEye.swift)

    var redEyeToolActive = false {
        didSet {
            guard redEyeToolActive != oldValue else { return }
            if redEyeToolActive {
                cropToolActive = false; maskTool = .none; healToolActive = false; toneTool = .none
                dustToolActive = false; touchUpToolActive = false
            } else {
                selectedRedEyeIndex = nil
            }
        }
    }
    var selectedRedEyeIndex: Int?
    /// Default size of the next spot; editing a selected spot updates it too.
    var redEyeRadius: Float = RedEyeSpot.defaultRadius
    var detectingRedEyes = false
    /// Red Eye or Pet Eye for the next spot (EditorModel+PetEye.swift).
    var redEyeKind: RedEyeSpot.Kind = .human
    /// Whether a new Pet Eye spot gets a catchlight.
    var petEyeCatchlight = true
    @ObservationIgnored var redEyeDrag: RedEyeDrag?

    // MARK: - Sensor dust (EditorModel+Dust.swift)

    /// Shows the dust spots as rings: click a ring to remove a false one,
    /// click the image to add one. Arming it disarms every other on-image
    /// tool, as they disarm it.
    var dustToolActive = false {
        didSet {
            guard dustToolActive != oldValue else { return }
            if dustToolActive {
                healToolActive = false; redEyeToolActive = false; cropToolActive = false; maskTool = .none
                touchUpToolActive = false; toneTool = .none
            } else {
                selectedDustIndex = nil
                dustToolDidDisarm()
            }
        }
    }
    /// Find Spots is looking for dust.
    var findingDust = false
    var dustSensitivity = 50
    var dustSize: DustSpotSize = .medium
    /// The Visualise Spots pass over the viewport (never exports).
    var visualiseSpots = false {
        didSet { if visualiseSpots != oldValue { rerender() } }
    }
    var visualiseThreshold: Float = 0.5 {
        didSet { if visualiseSpots, visualiseThreshold != oldValue { rerender() } }
    }
    var selectedDustIndex: Int?
    /// The map Find Spots detected on, kept so the sensitivity and size
    /// controls re-detect without another render. Dropped on image change,
    /// on disarm and at memory warning.
    @ObservationIgnored var dustAnalysis: DustDetector.Analysis?

    // MARK: - Touch-up (EditorModel+TouchUp.swift)

    /// Shows the enabled faces' boxes and a ring per blemish: click a ring
    /// to keep that spot, click skin to add one. Same exclusivity as the
    /// dust tool.
    var touchUpToolActive = false {
        didSet {
            guard touchUpToolActive != oldValue else { return }
            if touchUpToolActive {
                healToolActive = false; redEyeToolActive = false; cropToolActive = false; maskTool = .none
                dustToolActive = false; toneTool = .none
            } else {
                selectedBlemishIndex = nil
            }
        }
    }
    var findingFaces = false
    var findingBlemishes = false
    var selectedBlemishIndex: Int?
    /// Show Skin Mask: the skin slice tinted over the image (viewport only).
    var showSkinMask = false {
        didSet { if showSkinMask != oldValue { rerender() } }
    }
    /// Sharpening's Masking preview, shown while the Masking slider is
    /// dragged with Option held (viewport only, never part of the edit).
    var sharpenMaskPreview = false {
        didSet { if sharpenMaskPreview != oldValue { rerender() } }
    }
    /// Option-drag on a Colour Mixer slider: the band whose colours the
    /// viewport keeps while the rest goes grey. Display only.
    var hueIsolationBand: Int? = nil {
        didSet { if hueIsolationBand != oldValue { rerender() } }
    }
    /// Option-drag on a Colour Grading luminance slider: the range (0
    /// shadows, 1 midtones, 2 highlights) whose weight the viewport shows
    /// in grey. Display only.
    var gradingRangePreview: Int? = nil {
        didSet { if gradingRangePreview != oldValue { rerender() } }
    }
    /// Where a press with the Exposure eyedropper began and where the
    /// pointer is now, in screen points (ExposurePicker.swift).
    var exposurePickDrag: (start: CGPoint, end: CGPoint)?
    /// The defringe eyedropper is armed: the next click on the image picks
    /// a fringe colour (EditorModel+DetailTools.swift).
    var defringePickerActive = false
    /// Remove Chromatic Aberration is measuring the photo.
    var measuringChromaticAberration = false
    /// What the last measurement or pick found, for the Lens panel.
    var lensToolStatus = ""
    /// Saves or clears the per-lens profile choice in the catalog. Set by
    /// `LensProfileDefaults`; nil without a catalog.
    @ObservationIgnored var onRememberLensProfile: ((_ model: String?, _ key: LensProfileOverrides.Key) -> Void)?
    /// A 40 pt upright thumbnail per face, by the face's id, for the panel.
    var faceThumbnails: [UUID: CGImage] = [:]
    /// "Looking for faces…" and the like, for the panel.
    var touchUpStatus = ""
    /// The mask regeneration under way, if any; a newer one replaces it.
    @ObservationIgnored var touchUpMaskTask: Task<Void, Never>?
    /// Critical pressure took the touch-up masks; build them again once
    /// memory recovers rather than in the middle of the shortage.
    @ObservationIgnored var touchUpReleasedUnderPressure = false
    /// The geometry the masks were built for; a change regenerates them.
    @ObservationIgnored var touchUpGeometryKey: String?

    // MARK: - Lens Blur (EditorModel+LensBlur.swift)

    /// The depth map's job and source, Show Depth and Pick Focus.
    let lensBlurState = LensBlurState()

    // MARK: - Reflections (EditorModel+Reflections.swift)

    let reflectionState = ReflectionState()

    // MARK: - Crop and straighten

    /// While on, the viewport shows the whole (straightened) sensor with
    /// the crop rectangle drawn over it; off, it shows only the crop.
    var cropToolActive = false {
        didSet {
            guard cropToolActive != oldValue else { return }
            if !cropToolActive {
                straightenBase = nil
                geometry.straightenLineArmed = false
            } else {
                healToolActive = false; redEyeToolActive = false; dustToolActive = false; touchUpToolActive = false
                toneTool = .none
                geometry.guidedToolActive = false
                // With crop on a mask tool is inert, so it must not stay
                // shown as armed either.
                maskTool = .none
            }
            canvasDidChange()
            rerenderForViewport()
        }
    }
    /// The crop as it was before the straighten slider started moving, so
    /// turning the angle back re-grows the crop instead of leaving it at
    /// whatever the largest angle forced it to.
    @ObservationIgnored var straightenBase: CropParameters?
    /// Upright, Guided Upright and the straighten ruler (EditorModel+Geometry.swift).
    var geometry = GeometryToolState()

    // MARK: - Saving

    /// The catalog id of the open image, when it came from a catalog.
    /// Captured into each pending save, so a save that fires after the
    /// user has moved on still lands on the right image.
    var catalogImageID: Int64?
    /// The catalog id of an open image whose stored edit (or a stored
    /// history step or snapshot) was written by a newer Latent. This build
    /// can't read it, and every save rebuilds the stack from parameters in
    /// this build's format, so saving would erase the newer edit. Edits to
    /// that image are shown but never written back.
    @ObservationIgnored var newerEditImageID: Int64?
    /// True while the open image's stored edit must not be overwritten.
    var storedEditIsReadOnly: Bool { catalogImageID != nil && catalogImageID == newerEditImageID }
    /// The fresh parameters for this image (as-shot white balance and so
    /// on). A stack equal to these is "no edit" and isn't stored.
    var defaultParameters = EditParameters()
    @ObservationIgnored var pendingSave: Task<Void, Never>?

    /// Called with the edit to persist, or nil when the image is back to
    /// defaults. The library owns the actual write. Set by ContentView.
    @ObservationIgnored var onEditSettled: ((_ imageID: Int64, _ editStackJSON: String?) -> Void)?
    /// Called, just before `onEditSettled`, with the thumbnail of a settled
    /// edit rendered from the open session (`offerSettledThumbnail`). Set by
    /// ContentView.
    @ObservationIgnored var onSettledThumbnail: ((_ imageID: Int64, _ editStackJSON: String, _ image: CGImage) -> Void)?

    // MARK: - Rendered result and status

    /// The whole image at preview resolution. Always drawn, so the view is
    /// never empty however far the user pans or zooms mid-gesture.
    var preview: PresentLayer? { didSet { previewSubject.send(preview) } }
    /// A full-resolution render of (a margin around) the visible area,
    /// drawn on top of the preview when zoomed in close enough to need it.
    var tile: PresentLayer? { didSet { tileSubject.send(tile) } }
    var viewport = ViewportTransform(zoom: 1, center: .zero)
    var histogram: Histogram?
    var waveform: Waveform?
    var vectorscope: Vectorscope?
    /// Only the visible scope is computed (efficiency rule 2). Switching
    /// re-measures the current analysis texture without re-rendering.
    var scope: ScopeKind = .histogram {
        didSet { if scope != oldValue { updateScopes() } }
    }
    var status = "Open a raw file to begin" { didSet { statusSubject.send(status) } }
    var imageTitle: String? { didSet { imageTitleSubject.send(imageTitle) } }
    var lastRenderMs: Double = 0
    /// What the last action rendered, for the status bar: "preview 3016×2016
    /// · 3.1 ms", "tile · demosaic cached · 1.2 ms", or "pan · no render".
    var renderReport = ""

    // MARK: - Export

    /// Export settings persist across exports within a session, so a second
    /// export doesn't mean re-choosing format and quality.
    var exportSettings = ExportSettings()
    var isExporting = false

    // MARK: - Display

    /// Show highlights above paper white using the display's EDR range.
    /// Off means the on-screen image matches what an SDR export will look
    /// like, which is useful for judging a file before exporting it.
    var hdrDisplayEnabled = true {
        didSet { if hdrDisplayEnabled != oldValue { rerender() } }
    }
    /// How far above 1.0 the screen could reach with EDR on (its potential
    /// headroom, which doesn't move with brightness). Exactly 1.0 on an
    /// SDR display, in which case the toggle has nothing to do.
    var displayHeadroom: CGFloat = 1
    /// The Loupe on a second display (SecondaryDisplay.swift), while it
    /// shows: its drawable size in pixels and its screen's potential
    /// headroom. It draws this model's preview, so that is rendered for it too.
    @ObservationIgnored var secondaryDrawableSize: CGSize = .zero
    @ObservationIgnored var secondaryDisplayHeadroom: CGFloat?

    // MARK: - Soft proofing

    var proofEnabled = false { didSet { if proofEnabled != oldValue { rebuildProof() } } }
    /// The last target chosen (SoftProofSettings.swift); proofing itself
    /// starts off.
    var proofTarget: SoftProofTarget = SoftProofTargetStore().restored() {
        didSet { if proofTarget != oldValue { rebuildProof() } }
    }
    var gamutWarning = false { didSet { if gamutWarning != oldValue { rerender() } } }
    var proofStatus = ""
    @ObservationIgnored var proofLUT: SoftProofLUT?
    /// Intent and paper simulation (EditorModel+SoftProof.swift),
    /// remembered between launches.
    var proofOptions = SoftProofOptionsStore().options {
        didSet { if proofOptions != oldValue { SoftProofOptionsStore().options = proofOptions; rebuildProof() } }
    }
    var monitorGamutWarning = false {
        didSet { if monitorGamutWarning != oldValue { rebuildMonitorGamut() } }
    }
    @ObservationIgnored var monitorGamutLUT: SoftProofLUT?
    /// The warning colours and what Before shows while proofing, remembered
    /// between launches (SoftProofSettings.swift).
    var gamutWarningColours = SoftProofSettingsStore().warningColours {
        didSet {
            guard gamutWarningColours != oldValue else { return }
            SoftProofSettingsStore().warningColours = gamutWarningColours
            if proofLUT != nil { rerender() }
        }
    }
    var proofBeforeShowsUnproofed = SoftProofSettingsStore().beforeShowsUnproofed {
        didSet {
            guard proofBeforeShowsUnproofed != oldValue else { return }
            SoftProofSettingsStore().beforeShowsUnproofed = proofBeforeShowsUnproofed
            if proofLUT != nil && showingBefore { rerender() }
        }
    }

    // MARK: - Tone tools (EditorModel+ToneTools.swift)

    /// The White Balance Selector or a Targeted Adjustment Tool, armed on
    /// the image. Arming one disarms the other image tools, and arming any
    /// of those disarms it.
    var toneTool: ToneTool = .none {
        didSet { if toneTool != oldValue { toneToolDidChange() } }
    }
    /// Whether the Tone Curve panel shows points or regions; the curve's
    /// targeted tool adjusts whichever is showing.
    var curveEditorMode: CurveEditorMode = .point
    /// The clipping overlay on the viewport (J). Display only.
    var clipping: ClippingIndicators = []
    /// The last Auto white balance and the image it was for, so the White
    /// Balance menu can go on calling that setting Auto.
    var autoWhiteBalance: (url: URL?, balance: ColorKit.WhiteBalance)?
    @ObservationIgnored var toneToolDrag: ToneToolDrag?
    /// The colour under the pointer, in its own object so moving the
    /// pointer redraws the readout and not the whole window.
    let pixelProbe = PixelProbe()
    /// Colour samples pinned with Option-click, per session.
    let colourSamples = ColourSamples()
    /// The tone equalizer's panel and display state (EditorModel+ToneEqualizer.swift).
    let toneEqualizerState = ToneEqualizerState()

    // MARK: - Local adjustments

    /// `colourSample` is the Colour Range eyedropper; `box` drags a
    /// Select Objects rectangle (EditorModel+MaskComponents.swift).
    enum MaskTool: String, CaseIterable { case none, linear, radial, brush, erase, prompt, colourSample, box, lumaSample }

    var selectedLocalIndex: Int? {
        didSet {
            if selectedLocalIndex != oldValue {
                maskTool = .none
                selectedMaskComponentID = nil
                rerender()
            }
        }
    }
    /// The component of the selected local the mask tools work on; nil
    /// for the local's own shape (EditorModel+MaskComponents.swift).
    var selectedMaskComponentID: UUID? {
        didSet { if selectedMaskComponentID != oldValue { maskTool = .none } }
    }
    /// A Select Objects rectangle being dragged, in normalised output
    /// coordinates, for the overlay; nil otherwise.
    var maskDragBox: CGRect?
    /// A radial drag that began inside the ellipse moves it rather than
    /// drawing a new one: the offset from the centre to the press.
    @ObservationIgnored var radialMoveOffset: SIMD2<Float>?
    /// The last scene-linear analysis render the Colour Range eyedropper
    /// read, kept while the edit outside the masks stays the same.
    @ObservationIgnored var colourSampleCache: ColourSampleCache?
    /// The handle being dragged and the last shape a kept-armed tool
    /// placed (EditorModel+MaskShapes.swift).
    @ObservationIgnored var maskShapeEditing = MaskShapeEditing()
    /// The value a selected Luminance or Channel Range reads under the
    /// pointer, for the readout beside its range; nil off the image.
    var maskRangeProbe: Float?
    /// Multi-sample Pick Range and Colour Range sample points, drawn while
    /// the eyedropper is armed (EditorModel+MaskSampling.swift).
    var maskSampling = MaskSamplingState()
    /// Show Channel: the selected range component's input drawn as a grey.
    var showMaskChannel = false {
        didSet { if showMaskChannel != oldValue { rerender() } }
    }
    var maskTool: MaskTool = .none {
        didSet {
            guard maskTool != .none, maskTool != oldValue else { return }
            // Exclusive like every other pair of on-image tools: the drag
            // dispatch gives heal and red-eye priority, so with either
            // still on a drag would place a patch while the panel says
            // "Placing…".
            healToolActive = false
            redEyeToolActive = false
            cropToolActive = false
            dustToolActive = false
            touchUpToolActive = false
            toneTool = .none
        }
    }
    var showMaskOverlay = false {
        didSet { if showMaskOverlay != oldValue { rerender() } }
    }
    var brushRadius: Float = 0.04    // fraction of the short side
    var brushFeather: Float = 0.5
    var brushFlow: Float = 1.0
    /// The most a brush stroke builds up to, 0.1…1 (Density).
    var brushDensity: Float = 1.0
    /// Auto Mask: new strokes paint only where the picture is like the
    /// colour under the brush (BrushAutoMask.swift).
    var brushAutoMask = false
    @ObservationIgnored var isDraggingMask = false {
        didSet { if isDraggingMask != oldValue { rerender() } }
    }
    @ObservationIgnored var lastDab: SIMD2<Float>?

    /// Names of AI locals whose masks are being generated right now.
    var generatingMasks: Set<UUID> = []
    /// The lens and keystone settings (`touchUpGeometryKey`) each model
    /// mask on the session was made on, by local id. Masks are sampled on
    /// the output grid those settings define, so a change makes them
    /// again (EditorModel+Masks.swift).
    @ObservationIgnored var modelMaskGeometry: [UUID: String] = [:]
    /// The shape (model and prompt points) each model mask on the
    /// session was made, or is being made, for, by local id. The pixels
    /// outlive their local (Undo of a paste removes the local, not the
    /// pixels), so a later local with the same id but another shape is
    /// told apart by this record, not by the edit it replaced.
    @ObservationIgnored var modelMaskShapes: [UUID: MaskShape] = [:]
    /// The rebuild queued after a geometry change, 300 ms after the last.
    @ObservationIgnored var modelMaskGeometryTask: Task<Void, Never>?

    /// Option held during the click: the view passes it through so a
    /// prompt click can mean "exclude this".
    @ObservationIgnored var promptModifierExclude = false

    // MARK: Click-to-select (Segment Anything 2)

    /// The encoded image per click-to-select model, by model id: a mask
    /// made with SAM 2.1 Large clicks against Large's encoding while one
    /// made with Small uses Small's. Encoding is the expensive step
    /// (hundreds of ms, once per image and model); every click after it
    /// is a few milliseconds. Reset in `closeImage` and the failed-open
    /// path (EditorModel+Masks.swift).
    @ObservationIgnored var promptSessions: [String: SAM2Session] = [:]
    @ObservationIgnored var promptEncoding: [String: Task<SAM2Session?, Never>] = [:]
    /// The geometry key each model's encoding was made on: a click
    /// answered against an encoding of another grid lands off target.
    @ObservationIgnored var promptSessionGeometry: [String: String] = [:]
    /// What the mask row says about each model's encoding.
    var promptStatus: [String: String] = [:]

    // MARK: - GPU and the open image

    /// Non-nil when Metal setup failed, in which case nothing else works.
    private(set) var setupError: String?

    // Set once, when the shared GPU context is ready (see init).
    var gpuContext: GPUContext?
    @ObservationIgnored var pipeline: RenderPipeline?
    private var presenterInstance: Presenter?
    @ObservationIgnored var histogramCalculator: HistogramCalculator?
    @ObservationIgnored var scopeCalculator: ScopeCalculator?
    /// The small render the scopes measure. Kept so switching scope
    /// doesn't need a render; replaced on every preview render.
    @ObservationIgnored var analysisTexture: MTLTexture?
    var session: ImageSession?
    var sourceURL: URL?

    /// The camera's own white balance, for the "As Shot" button and for
    /// showing the user where the camera set things.
    var asShotWhiteBalance = ColorKit.WhiteBalance()

    /// The viewport's size in device pixels, reported by the Metal view.
    /// Zero until the view first appears.
    var drawableSize: CGSize = .zero

    /// True until the user zooms. While set, window resizes keep the image
    /// fitted rather than preserving an arbitrary zoom.
    var fitMode = true

    @ObservationIgnored var pendingRender: Task<Void, Never>?
    /// The render that shows a brush mask redrawn off the main thread,
    /// unless an edit renders first (EditorModel+Rendering.swift).
    @ObservationIgnored var brushRedrawRender: Task<Void, Never>?

    /// What the last renders used, so a viewport change can decide whether
    /// anything actually needs re-rendering.
    @ObservationIgnored var previewQuads = 0
    /// Whether the last renders were the cheaper drag-time kind, and when
    /// the full-quality one follows (EditorModel+DragRender.swift).
    @ObservationIgnored var dragRender = DragRenderState()
    /// Screen pixels per point where the main image view is, reported
    /// with its size: a drag renders about one preview pixel per point.
    var viewBackingScale: CGFloat = 2
    @ObservationIgnored var tileSize = CGSize.zero
    /// The part of the tile that heals as the whole frame does, so a pan
    /// may reuse it (`HealPatch.isSelfContained`).
    @ObservationIgnored var tileHealedCoverage = CGRect.null

    /// The press-and-hold magnifier's full-resolution render of the area
    /// under the pointer, and what it was rendered for
    /// (EditorModel+Magnifier.swift).
    var magnifierTile: PresentLayer?
    @ObservationIgnored var magnifierState = MagnifierRenderState()

    /// An image asked for before the GPU was ready, opened when it is.
    @ObservationIgnored var openWhenGPUReady: (() -> Void)?
    /// Numbers the opens and closes. An open whose decode finishes after a
    /// newer open or a close began finds the number moved on and drops its
    /// result, so a stale photo never replaces a newer one
    /// (EditorModel+Opening.swift).
    @ObservationIgnored var openGeneration = 0
    /// The open photo's decode and its neighbours' (RawDecodeCache.swift).
    let decodeCache = RawDecodeCache()
    /// Set while `open` lays the new photo's settings in place: their
    /// didSet must not render, because `open` renders once itself when
    /// everything is in place (plan fix #8).
    @ObservationIgnored var applyingOpenedImage = false
    /// Set by an open, cleared by an edit or the first high-quality
    /// preview: right after an open nothing is being dragged, so the
    /// high-quality preview need not wait for things to settle (plan
    /// fix #10, EditorModel+HighQualityPreview.swift).
    @ObservationIgnored var highQualityPreviewFollowsOpen = false
    /// The camera's embedded JPEG of a photo being opened, shown in Loupe
    /// until the decode and the first render are done (plan fix #18).
    var openingPlaceholder: OpeningPlaceholder? { didSet { openingPlaceholderSubject.send(openingPlaceholder) } }
    /// The catalog id that deferred open is for, and that image's stored
    /// history and snapshots if their read arrived before the GPU did:
    /// they are loaded once the open has happened
    /// (`loadHistory(steps:snapshots:forImage:)`).
    @ObservationIgnored var deferredOpenCatalogImageID: Int64?
    @ObservationIgnored var deferredHistory: (steps: [(stackJSON: String, createdAt: Int64)],
                          snapshots: [(name: String, stackJSON: String)])?

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

    /// Takes the shared context (or its failure) once; later calls, from
    /// the launch task after an open already took it, do nothing.
    func attachGPU(_ built: Result<GPUContext, any Error>) {
        guard gpuContext == nil, setupError == nil else { return }
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
            deferredOpenCatalogImageID = nil
            deferredHistory = nil
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
    var userRotation = 0 { didSet { userRotationSubject.send(userRotation) } }
    /// What's actually shown: camera orientation plus the user's turns.
    var rotation: ImageRotation { cameraRotation.rotated(by: userRotation) }

    /// The image as the user sees it — cropped, straightened and rotated.
    /// Zoom, pan and fit all work in this canvas space; the pipeline
    /// never sees it.
    var imageSize: CGSize { frame.canvasSize }

    // MARK: - Scopes

    @ObservationIgnored var lastScopeMeasurement: ContinuousClock.Instant?
    @ObservationIgnored var pendingScopeMeasurement: Task<Void, Never>?
    /// "Selected Mask Only" scopes measured off the main thread
    /// (EditorModel+MaskedScopes.swift): the one in flight, and a count
    /// every measurement bumps so an overtaken result is dropped.
    @ObservationIgnored var maskedScopeTask: Task<Void, Never>?
    @ObservationIgnored var maskedScopeGeneration = 0

    // MARK: - Compare: linked view

    /// Compare's other pane while Sync is on; ContentView sets it on both.
    /// Every zoom and pan made here is shown there as the same
    /// `RelativeView`, so both panes show the same part of the scene even
    /// when their crops, rotations or pixel sizes differ.
    @ObservationIgnored weak var linkedPane: EditorModel?

    /// Survey's panes while its Sync is on: `linkedPane` for any number of
    /// panes. Each zoom and pan made here reaches every other member.
    @ObservationIgnored weak var linkedGroup: (any LinkedPaneGroup)?

    /// Whether renders measure the scopes. Off for Survey's panes, which
    /// show no histogram, so their renders don't measure one.
    @ObservationIgnored var measuresScopes = true

    /// Set when this pane has just taken the linked pane's view, until the
    /// main queue next turns. Compare's zoom buttons and Z key send each
    /// command to both panes; once the first has carried it over, the copy
    /// arriving here must not apply it again (Z would toggle straight back
    /// to fit, and + would zoom twice).
    @ObservationIgnored var tookLinkedViewThisTurn = false

    // MARK: - Memory pressure

    @ObservationIgnored var memoryPressureMonitor: MemoryPressureMonitor?

    /// True while this model's image isn't on screen (Compare's Select pane
    /// outside Compare). Under pressure such a model closes its image
    /// outright: Compare loads it again on the way back in anyway.
    var isOffScreen = false

    /// Critical pressure took the neural denoise result; run it again once
    /// memory recovers rather than in the middle of the shortage.
    @ObservationIgnored var aiDenoiseReleasedUnderPressure = false

    /// Set on Survey's panes, which take turns: a denoise the image needs
    /// is asked for here rather than started (`SurveyModel`).
    @ObservationIgnored var aiDenoiseTurn: (@MainActor (EditorModel) -> Void)?

    // MARK: - Observation

    /// Bumped when something the views show changes outside the model's
    /// own properties: the session's resolved lens profile, a flat-field
    /// gain map arriving, the Heal tool's remembered defaults. The
    /// properties derived from those read it, so their views draw again.
    var outsideStateRevision = 0

    /// What `$preview` and the like gave while this was an
    /// ObservableObject, for the few that react to a change rather than
    /// draw it: Survey's pane housekeeping, the colour samples, tests.
    /// Each sends the current value on subscribing and then every
    /// assignment, after it is made.
    @ObservationIgnored private let previewSubject = CurrentValueSubject<PresentLayer?, Never>(nil)
    @ObservationIgnored private let tileSubject = CurrentValueSubject<PresentLayer?, Never>(nil)
    @ObservationIgnored private let aiDenoiseRunningSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let openingPlaceholderSubject = CurrentValueSubject<OpeningPlaceholder?, Never>(nil)
    @ObservationIgnored private let statusSubject = CurrentValueSubject<String, Never>("Open a raw file to begin")
    @ObservationIgnored private let lastErrorSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let parametersSubject = CurrentValueSubject<EditParameters, Never>(EditParameters())
    @ObservationIgnored private let imageTitleSubject = CurrentValueSubject<String?, Never>(nil)
    @ObservationIgnored private let userRotationSubject = CurrentValueSubject<Int, Never>(0)
    @ObservationIgnored private let snapshotsSubject = CurrentValueSubject<[EditSnapshot], Never>([])
    @ObservationIgnored private let beforeOverrideSubject = CurrentValueSubject<BeforeOverride?, Never>(nil)
    var previewPublisher: AnyPublisher<PresentLayer?, Never> { previewSubject.eraseToAnyPublisher() }
    var tilePublisher: AnyPublisher<PresentLayer?, Never> { tileSubject.eraseToAnyPublisher() }
    var aiDenoiseRunningPublisher: AnyPublisher<Bool, Never> { aiDenoiseRunningSubject.eraseToAnyPublisher() }
    var openingPlaceholderPublisher: AnyPublisher<OpeningPlaceholder?, Never> { openingPlaceholderSubject.eraseToAnyPublisher() }
    var statusPublisher: AnyPublisher<String, Never> { statusSubject.eraseToAnyPublisher() }
    var lastErrorPublisher: AnyPublisher<String?, Never> { lastErrorSubject.eraseToAnyPublisher() }
    var parametersPublisher: AnyPublisher<EditParameters, Never> { parametersSubject.eraseToAnyPublisher() }
    var imageTitlePublisher: AnyPublisher<String?, Never> { imageTitleSubject.eraseToAnyPublisher() }
    var userRotationPublisher: AnyPublisher<Int, Never> { userRotationSubject.eraseToAnyPublisher() }
    var snapshotsPublisher: AnyPublisher<[EditSnapshot], Never> { snapshotsSubject.eraseToAnyPublisher() }
    var beforeOverridePublisher: AnyPublisher<BeforeOverride?, Never> { beforeOverrideSubject.eraseToAnyPublisher() }

    // MARK: - Errors

    /// Lets other parts of the app put a message in the status bar.
    func reportError(_ message: String) {
        status = message
    }

    /// A failure the user must see: shown in red in the status bar in
    /// every mode until dismissed, and logged with the full error.
    var lastError: String? { didSet { lastErrorSubject.send(lastError) } }

    func reportFailure(_ what: String, _ error: Error) {
        lastError = "\(what) failed: \(error)"
        Log.editor.error("\(what, privacy: .private) failed: \(String(describing: error), privacy: .private)")
    }

    // MARK: - Copy / paste / presets

    /// Groups to carry on the next paste. Persisted so the checklist
    /// remembers what the user usually wants.
    var pasteGroups: Set<EditGroup> = {
        if let raw = UserDefaults.standard.array(forKey: "latent.pasteGroups") as? [String] {
            let groups = Set(raw.compactMap(EditGroup.init(rawValue:)))
            // Saved before Crop's transform was split into its own groups.
            return UserDefaults.standard.bool(forKey: "latent.pasteGroups.transformSplit")
                ? groups : EditGroup.upgradingLegacy(groups)
        }
        return EditGroup.lookGroups
    }() {
        didSet {
            UserDefaults.standard.set(pasteGroups.map(\.rawValue), forKey: "latent.pasteGroups")
            UserDefaults.standard.set(true, forKey: "latent.pasteGroups.transformSplit")
        }
    }

    var presets: [Preset] = PresetStore.load()

    // MARK: - History (undo / redo) and snapshots

    var history = EditHistory(initial: EditStack())
    var snapshots: [EditSnapshot] = [] { didSet { snapshotsSubject.send(snapshots) } }
    /// Set by ContentView so history and snapshots reach the catalog.
    @ObservationIgnored var onHistoryChanged: ((_ imageID: Int64, _ steps: [(stackJSON: String, createdAt: Int64)]) -> Void)?
    @ObservationIgnored var onSnapshotsChanged: ((_ imageID: Int64, _ snapshots: [(name: String, stackJSON: String)]) -> Void)?
    /// True while applying a history/snapshot state so it isn't re-recorded.
    @ObservationIgnored var restoringState = false
    /// Whether the stored history and snapshots of a catalog image have
    /// been read (`loadHistory`). Both are written back as whole lists, so
    /// until they are read, or when reading them failed, writing would
    /// replace the stored ones with the few made since opening.
    @ObservationIgnored var storedHistoryLoaded = false
    /// Stored rows this version cannot decode. They are written back with
    /// the rest rather than deleted by the next save.
    @ObservationIgnored var undecodableHistorySteps: [(stackJSON: String, createdAt: Int64)] = []
    @ObservationIgnored var undecodableSnapshots: [(name: String, stackJSON: String)] = []

    // MARK: - Before / after

    /// While held, the image renders with its defaults so the edit can be
    /// judged against the starting point. Display state, never saved.
    var showingBefore = false {
        didSet { if showingBefore != oldValue { rerender() } }
    }

    /// The Before when it is not the unedited image: set by Copy After to
    /// Before and Swap (EditorModel+BeforeAfter.swift), for one image, for
    /// the session. Never saved.
    var beforeOverride: BeforeOverride? {
        didSet {
            beforeOverrideSubject.send(beforeOverride)
            if showingBefore && beforeOverride != oldValue { rerender() }
        }
    }
}
