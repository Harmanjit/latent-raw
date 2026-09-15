import PixelEngine
import MLKit

extension EditorModel {
    // MARK: - Memory pressure

    func watchMemoryPressure() {
        memoryPressureMonitor = MemoryPressureMonitor { [weak self] level in
            self?.releaseMemory(for: level)
        }
    }

    /// Gives back what can be rebuilt when macOS runs short of memory.
    ///
    /// Warning: the session's pooled textures and demosaic cache (one render
    /// to rebuild), the shared Core ML models (they reload from compiled
    /// copies on disk), and the SAM 2 image encoding unless click-to-select
    /// is in use. Critical adds the encoding regardless, brush mask rasters
    /// and the neural denoise result, which takes about 11 s to recompute.
    /// The layers on screen keep their own textures, so the picture doesn't
    /// change and nothing re-renders until the user acts.
    func releaseMemory(for level: MemoryPressureLevel) {
        guard level >= .warning else {
            if aiDenoiseReleasedUnderPressure {
                aiDenoiseReleasedUnderPressure = false
                regenerateAIDenoiseIfNeeded()
            }
            return
        }
        if isOffScreen {
            closeImage()
            return
        }
        // Dropping these caches never disturbs work in flight: a running
        // denoise or encode holds its own reference to the model.
        Self.sharedDenoisers.removeAll()
        SAM2Models.shared.release()
        SegmentationModel.shared.release()
        if level == .critical || maskTool != .prompt {
            sam2Session = nil
        }
        // The denoise worker renders from this session off the main thread
        // when it starts, so its pool is left alone until the run is done.
        guard let session, !aiDenoiseRunning else { return }
        if session.releaseMemory(for: level) {
            aiDenoiseReleasedUnderPressure = true
            if parameters.aiDenoise > 0 {
                status = "Memory is low: AI denoise will run again when memory recovers"
            }
        }
    }

    /// Lets go of the open image and everything built from it, saving a
    /// pending edit first. Used for a pane nobody is looking at, and when
    /// another folder opens: the catalog id belongs to the catalog being
    /// left, and the same id in the next one is a different photo, so once
    /// the save is on its way nothing may be saved under that id again.
    /// Opening an image starts afresh.
    func closeImage() {
        guard hasImage else { return }
        flushPendingSave()
        disarmTools()
        pendingRender?.cancel()
        aiDenoiseTask?.cancel()
        aiDenoiseRunning = false
        aiDenoiseStatus = ""
        aiDenoiseReleasedUnderPressure = false
        sam2Encoding?.cancel()
        sam2Encoding = nil
        sam2Session = nil
        sam2Status = ""
        session = nil
        sourceURL = nil
        catalogImageID = nil
        preview = nil
        tile = nil
        previewQuads = 0
        tileSize = .zero
        analysisTexture = nil
        histogram = nil
        waveform = nil
        vectorscope = nil
        imageTitle = nil
        history = EditHistory(initial: EditStack(parameters: parameters))
        snapshots = []
        status = "Open a raw file to begin"
    }
}
