import Foundation
import Metal
import PixelEngine

/// The editor's renders, latest wins (docs/Performance-Plan.md fixes #15
/// and #20).
///
/// The main actor still encodes each render (well under a millisecond: it
/// owns the session, see the ownership rule in PixelEngine's
/// DeferredSubmission.swift) but no longer waits for the GPU. A pass (the
/// preview, the scopes' render and the tile of one edit, say) is committed
/// as one `GPUSubmission`; its completion comes back to the main actor
/// through the command buffers' completed handlers.
///
/// At most one pass per session is in flight. A render asked for meanwhile
/// is noted in `pending`, where requests coalesce: when the pass in flight
/// completes, one pass renders whatever is newest, and the slider values
/// in between are never rendered at all. Layers (`preview`, `tile`) are put
/// in place when a pass is encoded, as before: the presenter draws on the
/// same command queue, so it can only ever sample them after the render
/// has written them. Everything that needs the pixels finished (scopes,
/// the tone equalizer's statistics, the magnifier, the status bar's time,
/// the drag timers, the high-quality preview) runs on completion.
@MainActor
final class EditorRenderQueue {
    /// What is waiting to be rendered once the pass in flight completes.
    struct Work {
        /// An edit render (both layers); its value is whether it is the
        /// drag's draft. The newest request's value wins.
        var edit: Bool?
        /// The edit came through `rerender()`, so its completion restarts
        /// the drag timers (`endEditRender`).
        var countsAsEdit = false
        /// The drag stopped: replace the draft with the full render.
        var settle = false
        /// A zoom, pan or resize: re-render what the view now needs.
        var viewport = false
        /// The high-quality preview, for the preview generation it was
        /// queued for. Dropped when an edit, a view change or a settle
        /// that renders is waiting: that changes the preview, and its
        /// completion queues a new one. A settle with no draft to replace
        /// renders nothing, so the high-quality pass goes ahead.
        var highQuality: UInt64?

        var isEmpty: Bool { edit == nil && !settle && !viewport && highQuality == nil }
    }

    /// What one encoded pass left to do on completion.
    struct Outcome {
        var what: [String] = []
        /// Some render was encoded (a viewport change may need none).
        var didWork = false
        /// A viewport pass ran, so "no render" is worth saying.
        var checkedViewport = false
        /// An edit through `rerender()` ran, as a draft or not.
        var editTick: Bool?
        var previewRendered = false
        var refreshesMagnifier = false
        var schedulesHighQuality = false
        /// The high-quality layer, shown on completion unless overtaken.
        var highQuality: (layer: PresentLayer, generation: UInt64)?
        var failure: String?
    }

    struct InFlight {
        let token: Int
        let session: ImageSession
        let submission: GPUSubmission
        let outcome: Outcome
        let started: ContinuousClock.Instant
        /// Carries an edit through `rerender()` (for `beginEditRender`).
        let countsAsEdit: Bool
    }

    var pending = Work()
    var inFlight: InFlight?
    private(set) var tokens = 0
    var waiters: [CheckedContinuation<Void, Never>] = []

    func nextToken() -> Int {
        tokens &+= 1
        return tokens
    }
}

extension EditorModel {
    // MARK: - Latest-wins render queue

    /// A pass for the open session is still on the GPU. One for a photo
    /// already left doesn't hold the new one's renders back.
    var renderInFlight: Bool {
        guard let pass = renderQueue.inFlight, let session else { return false }
        return pass.session === session
    }

    /// An edit render asked for through `rerender()` is in flight or
    /// waiting: an edit arriving now is part of a drag.
    var editRenderOutstanding: Bool {
        (renderInFlight && renderQueue.inFlight?.countsAsEdit == true) || renderQueue.pending.countsAsEdit
    }

    /// Notes `change` in the work waiting and, unless a pass is in flight,
    /// encodes it now.
    func requestRender(_ change: (inout EditorRenderQueue.Work) -> Void) {
        change(&renderQueue.pending)
        guard !renderInFlight else { return }
        runPendingRenders()
    }

    /// Resolves once nothing is rendering or waiting to render, and every
    /// completed render's results are in place (scopes, status, timers).
    /// For tests and anything else that reads the textures right after
    /// asking for a render.
    func renderSettled() async {
        while true {
            if !renderInFlight {
                renderQueue.inFlight = nil
                if renderQueue.pending.isEmpty { return }
                runPendingRenders()
                continue
            }
            await withCheckedContinuation { renderQueue.waiters.append($0) }
        }
    }

