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
        guard wantsHighQualityPreview, let generation = preview?.generation else { return }
        HighQualityPreviewJobs.pending[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.highQualityPreviewDelay)
            guard !Task.isCancelled else { return }
            HighQualityPreviewJobs.pending[key] = nil
            guard let self, self.wantsHighQualityPreview, self.preview?.generation == generation else { return }
            self.renderHighQualityPreview()
        }
    }

    /// Renders the whole frame at full resolution and puts it in place of
    /// the binned preview, resampled to the size it is shown at.
    func renderHighQualityPreview() {
        guard let session, let pipeline, let current = preview else { return }
        let longEdge = Int((max(sensorSize.width, sensorSize.height) * viewport.zoom).rounded(.up))
        let start = Date()
        do {
            var layer = try HighQualityPreview.render(session, pipeline: pipeline, parameters: renderParameters,
                                                      output: displayOutput, longEdge: longEdge)
            // Raw clipping's mask covers the same sensor area.
            layer.rawClipMask = current.rawClipMask
            preview = layer
            lastRenderMs = Date().timeIntervalSince(start) * 1000
            renderReport = "high quality \(layer.texture.width)×\(layer.texture.height)"
                + String(format: " · %.1f ms", lastRenderMs)
        } catch {
            status = "High quality preview failed: \(error)"
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
