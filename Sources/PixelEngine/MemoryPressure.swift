import Foundation
import Dispatch

/// How short of memory macOS says it is.
public enum MemoryPressureLevel: Int, Comparable, Sendable {
    /// Back to normal after a warning or critical event.
    case normal
    /// Other apps are being squeezed: give back caches that are cheap to rebuild.
    case warning
    /// The system is about to kill processes: give back everything that can
    /// be rebuilt, even at a cost.
    case critical

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The most severe level in a dispatch source's event, if any.
    public init?(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            self = .critical
        } else if event.contains(.warning) {
            self = .warning
        } else if event.contains(.normal) {
            self = .normal
        } else {
            return nil
        }
    }
}

/// Calls `handler` on the main queue whenever the system's memory pressure
/// changes. The kernel tells us, so nothing polls; the source stops when
/// the monitor is released.
///
/// There's no point freeing memory before the system asks. Textures and
/// model caches are what make zooming, slider drags and repeat clicks
/// instant, and unified memory the system doesn't need is better spent on
/// them than left idle.
///
/// `@unchecked Sendable`: the only state is the dispatch source, which is
/// thread-safe and never changes after `init`.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    public init(handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data, let level = MemoryPressureLevel(event) else { return }
            MainActor.assumeIsolated { handler(level) }
        }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}

/// Choices that depend on how much memory the Mac has.
///
/// Textures live in unified memory shared with every other app. A 24 MP
/// session holds its sensor plane plus pooled textures that reach several
/// hundred megabytes at 100% zoom, so on an 8 GB Mac a second session
/// nobody is looking at is a real cost, while on 16 GB and up it is what
/// makes coming back to it instant.
public struct MemoryPolicy: Equatable, Sendable {
    public let physicalMemory: UInt64

    public init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.physicalMemory = physicalMemory
    }

    public static let current = MemoryPolicy()

    /// 8 GB or less.
    public var isConstrained: Bool { physicalMemory <= 8 << 30 }

    /// Whether an image loaded for a view that isn't showing (Compare's
    /// Select pane after leaving Compare) should stay loaded.
    public var keepsIdleImages: Bool { !isConstrained }
}
