import Foundation

/// A small, bounded pool for reconcile's per-file work (hashing, and the
/// metadata read beside it). Each file is independent, so a few at once keep
/// an SSD's queue full where one at a time leaves it mostly idle; more than a
/// few only add seeking on a spinning or network disk and memory for buffers.
///
/// Blocking on purpose: reconcile is a synchronous pass on the catalog's
/// actor, and nothing here touches the catalog. Results come back in input
/// order, so what reconcile does with them doesn't depend on timing.
enum ImportWorkers {
    /// How many files to work on at once for a folder at `root`: four on
    /// the Mac's own disk, two on an external or network one.
    static func width(forFolderAt root: URL) -> Int {
        let values = try? root.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        if values?.volumeIsLocal == false { return 2 }
        return values?.volumeIsInternal == true ? 4 : 2
    }

    /// `body(i, buffer)` for every `i` in `0..<count`, on at most `width`
    /// threads at once. Each thread has its own hashing buffer of
    /// `FileHash.chunkSize` bytes, reused for every file it takes.
    static func map<T: Sendable>(count: Int, width: Int,
                                 _ body: @escaping @Sendable (Int, UnsafeMutableRawBufferPointer) -> T) -> [T] {
        guard count > 0 else { return [] }
        let slots = Slots<T>(count: count)
        let threads = max(1, min(width, count))
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: FileHash.chunkSize, alignment: 16_384)
            defer { buffer.deallocate() }
            while let index = slots.next() {
                slots.put(body(index, buffer), at: index)
            }
        }
        return slots.results()
    }

    /// The work queue and its results, shared by the threads under a lock.
    private final class Slots<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [T?]
        private var cursor = 0

        init(count: Int) { values = Array(repeating: nil, count: count) }

        func next() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard cursor < values.count else { return nil }
            defer { cursor += 1 }
            return cursor
        }

        func put(_ value: T, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            values[index] = value
        }

        func results() -> [T] {
            lock.lock(); defer { lock.unlock() }
            return values.map { $0! }
        }
    }
}
