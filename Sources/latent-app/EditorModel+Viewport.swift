import Foundation
import PixelEngine

extension EditorModel {
    // MARK: - Rotation

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

    // MARK: - Viewport

    /// The Metal view's drawable size changed (window resize, or the view
    /// appearing for the first time).
    func viewportDidResize(to size: CGSize) {
        guard size != drawableSize else { return }
        let oldSize = drawableSize
        drawableSize = size
        guard hasImage else { return }
        if fitMode {
            viewport = .fit(imageSize: imageSize, drawableSize: size)
        } else {
            viewport = viewport.clamped(imageSize: imageSize, drawableSize: size)
        }
        // Compare: a pane laid out for the first time joins the other; a
        // zoomed pane that changed size keeps the other lined up with it.
        if oldSize == .zero { joinLinkedPane() } else if !fitMode { carryViewToLinkedPane() }
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
        guard hasImage, !tookLinkedViewThisTurn else { return }
        fitMode = true
        viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)
        rerenderForViewport()
        carryViewToLinkedPane()
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
        guard !tookLinkedViewThisTurn else { return }
        let clamped = proposed.clamped(imageSize: imageSize, drawableSize: drawableSize)
        fitMode = clamped.isFit(imageSize: imageSize, drawableSize: drawableSize)
        guard clamped != viewport else { return }
        viewport = clamped
        scheduleRender()
        carryViewToLinkedPane()
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

    // MARK: - Compare: linked view

    /// This pane's zoom and pan in terms another pane can apply.
    var relativeView: RelativeView {
        RelativeView(transform: viewport, isFit: fitMode, imageSize: imageSize, drawableSize: drawableSize)
    }

    /// Shows `view` of this pane's own image. Never carried back.
    func takeLinkedView(_ view: RelativeView) {
        if !tookLinkedViewThisTurn {
            tookLinkedViewThisTurn = true
            Task { @MainActor [weak self] in self?.tookLinkedViewThisTurn = false }
        }
        show(view)
    }

    private func show(_ view: RelativeView) {
        guard hasImage, drawableSize.width > 0, drawableSize.height > 0 else { return }
        let target = view.transform(imageSize: imageSize, drawableSize: drawableSize)
            .clamped(imageSize: imageSize, drawableSize: drawableSize)
        fitMode = view.isFit || target.isFit(imageSize: imageSize, drawableSize: drawableSize)
        guard target != viewport else { return }
        viewport = target
        scheduleRender()
    }

    private func carryViewToLinkedPane() {
        linkedPane?.takeLinkedView(relativeView)
        if let group = linkedGroup {
            let view = relativeView
            for pane in group.linkedPanes where pane !== self { pane.takeLinkedView(view) }
        }
    }

    /// An image that opens (or is first laid out) while the other pane is
    /// zoomed in joins it, so stepping the candidate keeps the same detail
    /// in view. A fitted pane has nothing to share: images open fitted.
    func joinLinkedPane() {
        let peer = linkedGroup?.linkedPanes.first { $0 !== self && $0.hasImage && !$0.fitMode }
        guard let other = linkedPane ?? peer, other.hasImage, !other.fitMode else { return }
        show(other.relativeView)
    }
}
