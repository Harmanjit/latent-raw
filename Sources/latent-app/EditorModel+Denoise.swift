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
        aiDenoiseRunning = true
        aiDenoiseStatus = "Loading model…"
        let imageID = catalogImageID
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
                        self?.aiDenoiseStatus = "Denoising… \(done) of \(total) tiles"
                    }
                }
                guard let model = self, model.catalogImageID == imageID || model.session === session else { return }
                model.aiDenoiseStatus = String(format: "Denoised in %.1f s (%@)", seconds, denoiser.variant.displayName)
                model.aiDenoiseRunning = false
                if model.parameters.aiDenoise == 0 { model.parameters.aiDenoise = 1 } else { model.rerender() }
            } catch is CancellationError {
                self?.aiDenoiseRunning = false
                self?.aiDenoiseStatus = ""
            } catch {
                self?.aiDenoiseRunning = false
                self?.aiDenoiseStatus = "Denoise failed: \(error)"
            }
        }
    }

    func cancelAIDenoise() {
        aiDenoiseTask?.cancel()
    }

    /// A stored edit with denoise on needs the result recomputed on open.
    func regenerateAIDenoiseIfNeeded() {
        if parameters.aiDenoise > 0, !hasAIDenoiseResult, !aiDenoiseRunning { runAIDenoise() }
    }

    /// Slider binding: moving it off zero with no result yet starts the run.
    var aiDenoiseStrength: Float {
        get { parameters.aiDenoise }
        set {
            parameters.aiDenoise = newValue
            if newValue > 0 { regenerateAIDenoiseIfNeeded() }
        }
    }
}
