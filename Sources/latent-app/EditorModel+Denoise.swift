import Foundation
import PixelEngine
import MLKit

extension EditorModel {
    // MARK: - Neural denoise

    var aiDenoiseAvailable: Bool { AIDenoiser.isAvailable }
    var hasAIDenoiseResult: Bool { session?.aiDenoisedCameraRGB != nil }
    /// False for a linear source (an HDR merge or another LinearRaw DNG):
    /// the network only handles values up to white, and a merge keeps much
    /// of its picture above it (`ImageSession.supportsAIDenoise`). True
    /// with no image open, so the panel doesn't flash its explanation.
    var aiDenoiseSupported: Bool { session?.supportsAIDenoise ?? true }

    /// Runs the network over the open image (once; the result lives with
    /// the session) and re-renders. ~12 s for 24 MP on the GPU.
    func runAIDenoise() {
        guard let session, let pipeline, let gpu = gpuContext, !aiDenoiseRunning else { return }
        // The worker would refuse too; saying so here keeps the status honest.
        guard session.supportsAIDenoise else {
            aiDenoiseStatus = "Not available for merged or linear DNG images."
            return
        }
        guard AIDenoiser.isAvailable else {
            aiDenoiseStatus = "NAFNet model not bundled — see Sources/MLKit/Resources/Models/README.md"
            return
        }
        let run = beginAIDenoiseRun()
        // Seconds to minutes of GPU work, often left to run: held off sleep
        // as an export is.
        let activity = ExportActivity(reason: "Reducing noise")
        aiDenoiseTask = Task { [weak self] in
            defer { activity.end() }
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

    /// Denoise is on with no result, and none is being made. Never for a
    /// linear source, where a strength (pasted from a raw's edit, say) has
    /// nothing to run.
    var needsAIDenoise: Bool {
        parameters.aiDenoise > 0 && !hasAIDenoiseResult && !aiDenoiseRunning && aiDenoiseSupported
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
