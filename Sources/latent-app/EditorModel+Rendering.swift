import Foundation
import PixelEngine

extension EditorModel {
    // MARK: - Rendering

    /// Extra sensor pixels rendered beyond each edge of the visible area,
    /// so small pans stay inside the tile and need no render at all. Costs
    /// about 25% more pixels per tile on a laptop-sized window.
    private static let tileMargin: CGFloat = 128
    /// Pixels trimmed from the tile's edge when drawing — the demosaic's
    /// neighbourhood reach, where clamped reads produce colour fringes.
    private static let tileInset: CGFloat = 8

    /// How many quads to bin for the preview at the current zoom. Zoomed
    /// out, the preview is the only layer and should match the screen;
    /// zoomed in, it's the soft backdrop under the tile, and half-size is
    /// plenty.
    private var wantedPreviewQuads: Int {
        // The Loupe on a second display draws the same preview.
        SecondaryPreview.previewQuads(mainZoom: drawableSize.width > 0 ? viewport.zoom : nil,
                                      secondaryZoom: secondaryFitZoom)
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

    /// What the tile is rendered for: the visible area and margin.
    private var tileViewRegion: CGRect {
        var visible = visibleSensorRect.insetBy(dx: -Self.tileMargin, dy: -Self.tileMargin)
        // Keystone reads pixels from elsewhere in the frame; widen the tile
        // to the source region so the corrected view is complete.
        if !parameters.perspective.isIdentity {
            visible = parameters.perspective.sourceRect(forSensorRect: visible, sensorSize: sensorSize)
                .insetBy(dx: -4, dy: -4)
        }
        return visible
    }

    private func wantedTileRegion() -> (x: Int, y: Int, width: Int, height: Int) {
        // A patch on screen must be able to read its source and, for a heal,
        // the surroundings, which may lie outside the visible area: widen
        // the tile to include them.
        let visible = HealPatch.regionIncludingSources(tileViewRegion, patches: parameters.heals, sensorSize: sensorSize)
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
        let usable = tileHealedCoverage.insetBy(dx: Self.tileInset, dy: Self.tileInset)
        // Only the part of the view that's actually over the image matters.
        let sensorBounds = CGRect(origin: .zero, size: sensorSize)
        return usable.contains(visible.intersection(sensorBounds))
    }

    /// Re-renders after a zoom or pan. Cheap when nothing changed: the
    /// preview only re-renders if its bin factor changed, and the tile
    /// only if the view has moved outside it or the zoom changed.
    func rerenderForViewport() {
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
        refreshMagnifier()
    }

    /// Returns a short description of what ran, for the status bar.
    /// What actually renders: the edit, or the defaults while "before"
    /// is held.
    var renderParameters: EditParameters { showingBefore ? defaultParameters : parameters }

    @discardableResult
    private func renderPreview(session: ImageSession, pipeline: RenderPipeline) throws -> String {
        let quads = wantedPreviewQuads
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
        let rendered = try pipeline.render(session, scale: .binned(quads: quads),
                                            parameters: renderParameters, output: displayOutput,
                                            info: &info)
        preview = PresentLayer(texture: rendered, coverage: info.sensorRect,
                               headroom: displayOutput.headroom)
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

    @discardableResult
    private func renderTile(session: ImageSession, pipeline: RenderPipeline,
                            region: (x: Int, y: Int, width: Int, height: Int)) throws -> String {
        var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: true)
        let rendered = try pipeline.render(
            session,
            scale: .region(x: region.x, y: region.y, width: region.width, height: region.height),
            parameters: renderParameters, output: displayOutput, info: &info)
        tile = PresentLayer(texture: rendered, coverage: info.sensorRect, inset: Self.tileInset,
                            headroom: displayOutput.headroom)
        // Past the view region the tile can hold a patch that reads outside
        // it (it wasn't needed for the view), which a pan must not reveal.
        tileHealedCoverage = HealPatch.isSelfContained(info.sensorRect, patches: renderParameters.heals, sensorSize: sensorSize)
            ? info.sensorRect : info.sensorRect.intersection(tileViewRegion)
        return "tile \(rendered.width)×\(rendered.height)" + (info.demosaicWasCached ? " (cached)" : "")
    }
}
