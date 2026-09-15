import Foundation

/// A model loaded on first use, shared by everyone who asks, and let go of
/// when memory runs short.
///
/// Loading is from the compiled copy CoreMLStore keeps on disk, so after a
/// `release()` the next request pays a reload (well under a second for
/// the bundled models), never a recompile. Anyone still holding the model,
/// such as an encoded SAM 2 image or an export in flight, keeps it alive
/// until they finish: releasing only drops the shared reference.
///
/// `@unchecked Sendable`: the one mutable property is guarded by `lock`.
public final class SharedModel<Model: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let load: @Sendable () async -> Model?
    private var loading: Task<Model?, Never>?

    /// `load` returns nil when the model isn't bundled or fails to load;
    /// that answer is kept too, until the next release.
    public init(load: @escaping @Sendable () async -> Model?) {
        self.load = load
    }

    /// The model, loading it first if no one has since the last release.
    public var value: Model? {
        get async { await task().value }
    }

    /// Whether a load has started (or finished) since the last release.
    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return loading != nil
    }

    /// Drops the shared reference. Memory comes back once the last user
    /// of the model lets go of it too.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        loading = nil
    }

    private func task() -> Task<Model?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let loading { return loading }
        let load = self.load
        let started = Task.detached(priority: .utility) { await load() }
        loading = started
        return started
    }
}
