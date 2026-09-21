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
    /// to rebuild), every model the registry has loaded (they reload from
    /// compiled copies on disk), and the click-to-select encodings unless
    /// the prompt tool is armed, when only the selected mask's model keeps
    /// its encoding. Critical adds every encoding regardless, brush mask
    /// rasters and the neural denoise result, which takes about 11 s to
    /// recompute. The layers on screen keep their own textures, so the
    /// picture doesn't change and nothing re-renders until the user acts.
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
        ModelRegistry.shared.releaseAll()
        if level == .critical || maskTool != .prompt {
            resetPromptSessions()
        } else {
            resetPromptSessions(keeping: selectedPromptModelID)
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
    /// Opening an image starts afresh. Also runs with no image but an id
    /// still set, so no id outlives the image it belonged to.
    func closeImage() {
        guard hasImage || catalogImageID != nil else { return }
        flushPendingSave()
        disarmTools()
        pendingRender?.cancel()
        stopAIDenoise()
        aiDenoiseReleasedUnderPressure = false
        resetPromptSessions()
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

    /// The model the armed prompt tool clicks against: the selected
    /// click-to-select mask's, resolved as its clicks are.
    private var selectedPromptModelID: String? {
        guard case .prompted(_, let version)? = selectedLocal?.shape else { return nil }
        return promptModelID(for: version)
    }
}
