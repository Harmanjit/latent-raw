import Foundation

/// The Pause switch of a background job: thumbnail generation, an export,
/// a Remove Dust or Find Faces run. The job looks at it between work
/// items, never in the middle of one, so pausing finishes the file or
/// photo under way and then starts nothing new until Resume; the job
/// carries on from the next item.
///
/// Cancelling still works while paused: `waitWhilePaused` returns as soon
/// as the waiting task is cancelled, and the job's own cancellation check
/// after it stops the loop. That is what lets quitting, closing the
/// catalog or Cancel stop a paused job without resuming it first.
///
/// Thread-safe, so a detached worker reads the switch the main actor sets.
public final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    public init() {}

    public var isPaused: Bool { lock.withLock { paused } }

    public func pause() { lock.withLock { paused = true } }
    public func resume() { lock.withLock { paused = false } }

    /// How often a paused job looks at the switch again. Short enough that
    /// Resume and Cancel feel immediate, long enough to cost nothing.
    public static let pollInterval: Duration = .milliseconds(100)

    /// Returns at once when not paused; otherwise once resumed, or once the
    /// calling task is cancelled (check for that afterwards). True when it
    /// waited.
    @discardableResult
    public func waitWhilePaused() async -> Bool {
        guard isPaused else { return false }
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
        }
        return true
    }
}
