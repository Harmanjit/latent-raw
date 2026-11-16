import Foundation
import PixelEngine

/// The debounced high-quality preview renders, one per editor.
@MainActor
private enum HighQualityPreviewJobs {
    static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
}

extension EditorModel {
    // MARK: - High-quality preview

    /// How long the view must stay still, after an edit, zoom or resize,
    /// before the full-resolution render starts. A slider drag renders the
    /// binned preview on every tick and never waits on this.
    static let highQualityPreviewDelay: Duration = .milliseconds(400)
    /// The wait right after a photo opens (plan fix #10): nothing is being
    /// dragged then, so only long enough for the binned preview to reach
    /// the screen first. It made "selection to sharp" 400 ms longer.
    static let highQualityPreviewDelayAfterOpen: Duration = .milliseconds(20)

    /// The wait before the next high-quality preview: short right after an
    /// open, until an edit or that preview itself.
    var highQualityPreviewWait: Duration {
        highQualityPreviewFollowsOpen ? Self.highQualityPreviewDelayAfterOpen : Self.highQualityPreviewDelay
    }

    /// Whether the fitted view should be replaced by a full-resolution
    /// render: View › High Quality Preview is on, this is the main window's
    /// editor, and the view is zoomed out far enough to be drawn from the
    /// preview alone (zoomed in, the full-resolution tile already is).
    var wantsHighQualityPreview: Bool {
        hasImage && session != nil && drawableSize.width > 0 && !wantsTile
            && ViewingSettings.shared.rendersHighQualityPreview(for: self)
    }

    /// Queues the full-resolution render for when things settle, replacing
    /// any queued before. It is skipped if the preview changed meanwhile:
    /// a newer edit queues its own.
    func scheduleHighQualityPreview() {
        let key = ObjectIdentifier(self)
        HighQualityPreviewJobs.pending[key]?.cancel()
        HighQualityPreviewJobs.pending[key] = nil
        guard wantsHighQualityPreview, let generation = preview?.generation else {
            // Not wanted now (zoomed in, turned off): give back the
            // full-resolution buffers kept between renders.
            session?.releasePooledTextures(in: .highQuality)
            return
        }
        let wait = highQualityPreviewWait
        HighQualityPreviewJobs.pending[key] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            HighQualityPreviewJobs.pending[key] = nil
            guard let self, self.wantsHighQualityPreview, self.preview?.generation == generation else { return }
            self.renderHighQualityPreview()
        }
    }

    /// Renders the whole frame at full resolution and puts it in place of
    /// the binned preview, resampled to the size it is shown at. Queued
    /// like any render and not waited for (EditorModel+RenderQueue.swift):
    /// it is shown once the GPU has finished, unless an edit or view
    /// change came meanwhile. The full-resolution textures and resample
    /// buffers stay between renders (docs/Performance-Plan.md fix #20).
    func renderHighQualityPreview() {
        guard session != nil, pipeline != nil, let current = preview else { return }
        // From here on, changes wait for things to settle again.
        highQualityPreviewFollowsOpen = false
        requestRender { $0.highQuality = current.generation }
    }

    /// The high-quality pass, encoded without waiting for the GPU.
    func encodeHighQualityPass(generation: UInt64, into outcome: inout EditorRenderQueue.Outcome) {
        guard let session, let pipeline, let current = preview, current.generation == generation else { return }
        let longEdge = Int((max(sensorSize.width, sensorSize.height) * viewport.zoom).rounded(.up))
        do {
            let layer = try HighQualityPreview.renderKeepingBuffers(
                session, pipeline: pipeline, parameters: renderParameters, output: displayOutput,
                longEdge: longEdge, avoiding: current.texture)
            outcome.highQuality = (layer, generation)
            outcome.didWork = true
        } catch {
            outcome.failure = "High quality preview failed: \(error)"
        }
    }

    /// View › High Quality Preview changed: render it, or go back to the
    /// binned preview.
    func highQualityPreviewSettingChanged() {
        guard hasImage else { return }
        if ViewingSettings.shared.rendersHighQualityPreview(for: self) {
            scheduleHighQualityPreview()
        } else {
            rerender()
        }
    }
}
