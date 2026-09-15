import SwiftUI
import AppKit
import Metal
import QuartzCore
import PixelEngine

/// The image viewport: a CAMetalLayer-backed NSView bridged into SwiftUI.
///
/// AppKit rather than SwiftUI because SwiftUI has no way to hand you a
/// CAMetalLayer and control exactly when it draws. That control is the
/// whole point here — the layer redraws only when there's a new texture,
/// a new transform, the window resizes or the screen's headroom moves, at
/// most once per screen refresh, and never on a timer (DESIGN.md
/// efficiency rule 4: zero cost when idle).
///
/// The view deliberately knows nothing about images. It turns raw AppKit
/// events into three intents — zoom by a factor about a point, pan by a
/// delta, double-click at a point — and hands them to the model, which
/// owns the transform and does the clamping. The view then draws whatever
/// texture, coverage and transform it's told to. Keeping the maths out of
/// here means it's testable in PixelEngine without a window.
struct MetalImageView: NSViewRepresentable {
    let preview: PresentLayer
    let tile: PresentLayer?
    let transform: ViewportTransform
    /// Crop, straighten and rotation: how canvas pixels reach the sensor.
    let frame: CropFrame
    let presenter: Presenter
    let device: MTLDevice

    /// Drawable size in device pixels changed.
    let onResize: (CGSize) -> Void
    /// The screen's potential EDR headroom changed, which in practice means
    /// the view moved to another display. 1.0 means an ordinary SDR screen.
    /// The current headroom, which follows the brightness slider, never
    /// comes through here: the view reads it for every frame and fits the
    /// image to it, so brightness costs a present, not a render.
    let onHeadroomChange: (CGFloat) -> Void
    /// Grey level for the surround, in the drawable's own encoding.
    let backgroundLevel: Float
    /// Pinch or option-scroll: multiply zoom by `factor`, keeping the
    /// content under `screenPoint` (device pixels, top-left origin) still.
    let onZoom: (_ factor: CGFloat, _ screenPoint: CGPoint) -> Void
    /// Scroll or drag: move the content by this many device pixels.
    let onPan: (CGSize) -> Void
    let onDoubleClick: (CGPoint) -> Void
    /// When true, drags shape a mask instead of panning.
    let toolActive: Bool
    /// Second argument: whether Option was held (exclude for prompts).
    let onToolBegan: (CGPoint, Bool) -> Void
    let onToolMoved: (CGPoint) -> Void
    let onToolEnded: () -> Void

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        view.configure(device: device, presenter: presenter)
        view.onResize = onResize
        view.onHeadroomChange = onHeadroomChange
        view.onZoom = onZoom
        view.onPan = onPan
        view.onDoubleClick = onDoubleClick
        view.onToolBegan = onToolBegan
        view.onToolMoved = onToolMoved
        view.onToolEnded = onToolEnded
        return view
    }

    func updateNSView(_ view: MetalLayerView, context: Context) {
        view.backgroundLevel = backgroundLevel
        view.toolActive = toolActive
        view.display(preview: preview, tile: tile, transform: transform, frame: frame)
    }
}

/// Everything a presented frame depends on. A frame that would come out
/// identical to the one on screen is skipped, which is most of them:
/// SwiftUI calls `updateNSView` for every published change of the model,
/// status text and histogram included.
private struct PresentedFrame: Equatable {
    var preview: UInt64
    var tile: UInt64?
    var transform: ViewportTransform
    var frame: CropFrame
    var backgroundLevel: Float
    var drawableSize: CGSize
    var displayHeadroom: Float
}

final class MetalLayerView: NSView {
    private var metalLayer: CAMetalLayer!
    private var presenter: Presenter?

    private var currentPreview: PresentLayer?
    private var currentTile: PresentLayer?
    private var currentTransform = ViewportTransform(zoom: 1, center: .zero)
    private var currentFrame = CropFrame(sensorSize: .zero)
    private var lastReportedSize: CGSize = .zero
    private var lastReportedHeadroom: CGFloat = 0
    var backgroundLevel: Float = 0.12 {
        didSet { if backgroundLevel != oldValue { setNeedsRedraw() } }
    }

