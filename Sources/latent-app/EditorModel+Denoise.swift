import Foundation
import PixelEngine
import MLKit

extension EditorModel {
    // MARK: - Neural denoise

    var aiDenoiseAvailable: Bool { AIDenoiser.isAvailable }
    var hasAIDenoiseResult: Bool { session?.aiDenoisedCameraRGB != nil }

    func downloadHighQualityModel() {
        guard modelDownloadProgress == nil else { return }
        let model = OptionalModel.nafnetWidth64
        modelDownloadProgress = 0
        modelDownloadStatus = "Downloading \(model.title) (\(model.sizeMB) MB)…"
        modelDownloadTask = Task { [weak self] in
            do {
                try await ModelDownloader.install(model) { [weak self] received, expected in
                    Task { @MainActor in
                        self?.modelDownloadProgress = expected > 0 ? Double(received) / Double(expected) : 0
                    }
                }
                self?.modelDownloadProgress = nil
                self?.highQualityModelInstalled = model.isInstalled
                self?.modelDownloadStatus = "Installed. Choose “High quality” above."
            } catch is CancellationError {
                self?.modelDownloadProgress = nil
                self?.modelDownloadStatus = ""
            } catch {
                self?.modelDownloadProgress = nil
                self?.modelDownloadStatus = "\(error)"
            }
        }
    }

    func cancelModelDownload() { modelDownloadTask?.cancel() }

    func removeHighQualityModel() {
        do { try ModelDownloader.remove(.nafnetWidth64) } catch { reportFailure("Removing the model", error) }
        highQualityModelInstalled = OptionalModel.nafnetWidth64.isInstalled
        Self.sharedDenoisers[.high] = nil
        if aiDenoiseVariant == .high { aiDenoiseVariant = .standard }
        modelDownloadStatus = "Removed."
    }

    /// Runs the network over the open image (once; the result lives with
    /// the session) and re-renders. ~12 s for 24 MP on the GPU.
    func runAIDenoise() {
        guard let session, let pipeline, let gpu = gpuContext, !aiDenoiseRunning else { return }
        guard AIDenoiser.isAvailable else {
            aiDenoiseStatus = "NAFNet model not bundled — see Sources/MLKit/Resources/Models/README.md"
            return
        }
        let run = beginAIDenoiseRun()
        aiDenoiseTask = Task { [weak self] in
            do {
                let variant = AIDenoiser.preferredVariant
                let denoiser: AIDenoiser
                if let d = Self.sharedDenoisers[variant] { denoiser = d } else {
                    denoiser = try await AIDenoiser.load(variant)
                    Self.sharedDenoisers[variant] = denoiser
                }
                let seconds = try await AIDenoiseWorker.run(
                    session: session, pipeline: pipeline, gpu: gpu, denoiser: denoiser
                ) { [weak self] done, total in
                    Task { @MainActor in
                        guard self?.aiDenoiseRun == run else { return }
                        self?.aiDenoiseStatus = "Denoising… \(done) of \(total) tiles"
                    }
                }
                let summary = String(format: "Denoised in %.1f s (%@)", seconds, denoiser.variant.displayName)
                guard let model = self, model.endAIDenoiseRun(run, status: summary) else { return }
                if model.parameters.aiDenoise == 0 { model.parameters.aiDenoise = 1 } else { model.rerender() }
            } catch is CancellationError {
                self?.endAIDenoiseRun(run, status: "")
            } catch {
                self?.endAIDenoiseRun(run, status: "Denoise failed: \(error)")
            }
        }
    }

    /// Marks a new run as the current one and returns its number.
    func beginAIDenoiseRun() -> Int {
        aiDenoiseRun += 1
        aiDenoiseRunning = true
        aiDenoiseStatus = "Loading model…"
        return aiDenoiseRun
    }

    /// Ends `run` if it is still the current one, and says whether it was.
    /// A cancelled run only notices at its next tile, by which time
    /// another image may have started its own; clearing the flag then
    /// would let memory pressure release the session that run is reading,
    /// and let a second run start beside it.
    @discardableResult
    func endAIDenoiseRun(_ run: Int, status: String) -> Bool {
        guard run == aiDenoiseRun else { return false }
        aiDenoiseRunning = false
        aiDenoiseStatus = status
        return true
    }

    /// Cancels the current run, if any, and disowns it, so nothing it
    /// reports afterwards lands on the image open by then.
    func stopAIDenoise() {
        aiDenoiseTask?.cancel()
        aiDenoiseRun += 1
        aiDenoiseRunning = false
        aiDenoiseStatus = ""
    }

    func cancelAIDenoise() {
        aiDenoiseTask?.cancel()
    }

    /// A stored edit with denoise on needs the result recomputed on open.
    /// A model that takes turns asks for its turn instead.
    func regenerateAIDenoiseIfNeeded() {
        guard needsAIDenoise else { return }
        if let aiDenoiseTurn { aiDenoiseTurn(self) } else { runAIDenoise() }
    }

    /// Denoise is on with no result, and none is being made.
    var needsAIDenoise: Bool { parameters.aiDenoise > 0 && !hasAIDenoiseResult && !aiDenoiseRunning }

    /// Slider binding: moving it off zero with no result yet starts the run.
    var aiDenoiseStrength: Float {
        get { parameters.aiDenoise }
        set {
            parameters.aiDenoise = newValue
            if newValue > 0 { regenerateAIDenoiseIfNeeded() }
        }
    }
}
