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
/// a new transform, or the window resizes, never on a timer (DESIGN.md
/// efficiency rule 4: zero cost when idle).
///
/// The view deliberately knows nothing about images. It turns raw AppKit
/// events into three intents — zoom by a factor about a point, pan by a
/// delta, double-click at a point — and hands them to the model, which
/// owns the transform and does the clamping. The view then draws whatever
/// texture, coverage and transform it's told to. Keeping the maths out of
/// here means it's testable in PixelEngine without a window.
struct MetalImageView: NSViewRepresentable {
    let texture: MTLTexture?
    /// Which sensor rectangle `texture` covers.
    let coverage: CGRect
    let transform: ViewportTransform
    let presenter: Presenter
    let device: MTLDevice

    /// Drawable size in device pixels changed.
    let onResize: (CGSize) -> Void
    /// Pinch or option-scroll: multiply zoom by `factor`, keeping the
    /// content under `screenPoint` (device pixels, top-left origin) still.
    let onZoom: (_ factor: CGFloat, _ screenPoint: CGPoint) -> Void
    /// Scroll or drag: move the content by this many device pixels.
    let onPan: (CGSize) -> Void
    let onDoubleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        view.configure(device: device, presenter: presenter)
        view.onResize = onResize
        view.onZoom = onZoom
        view.onPan = onPan
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: MetalLayerView, context: Context) {
        view.display(texture: texture, coverage: coverage, transform: transform)
    }
}

final class MetalLayerView: NSView {
    private var metalLayer: CAMetalLayer!
    private var presenter: Presenter?

    private var currentTexture: MTLTexture?
    private var currentCoverage: CGRect = .zero
    private var currentTransform = ViewportTransform(zoom: 1, center: .zero)
    private var lastReportedSize: CGSize = .zero

    var onResize: ((CGSize) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?

    /// Top-left origin, like the Metal drawable. Without this AppKit puts
    /// (0,0) at the bottom-left and every y coordinate would need
    /// flipping before it could be compared with the render.
    override var isFlipped: Bool { true }

    func configure(device: MTLDevice, presenter: Presenter) {
        self.presenter = presenter

        wantsLayer = true
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // The present kernel writes to the drawable from a compute shader,
        // which framebufferOnly would forbid.
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.needsDisplayOnBoundsChange = true
        self.layer = layer
        self.metalLayer = layer
    }

    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Size

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
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
        redraw()
    }

    // MARK: - Drawing

    func display(texture: MTLTexture?, coverage: CGRect, transform: ViewportTransform) {
        currentTexture = texture
        currentCoverage = coverage
        currentTransform = transform
        redraw()
    }

    private func redraw() {
        guard let metalLayer, let presenter, let texture = currentTexture,
              metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable() else { return }
        presenter.present(texture, covering: currentCoverage,
                          transform: currentTransform, to: drawable)
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
        if event.clickCount == 2 {
            onDoubleClick?(screenPoint(for: event))
        }
    }

    /// Click-drag pans; the content follows the pointer.
    override func mouseDragged(with event: NSEvent) {
        onPan?(CGSize(width: event.deltaX * backingScale,
                      height: event.deltaY * backingScale))
    }
}
