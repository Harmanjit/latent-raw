import SwiftUI
import AppKit
import Metal
import QuartzCore
import PixelEngine

/// The image viewport: a CAMetalLayer-backed NSView bridged into SwiftUI.
///
/// AppKit rather than SwiftUI because SwiftUI has no way to hand you a
/// CAMetalLayer and control exactly when it draws. That control is the
/// whole point here — the layer redraws only when there's a new texture or
/// the window resizes, never on a timer (DESIGN.md efficiency rule 4: zero
/// cost when idle).
struct MetalImageView: NSViewRepresentable {
    let texture: MTLTexture?
    let presenter: Presenter
    let device: MTLDevice
    /// Called when the drawable size changes, so the model can re-render at
    /// the new viewport resolution.
    let onResize: (Int) -> Void

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        view.configure(device: device, presenter: presenter, onResize: onResize)
        return view
    }

    func updateNSView(_ view: MetalLayerView, context: Context) {
        view.display(texture: texture)
    }
}

final class MetalLayerView: NSView {
    private var metalLayer: CAMetalLayer!
    private var presenter: Presenter?
    private var currentTexture: MTLTexture?
    private var onResize: ((Int) -> Void)?
    private var lastReportedLongEdge = 0

    func configure(device: MTLDevice, presenter: Presenter, onResize: @escaping (Int) -> Void) {
        self.presenter = presenter
        self.onResize = onResize

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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer, let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale

        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        metalLayer.drawableSize = pixelSize

        // Report the physical pixel dimension, not points — rendering to
        // point resolution on a Retina display would be visibly soft.
        let longEdge = Int(max(pixelSize.width, pixelSize.height))
        if abs(longEdge - lastReportedLongEdge) > 32 {
            lastReportedLongEdge = longEdge
            onResize?(longEdge)
        }
        redraw()
    }

    func display(texture: MTLTexture?) {
        currentTexture = texture
        redraw()
    }

    private func redraw() {
        guard let metalLayer, let presenter, let texture = currentTexture,
              metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable() else { return }
        presenter.present(texture, to: drawable)
    }
}
