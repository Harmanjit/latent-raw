import Foundation
import PixelEngine

/// One photo at a time through the model steps of an export: AI masks,
/// touch-up regions, Lens Blur depth, reflection removal and AI Denoise.
///
/// With several photos exporting at once (`ExportPipeline`), the plain
/// steps (decode, render, encode) overlap, but these hold networks and
/// tile buffers whose memory the per-photo estimate in
/// `ExportConcurrency` doesn't cover, and the shared denoiser and model
/// sessions were written for one caller at a time. So they take turns;
/// a photo whose edit needs none of them never waits here.
enum ExportModelGate {
    /// Whether rendering `parameters` runs any model step.
    static func needsModels(_ parameters: EditParameters) -> Bool {
        parameters.aiDenoise > 0 || parameters.touchUp.wantsMasks || parameters.lensBlur.isActive
            || parameters.reflections.isActive || parameters.locals.contains { !$0.modelElements.isEmpty }
    }

    /// Runs `body`, alone among exports when `needed`.
    static func whileHeld<T: Sendable>(_ needed: Bool, isolation: isolated (any Actor)? = #isolation,
                             _ body: () async throws -> T) async throws -> T {
        guard needed else { return try await body() }
        await semaphore.acquire()
        do {
            let value = try await body()
            semaphore.release()
            return value
        } catch {
            semaphore.release()
            throw error
        }
    }

    static let semaphore = AsyncSemaphore()
}

/// A one-holder lock that waits without blocking a thread. Waiting ignores
/// cancellation: an export's steps finish once started.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let free: Bool = lock.withLock {
                if !held {
                    held = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if free { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                held = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
