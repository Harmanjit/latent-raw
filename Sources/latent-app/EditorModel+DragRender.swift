import Foundation
import PixelEngine

/// What the editor knows about a drag in progress, for the cheaper
/// renders it shows while one lasts (docs/Performance-Plan.md, fixes 3,
/// 4 and 25).
///
/// There is no "drag began / ended" signal from the sliders, so a drag is
/// told by its rhythm: an edit render that follows the previous one
/// within `EditorModel.dragTickWindow` is a drag tick. The first edit of a
/// burst renders at full quality as before; the ticks after it render the
/// draft; once no edit has come for `EditorModel.dragSettleDelay` the
/// full-quality render replaces the draft. Export, thumbnails and the
/// high-quality preview never see any of this.
struct DragRenderState {
    /// When the last edit render finished, nil once a drag has settled.
    var lastEditRender: ContinuousClock.Instant?
    /// The preview on screen is the drag draft: coarser than the view
    /// wants, or with coarse blurs.
    var previewIsDraft = false
    /// The tile on screen was rendered with the drag's coarse blurs.
    var tileIsDraft = false
    /// The full-quality render queued for when the drag stops.
    var settleTask: Task<Void, Never>?
}

extension EditorModel {
    // MARK: - Drag-time renders

    /// Edit renders closer together than this are one drag. A slider tick
    /// comes every 16 ms at 60 Hz, or every 50 ms or so when each render
    /// is slow; a separate click is rarely this quick.
    static let dragTickWindow: Duration = .milliseconds(250)
    /// How long the edits must stop before the full-quality render.
    static let dragSettleDelay: Duration = .milliseconds(150)

    /// Notes an edit render about to run and says whether it is a drag
    /// tick: the previous edit render *finished* less than
    /// `dragTickWindow` ago. Any settle render still waiting is called
    /// off; `endEditRender(wasDragTick:)` queues the next one.
    ///
    /// Both timers run from when a render ends, not when it starts, so a
    /// slow render (a big file at 100% with many heal spots, a slower Mac)
    /// doesn't eat the window: the settle sleep never ends during the
    /// render and wins the main actor ahead of the next slider event.
    func beginEditRender(now: ContinuousClock.Instant = .now) -> Bool {
        let isDragTick = dragRender.lastEditRender.map { now - $0 < Self.dragTickWindow } ?? false
        dragRender.settleTask?.cancel()
        dragRender.settleTask = nil
        return isDragTick
    }

    /// Notes that an edit render just finished: the drag window and, after
    /// a drag tick, the settle delay both start now.
    func endEditRender(wasDragTick: Bool, now: ContinuousClock.Instant = .now) {
        dragRender.lastEditRender = now
        dragRender.settleTask?.cancel()
        dragRender.settleTask = nil
        guard wasDragTick else { return }
        dragRender.settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dragSettleDelay)
            guard !Task.isCancelled, let self else { return }
            self.settleDragRender()
        }
    }

    /// The drag stopped: replace whatever was drawn as a draft with the
    /// full-quality render. Nothing to do when no draft is on screen.
    func settleDragRender() {
        dragRender.settleTask?.cancel()
        dragRender.settleTask = nil
        dragRender.lastEditRender = nil
        guard dragRender.previewIsDraft || dragRender.tileIsDraft else { return }
        guard let session, let pipeline else { return }
        if dragRender.tileIsDraft && wantsTile {
            // Both layers again, as an edit does (not counted as a tick).
            rerender(asDragTick: false)
            return
        }
        let start = Date()
        do {
            let what = try renderPreview(session: session, pipeline: pipeline, draft: false)
            lastRenderMs = Date().timeIntervalSince(start) * 1000
            renderReport = what + String(format: " · %.1f ms", lastRenderMs)
        } catch {
            status = "Render failed: \(error)"
        }
        dragRender.tileIsDraft = false
        scheduleHighQualityPreview()
    }

    /// Renders both layers at full quality and forgets any drag, for a
    /// render that is not an edit (a photo just opened).
    func rerenderAtFullQuality() {
        resetDragRender()
        rerender(asDragTick: false)
    }

    /// Forgets a drag in progress, for a photo being left: the next photo's
    /// first render is never a draft, and no settle render reaches it.
    func resetDragRender() {
        dragRender.settleTask?.cancel()
        dragRender = DragRenderState()
    }

    /// The bin factor for the drag draft of the preview: about one preview
    /// pixel per point of the main view instead of one per screen pixel,
    /// so a quarter of the pixels on a retina screen. The second display's
    /// Loupe, which draws the same preview, keeps its own full size.
    var draftPreviewQuads: Int {
        SecondaryPreview.previewQuads(mainZoom: drawableSize.width > 0 ? viewport.zoom : nil,
                                      secondaryZoom: secondaryFitZoom,
                                      mainPixelsPerPreviewPixel: viewBackingScale)
    }

    /// The bin factor for the preview during a drag at 100% or closer.
    /// There the tile covers the whole view and the preview is only the
    /// backdrop behind it, seen for a moment at the edges of a fast pan:
    /// it renders at the scopes' size, and that one render serves both.
    /// The second display's Loupe, when open, still gets its own size.
    var draftBackdropQuads: Int {
        if let secondary = secondaryFitZoom {
            return SecondaryPreview.previewQuads(mainZoom: nil, secondaryZoom: secondary)
        }
        return max(wantedPreviewQuads, Self.analysisQuads)
    }

    /// What a render on screen asks for: the display's output, with the
    /// coarse blurs on a drag tick when the edit has any to coarsen
    /// (fix 25), so a render that would come out the same isn't later
    /// redone as "settling".
    func draftOutput(_ draft: Bool) -> RenderOutput {
        var output = displayOutput
        output.coarseBlurs = draft && RenderPipeline.coarseBlursApply(to: renderParameters)
        return output
    }
}
