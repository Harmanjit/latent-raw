import Foundation
import PixelEngine

/// What the magnifier's tile was rendered for, and the render queued for it.
struct MagnifierRenderState {
    /// The loupe as the view last reported it; nil while it isn't showing.
    var loupe: ViewerInteraction.Magnifier?
    /// The part of `magnifierTile` that heals as the whole frame does.
    var healedCoverage = CGRect.null
    /// The image and settings the tile shows. A tile from another image, or
    /// from before an edit or a before/after toggle, is never drawn.
    weak var session: ImageSession?
    var parameters: EditParameters?
    /// The size the magnifier pool's textures were made for.
    var poolSize: CGSize?
    var lastRender: ContinuousClock.Instant?
    var pending: Task<Void, Never>?
}

extension EditorModel {
    /// Sensor pixels rendered around the loupe beyond what it shows, so
    /// the pointer can wander a little before another render is needed.
    private static let magnifierMargin: CGFloat = 96
    /// The demosaic's degraded border, trimmed when drawing, as for the tile.
    private static let magnifierInset: CGFloat = 8
    /// At most one magnifier render per this interval while the pointer
    /// moves; each is a few hundred pixels square, a few milliseconds.
    private static let magnifierInterval: Duration = .milliseconds(33)

    /// The view's magnifier appeared or moved (non-nil) or went away (nil).
    /// Renders a full-resolution tile under it when the one on hand no
    /// longer covers it, at most once per `magnifierInterval`; the view
    /// draws the loupe from the base layer meanwhile.
    func magnifierChanged(_ loupe: ViewerInteraction.Magnifier?) {
        guard let loupe, hasImage else {
            endMagnifier()
            return
        }
        magnifierState.loupe = loupe
        guard !magnifierTileCovers(loupe) else { return }
        requestMagnifierRender()
    }

    /// Something the view renders changed: an edit or before/after, but
    /// also the neural denoise result, a model mask or the display output,
    /// which the tile's key doesn't hold. So the tile on hand never stays.
    func refreshMagnifier() {
        guard let loupe = magnifierState.loupe else { return }
        magnifierState.parameters = nil
        guard !magnifierTileCovers(loupe) else { return }
        requestMagnifierRender()
    }

    private func endMagnifier() {
        magnifierState.pending?.cancel()
        magnifierState.session?.releasePooledTextures(in: .magnifier)
        magnifierState = MagnifierRenderState()
        if magnifierTile != nil { magnifierTile = nil }
    }

    /// The sensor area the loupe shows, on the sensor.
    private func loupeSensorRect(_ loupe: ViewerInteraction.Magnifier, clampedToSensor: Bool = true) -> CGRect {
        let canvas = loupe.canvasRect(in: viewport, drawableSize: drawableSize)
        let sensor = frame.sensorRect(fromCanvasRect: canvas)
        return clampedToSensor ? sensor.intersection(CGRect(origin: .zero, size: sensorSize)) : sensor
    }

    private func magnifierTileCovers(_ loupe: ViewerInteraction.Magnifier) -> Bool {
        let needed = loupeSensorRect(loupe)
        // Off the image there is nothing sharper to show.
        guard !needed.isNull, !needed.isEmpty else { return true }
        guard magnifierTile != nil, let session, magnifierState.session === session,
              magnifierState.parameters == renderParameters else { return false }
        return magnifierState.healedCoverage
            .insetBy(dx: Self.magnifierInset, dy: Self.magnifierInset).contains(needed)
    }

    /// Renders now if the last render was long enough ago, else once when
    /// it is; a queued render reads the latest loupe position when it runs,
    /// so a fast-moving pointer costs one render per interval, not one per
    /// event.
    private func requestMagnifierRender() {
        guard magnifierState.pending == nil else { return }
        let clock = ContinuousClock()
        if let last = magnifierState.lastRender, clock.now < last + Self.magnifierInterval {
            let due = last + Self.magnifierInterval
            magnifierState.pending = Task { [weak self] in
                try? await Task.sleep(until: due, clock: clock)
                guard !Task.isCancelled, let self else { return }
                self.magnifierState.pending = nil
                self.renderMagnifierIfNeeded()
            }
        } else {
            renderMagnifierIfNeeded()
        }
    }

    private func renderMagnifierIfNeeded() {
        guard let loupe = magnifierState.loupe, let session, let pipeline,
              !magnifierTileCovers(loupe) else { return }
        // Timed from the end, so slow renders never run back to back.
        defer { magnifierState.lastRender = ContinuousClock().now }
        let parameters = renderParameters
        // As the view's tile: keystone reads from elsewhere in the frame,
        // and a heal patch in view (dust and blemishes included) reads its
        // source and surroundings.
        var view = loupeSensorRect(loupe, clampedToSensor: false)
        if !parameters.perspective.isIdentity {
            view = parameters.perspective.sourceRect(forSensorRect: view, sensorSize: sensorSize)
                .insetBy(dx: -4, dy: -4)
        }
        let withSources = HealPatch.regionIncludingSources(view, patches: parameters.allHealPatches,
                                                           sensorSize: sensorSize)
        let region = ViewerInteraction.Magnifier.tileRegion(covering: withSources, margin: Self.magnifierMargin,
                                                            sensorSize: sensorSize)
        guard region.width > 0, region.height > 0 else { return }
        // Keystone and heals in view change the size as the pointer moves,
        // and every size gets a set of textures of its own: keep only the
        // latest. The magnifier's pool is its own, so none is on screen.
        if magnifierState.session !== session || magnifierState.poolSize != region.size {
            magnifierState.session?.releasePooledTextures(in: .magnifier)
            session.releasePooledTextures(in: .magnifier)
            magnifierState.poolSize = region.size
        }
        do {
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
            let rendered = try session.withTexturePool(.magnifier) {
                try pipeline.render(
                    session,
                    scale: .region(x: Int(region.minX), y: Int(region.minY),
                                   width: Int(region.width), height: Int(region.height)),
                    parameters: parameters, output: displayOutput, info: &info)
            }
            magnifierTile = PresentLayer(texture: rendered, coverage: info.sensorRect,
                                         inset: Self.magnifierInset, headroom: displayOutput.headroom)
            let viewed = view.insetBy(dx: -Self.magnifierMargin, dy: -Self.magnifierMargin)
            magnifierState.healedCoverage = HealPatch.isSelfContained(info.sensorRect,
                                                                      patches: parameters.allHealPatches,
                                                                      sensorSize: sensorSize)
                ? info.sensorRect : info.sensorRect.intersection(viewed)
            magnifierState.session = session
            magnifierState.parameters = parameters
        } catch {
            status = "Magnifier render failed: \(error)"
        }
    }

    // MARK: - Arrow keys

    /// Pans a zoomed-in image by an eighth of the view, for the arrow keys
    /// when Settings has them pan. The content moves the other way, so →
    /// shows more of the right-hand side.
    func panImage(_ direction: KeyCommand.PanDirection) {
        let x = drawableSize.width / 8, y = drawableSize.height / 8
        switch direction {
        case .left: pan(by: CGSize(width: x, height: 0))
        case .right: pan(by: CGSize(width: -x, height: 0))
        case .up: pan(by: CGSize(width: 0, height: y))
        case .down: pan(by: CGSize(width: 0, height: -y))
        }
    }
}