    /// Encodes everything waiting as one pass and sends it to the GPU.
    func runPendingRenders() {
        let work = renderQueue.pending
        renderQueue.pending = EditorRenderQueue.Work()
        guard let session, pipeline != nil, !work.isEmpty else {
            resumeRenderWaiters()
            return
        }
        let started = ContinuousClock.now
        session.defersGPUCompletion = true
        var outcome = EditorRenderQueue.Outcome()
        if let draft = work.edit {
            encodeEditPass(draft: draft, into: &outcome)
            if work.countsAsEdit { outcome.editTick = draft }
        } else if work.settle {
            encodeSettlePass(into: &outcome)
        }
        if work.viewport {
            encodeViewportPass(into: &outcome)
        }
        if let generation = work.highQuality, work.edit == nil, !work.viewport, !outcome.schedulesHighQuality {
            encodeHighQualityPass(generation: generation, into: &outcome)
        }
        guard let submission = session.takeDeferredSubmission() else {
            // Nothing reached the GPU (no render needed, or it failed
            // while encoding): finish at once.
            renderPassDidComplete(outcome, started: started, done: .now, succeeded: true)
            resumeRenderWaiters()
            return
        }
        let token = renderQueue.nextToken()
        renderQueue.inFlight = EditorRenderQueue.InFlight(
            token: token, session: session, submission: submission, outcome: outcome,
            started: started, countsAsEdit: work.countsAsEdit)
        let completion = submission.completion
        Task { [weak self] in
            let done = await completion.wait()
            self?.renderPassFinishedOnGPU(token: token, done: done)
        }
    }

    /// A pass's command buffers have completed: run its readbacks, show
    /// what needs finished pixels, and render whatever came in meanwhile.
    private func renderPassFinishedOnGPU(token: Int, done: ContinuousClock.Instant) {
        // A pass overtaken by a photo change: its session finishes the
        // readbacks itself on its next render, if it has one.
        guard let pass = renderQueue.inFlight, pass.token == token else { return }
        renderQueue.inFlight = nil
        let succeeded = pass.session.finishDeferredWork(pass.submission)
        if pass.session === session {
            renderPassDidComplete(pass.outcome, started: pass.started, done: done, succeeded: succeeded)
        }
        if renderQueue.pending.isEmpty || session == nil {
            renderQueue.pending = EditorRenderQueue.Work()
            resumeRenderWaiters()
        } else {
            runPendingRenders()
        }
    }

    private func resumeRenderWaiters() {
        guard !renderInFlight, renderQueue.pending.isEmpty else { return }
        let waiters = renderQueue.waiters
        renderQueue.waiters = []
        waiters.forEach { $0.resume() }
    }

    /// The finished pass's results that need its pixels.
    private func renderPassDidComplete(_ outcome: EditorRenderQueue.Outcome, started: ContinuousClock.Instant,
                                       done: ContinuousClock.Instant, succeeded: Bool) {
        if let failure = outcome.failure {
            status = failure
        } else if !succeeded {
            status = "Render failed: \(RenderError.commandBufferFailed)"
        }
        // The status bar's time: from the start of encoding until the GPU
        // finished, the time the user waits for the picture.
        let elapsed = done - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        if let hq = outcome.highQuality {
            // Shown only if nothing changed the preview meanwhile and no
            // edit is waiting to (a new edit cancels it). A view change
            // waiting may well need no render, so it doesn't.
            let editWaiting = renderQueue.pending.edit != nil || renderQueue.pending.settle
            if succeeded, preview?.generation == hq.generation, !editWaiting {
                var layer = hq.layer
                // Raw clipping's mask covers the same sensor area.
                layer.rawClipMask = preview?.rawClipMask
                preview = layer
                lastRenderMs = ms
                renderReport = "high quality \(layer.texture.width)×\(layer.texture.height)"
                    + String(format: " · %.1f ms", lastRenderMs)
            }
        } else if outcome.didWork {
            lastRenderMs = ms
            renderReport = outcome.what.joined(separator: " + ") + String(format: " · %.1f ms", lastRenderMs)
        } else if outcome.checkedViewport, outcome.failure == nil {
            renderReport = "view moved · no render"
        }
        if outcome.previewRendered {
            updateScopes()
            toneEqualizerRenderDidFinish()
        }
        if outcome.refreshesMagnifier { refreshMagnifier() }
        if outcome.schedulesHighQuality { scheduleHighQualityPreview() }
        if let wasDragTick = outcome.editTick { endEditRender(wasDragTick: wasDragTick) }
    }
}
