import Foundation

/// Keeps the Mac from idle-sleeping while an export runs.
///
/// A long batch is often started and left: without this, the system can
/// sleep an hour in and the export stops until someone wakes the Mac. The
/// display may still sleep; only system sleep is held off, and only for as
/// long as the export queue or Export Open Image is working. Ends when
/// `end()` is called or the value is released, whichever comes first.
///
/// `@unchecked Sendable`: the token is only read under the lock, and
/// `endActivity` may be called from any thread.
final class ExportActivity: @unchecked Sendable {
    /// User-initiated work that must not be put off, with idle system sleep
    /// held off (already part of `.userInitiated`; named for the reader).
    static let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]

    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init(reason: String) {
        token = ProcessInfo.processInfo.beginActivity(options: Self.options, reason: reason)
    }

    var isActive: Bool { lock.withLock { token != nil } }

    func end() {
        let ending: NSObjectProtocol? = lock.withLock {
            defer { token = nil }
            return token
        }
        if let ending { ProcessInfo.processInfo.endActivity(ending) }
    }

    deinit { end() }
}
