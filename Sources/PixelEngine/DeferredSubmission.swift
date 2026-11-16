import Foundation
import Metal

/// The editor's renders, submitted to the GPU without waiting for it
/// (docs/Performance-Plan.md fix #15).
///
/// OWNERSHIP RULE. An `ImageSession`, and the `RenderPipeline` rendering it,
/// belong to one thread at a time; the editor's session belongs to the main
/// actor. Every CPU-side read or write of the session's state happens
/// there: the pooled textures and the pool dictionary, the StageKey /
/// HealKey / denoise / tone-equalizer caches, the brush and AI mask uploads
/// (`MTLTexture.replace` into textures the GPU reads), readbacks.
///
/// The GPU side is ordered by the editor's single command queue
/// (`GPUContext.commandQueue`): a render committed without waiting is
/// complete before any later command buffer on that queue runs — the next
/// render, the presenter's draw, the scopes, a readback blit. So pooled
/// textures and cache entries can be handed on at commit time.
///
/// What the queue does not order is the CPU. While a deferred command
/// buffer may still be running, nothing may write one of the session's
/// textures in place or read one back on the CPU. Hence:
///  - every render begins with `ImageSession.waitForDeferredWork()`, which
///    blocks until the submission the editor took (if any) has completed
///    and runs its post-completion readbacks — so a synchronous render
///    (magnifier, masked scopes, AI-mask input, export of the open photo)
///    behaves exactly as before, only possibly waiting a little first;
///  - the editor keeps at most one submission in flight per session and
///    encodes the next only once it has completed (`EditorRenderQueue`).
/// The command buffers retain every texture they use, so a texture the
/// session lets go of (a pool release on zoom) stays alive until the GPU
/// is done with it.
public final class GPUSubmission {
    private var buffers: [MTLCommandBuffer] = []
    private var afterCompletion: [() -> Void] = []
    private let group = DispatchGroup()
    private var finished = false
    private var succeeded = true

    init() {}

    /// Commits `cmdBuffer` as part of this submission. `after` runs on the
    /// owning thread once the GPU is done (a readback), in `finish()`.
    func commit(_ cmdBuffer: MTLCommandBuffer, after: (() -> Void)?) {
        group.enter()
        cmdBuffer.addCompletedHandler { [group] _ in group.leave() }
        cmdBuffer.commit()
        buffers.append(cmdBuffer)
        if let after { afterCompletion.append(after) }
    }

    /// Something to await the GPU with, from any isolation.
    public var completion: GPUCompletion { GPUCompletion(group: group) }

    /// Blocks until every command buffer of this submission has completed.
    public func waitUntilCompleted() { group.wait() }

    /// Runs the post-completion work once and says whether every command
    /// buffer succeeded. Call it on the owning thread, after completion.
    @discardableResult
    public func finish() -> Bool {
        guard !finished else { return succeeded }
        finished = true
        let work = afterCompletion
        afterCompletion = []
        work.forEach { $0() }
        succeeded = !buffers.contains { $0.status == .error }
        buffers = []
        return succeeded
    }
}

/// Awaits a `GPUSubmission`'s command buffers without holding the
/// submission itself, so it can cross isolation boundaries.
public struct GPUCompletion: Sendable {
    let group: DispatchGroup

    /// Suspends until the GPU has finished; returns when that happened
    /// (measured on the completion thread, not after the hop back).
    public func wait() async -> ContinuousClock.Instant {
        await withCheckedContinuation { (continuation: CheckedContinuation<ContinuousClock.Instant, Never>) in
            group.notify(queue: .global(qos: .userInteractive)) {
                continuation.resume(returning: .now)
            }
        }
    }
}

extension ImageSession {
    /// Commits a render's final command buffer: into the submission being
    /// gathered while `defersGPUCompletion` is set, otherwise committed and
    /// waited for as always. `after` is that render's readback work.
    func commitRender(_ cmdBuffer: MTLCommandBuffer, after: (() -> Void)?) throws {
        if defersGPUCompletion {
            let submission = gatheringSubmission ?? GPUSubmission()
            gatheringSubmission = submission
            submission.commit(cmdBuffer, after: after)
            return
        }
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
        after?()
    }

    /// Ends the gathering the editor began by setting
    /// `defersGPUCompletion`: returns everything committed since, now in
    /// flight, or nil when nothing was. Until it is finished, every later
    /// render on this session waits for it first (`waitForDeferredWork`).
    public func takeDeferredSubmission() -> GPUSubmission? {
        defersGPUCompletion = false
        guard let submission = gatheringSubmission else { return nil }
        gatheringSubmission = nil
        inFlightSubmission = submission
        return submission
    }

    /// Blocks until the submission in flight, if any, has completed, and
    /// runs its readbacks. A submission still being gathered (renders of
    /// the same editor pass) is left alone. On a failed submission the
    /// caches that may point at unfinished pixels are dropped.
    public func waitForDeferredWork() {
        guard let submission = inFlightSubmission else { return }
        submission.waitUntilCompleted()
        finishDeferredWork(submission)
    }

    /// The editor's half of `waitForDeferredWork`, once it knows the GPU
    /// is done: runs the readbacks (once) and lets go of the submission.
    @discardableResult
    public func finishDeferredWork(_ submission: GPUSubmission) -> Bool {
        if inFlightSubmission === submission { inFlightSubmission = nil }
        let ok = submission.finish()
        if !ok { dropCachesAfterFailedRender() }
        return ok
    }
}