    /// Fires with the screen's refresh while there is a frame to draw, and
    /// is paused the rest of the time, so several changes in one refresh
    /// cost one present and an idle viewport costs nothing.
    private var displayLink: CADisplayLink?
    private var needsRedraw = false
    /// What the frame on screen was drawn from.
    private var presented: PresentedFrame?

    var onResize: ((CGSize) -> Void)?
    var onHeadroomChange: ((CGFloat) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?
    var toolActive = false
    var onToolBegan: ((CGPoint, Bool) -> Void)?
    var onToolMoved: ((CGPoint) -> Void)?
    var onToolEnded: (() -> Void)?

    /// Top-left origin, like the Metal drawable. Without this AppKit puts
    /// (0,0) at the bottom-left and every y coordinate would need
    /// flipping before it could be compared with the render.
    override var isFlipped: Bool { true }

    func configure(device: MTLDevice, presenter: Presenter) {
        self.presenter = presenter

        wantsLayer = true
        let layer = CAMetalLayer()
        layer.device = device
        // EDR surface (DESIGN.md §8.3): half-float pixels in extended
        // linear Display P3. "Extended" means components may exceed 1.0;
        // on an HDR-capable screen the compositor shows those as brighter
        // than paper white instead of clipping. On an SDR screen it just
        // clips, and nothing else changes. EDR itself starts off and is
        // turned on only while it's needed (updateDynamicRange).
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = false
        // The present kernel writes to the drawable from a compute shader,
        // which framebufferOnly would forbid.
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.needsDisplayOnBoundsChange = true
        self.layer = layer
        self.metalLayer = layer

        // Posted for new screens and resolutions, and for every step of an
        // EDR headroom change: the brightness slider, and the ramp after
        // EDR content first appears. Another app's EDR video posts it too,
        // which the frame comparison turns into no work at all.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Screen and size

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        reportHeadroom()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeScreenNotification, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The display link retains its target, so it must not outlive the
        // window: that would keep the view alive forever.
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSWindow.didChangeScreenNotification, object: window)
        // An NSView display link follows the view to whichever screen it's
        // on, so it ticks at that screen's refresh rate.
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        reportHeadroom()
        setNeedsRedraw()
    }

    @objc private func screenParametersChanged() {
        reportHeadroom()
        setNeedsRedraw()
    }

    /// Tells the model how far the screen could reach above paper white,
    /// which is what the pipeline renders to. Unlike the current headroom
    /// it doesn't wait for EDR to be switched on, and doesn't move with
    /// brightness, so this only fires when the view changes screens.
    private func reportHeadroom() {
        guard let screen = window?.screen else { return }
        let headroom = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        guard headroom != lastReportedHeadroom else { return }
        lastReportedHeadroom = headroom
        DispatchQueue.main.async { [weak self] in self?.onHeadroomChange?(headroom) }
    }

    /// EDR on while the image on screen was rendered with room above white
    /// and the screen can show some of it; off otherwise, since EDR raises
    /// the backlight and costs power. HDR display switched off, soft
    /// proofing and SDR screens all render to headroom 1, so they all end
    /// up here with EDR off.
    private func updateDynamicRange() {
        guard let metalLayer else { return }
        let content = max(currentPreview?.headroom ?? 1, currentTile?.headroom ?? 1)
        let potential = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let wanted = DisplayHeadroom.wantsExtendedDynamicRange(contentHeadroom: content, potential: potential)
        if metalLayer.wantsExtendedDynamicRangeContent != wanted {
            metalLayer.wantsExtendedDynamicRangeContent = wanted
        }
    }

