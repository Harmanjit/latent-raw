import Foundation

/// Runs an export batch several photos at a time while keeping everything
/// the user sees in the batch's order (docs/Performance-Plan.md #19).
///
/// One photo's export is a chain of steps that mostly use different parts
/// of the Mac: the raw decode and the encode on the CPU, the render on the
/// GPU, the write on the disk. One photo at a time left the GPU idle 87-95%
/// of an export. With several photos in flight, one decodes while another
/// renders and a third encodes.
///
/// The caller keeps the parts that must happen in order on its own actor:
/// `next` prepares the next photo (reads its edit, settles its file name)
/// and `commit` counts a finished one, both in the batch's order, so names,
/// numbering, progress and the list of failures come out exactly as from a
/// serial run. Only `work` (decode, render, encode, write) runs on other
/// threads, `workers` at a time.
///
/// Photos that have finished but wait for an earlier one still hold their
/// result (for a combined PDF, a whole decoded page), so they count against
/// the limit too: at most `workers` photos are working and at most
/// `2 * workers` are started but not yet committed. A slow photo at the
/// front (AI Denoise) lets the others run `workers` photos ahead of it to
/// keep the GPU busy, then the run waits for it instead of piling up
/// results without bound.
///
/// Cancelling the calling task stops new photos from starting (`next` sees
/// it and returns nil); photos already started run to the end, so a file
/// is never left half-written, and are committed before `run` returns.
public enum ExportPipeline {
    /// What `next` and `retry` hand back for one photo.
    public enum Step<Job: Sendable, Output: Sendable>: Sendable {
        /// Work to run on a worker.
        case run(Job)
        /// Settled without work (skipped, or failed while preparing): it is
        /// committed in its turn like any other.
        case done(Output)
    }

    /// Runs the batch. `next` is asked for the next photo whenever a worker
    /// is free and `hold()` is false (a paused export: photos under way
    /// finish and are committed, and no other starts); it returns nil when
    /// there are no more, or when the run should stop. `retry` sees each
    /// worker's result as it arrives and may send the photo round again
    /// (a name taken while it rendered); nil keeps the result. `commit`
    /// gets every result in the order `next` handed the photos out.
    public static func run<Job: Sendable, Output: Sendable>(
        workers: Int,
        isolation: isolated (any Actor)? = #isolation,
        hold: () -> Bool = { false },
        next: () async -> Step<Job, Output>?,
        work: @escaping @Sendable (Job) async -> Output,
        retry: (Output) async -> Step<Job, Output>? = { _ in nil },
        commit: (Output) async -> Void
    ) async {
        let workers = max(1, workers)
        let finished = Completions<(Int, Output)>()
        var running = 0
        var exhausted = false
        var admitted = 0
        var nextToCommit = 0
        var ready: [Int: Output] = [:]

        func start(_ job: Job, as sequence: Int) {
            running += 1
            Task.detached(priority: .userInitiated) {
                finished.put((sequence, await work(job)))
            }
        }

        while true {
            // Hand out photos while a worker is free and not too many
            // finished ones wait for an earlier photo. A held run (paused)
            // takes none while others are under way, and waits in `next`
            // (which waits out the pause) only once they're all committed.
            while !exhausted, running < workers, running + ready.count < 2 * workers,
                  running == 0 || !hold() {
                guard let step = await next() else { exhausted = true; break }
                let sequence = admitted
                admitted += 1
                switch step {
                case .run(let job):
                    start(job, as: sequence)
                case .done(let output):
                    ready[sequence] = output
                    // Commit every result that is next in order (inline, not a nested
                    // async function: Swift 6.1 refuses one that captures these vars).
                    while let output = ready.removeValue(forKey: nextToCommit) {
                        nextToCommit += 1
                        await commit(output)
                    }
                }
            }
            guard running > 0 else { break }
            let (sequence, output) = await finished.take()
            running -= 1
            switch await retry(output) {
            case .run(let job)?:
                start(job, as: sequence)
            case .done(let replacement)?:
                ready[sequence] = replacement
            case nil:
                ready[sequence] = output
            }
            // Commit every result that is next in order (inline, not a nested
            // async function: Swift 6.1 refuses one that captures these vars).
            while let output = ready.removeValue(forKey: nextToCommit) {
                nextToCommit += 1
                await commit(output)
            }
        }
        // Commit every result that is next in order (inline, not a nested
        // async function: Swift 6.1 refuses one that captures these vars).
        while let output = ready.removeValue(forKey: nextToCommit) {
            nextToCommit += 1
            await commit(output)
        }
    }
}

/// Results handed from the workers to the one task that runs the pipeline.
/// Waiting here ignores cancellation on purpose: a cancelled export still
/// waits for, and counts, the photos already under way (an AsyncStream
/// would end its iteration on cancel and lose them).
private final class Completions<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: [Value] = []
    private var waiter: CheckedContinuation<Value, Never>?

    func put(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter
            }
            ready.append(value)
            return nil
        }
        waiting?.resume(returning: value)
    }

    func take() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let value: Value? = lock.withLock {
                if !ready.isEmpty { return ready.removeFirst() }
                waiter = continuation
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}