    /// What the screen shows above paper white at this moment. Read for
    /// every frame because it follows brightness and the EDR ramp; each
    /// change posts a screen-parameters notification that asks for a frame,
    /// so nothing polls.
    private var presentHeadroom: Float {
        DisplayHeadroom.presented(
            current: window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1,
            extendedDynamicRange: metalLayer?.wantsExtendedDynamicRangeContent ?? false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func updateDrawableSize() {
        guard let metalLayer, window != nil else { return }
        let scale = backingScale
        metalLayer.contentsScale = scale

        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        metalLayer.drawableSize = pixelSize

        if pixelSize != lastReportedSize {
            lastReportedSize = pixelSize
            // setFrameSize runs inside AppKit layout; letting the model
            // publish state from there triggers SwiftUI's "modifying state
            // during view update" complaint. Defer one runloop turn.
            let size = pixelSize
            DispatchQueue.main.async { [weak self] in self?.onResize?(size) }
        }
        // Drawn at once rather than on the next refresh: the layer is
        // already showing the old frame stretched to the new size.
        drawIfChanged()
    }

    // MARK: - Drawing

    func display(preview: PresentLayer, tile: PresentLayer?, transform: ViewportTransform,
                 frame: CropFrame) {
        currentPreview = preview
        currentTile = tile
        currentTransform = transform
        currentFrame = frame
        setNeedsRedraw()
    }

    /// Asks for a frame on the next screen refresh.
    private func setNeedsRedraw() {
        needsRedraw = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Pause first: anything that changes during the draw unpauses it.
        link.isPaused = true
        guard needsRedraw else { return }
        needsRedraw = false
        drawIfChanged()
    }

    /// Presents a frame unless it would match the one already on screen.
    private func drawIfChanged() {
        guard let metalLayer, let presenter, let preview = currentPreview, window != nil,
              metalLayer.drawableSize.width > 0 else { return }
        updateDynamicRange()
        let headroom = presentHeadroom
        let wanted = PresentedFrame(preview: preview.generation, tile: currentTile?.generation,
                                    transform: currentTransform, frame: currentFrame,
                                    backgroundLevel: backgroundLevel,
                                    drawableSize: metalLayer.drawableSize,
                                    displayHeadroom: headroom)
        guard wanted != presented, let drawable = metalLayer.nextDrawable() else { return }
        presented = wanted
        presenter.present(base: preview, tile: currentTile,
                          transform: currentTransform, frame: currentFrame,
                          to: drawable, backgroundLevel: backgroundLevel,
                          displayHeadroom: headroom)
        #if DEBUG
        SnapshotHarness.noteDrawable(drawable.texture, presentedBy: self)
        #endif
    }

    // MARK: - Gestures

    /// Event location as device pixels with a top-left origin, which is
    /// the coordinate system ViewportTransform speaks.
    private func screenPoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x * backingScale, y: p.y * backingScale)
    }

    /// Trackpad pinch.
    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, screenPoint(for: event))
    }

    /// Two-finger scroll pans; holding Option turns it into zoom, so a
    /// plain mouse wheel (which can't pinch) still has a way to zoom.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            // Wheel notches are coarse; trackpads report fine deltas.
            let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            let factor = 1 + event.scrollingDeltaY * step
            onZoom?(factor, screenPoint(for: event))
            return
        }
        // Precise deltas (trackpad) are in points; wheel notches aren't,
        // so scale those up to something that feels like a scroll.
        let gain: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        onPan?(CGSize(width: event.scrollingDeltaX * gain * backingScale,
                      height: event.scrollingDeltaY * gain * backingScale))
    }

    override func mouseDown(with event: NSEvent) {
        if toolActive {
            onToolBegan?(screenPoint(for: event), event.modifierFlags.contains(.option))
            return
        }
        if event.clickCount == 2 {
            onDoubleClick?(screenPoint(for: event))
        }
    }

    /// Click-drag pans; the content follows the pointer. With a mask tool
    /// armed, the drag shapes the mask instead.
    override func mouseDragged(with event: NSEvent) {
        if toolActive {
            onToolMoved?(screenPoint(for: event))
            return
        }
        onPan?(CGSize(width: event.deltaX * backingScale,
                      height: event.deltaY * backingScale))
    }

    override func mouseUp(with event: NSEvent) {
        if toolActive { onToolEnded?() }
    }
}
