import Foundation

/// Content hashing for catalog identity (DESIGN.md §5.3).
///
/// The hash is how reconciliation recognises a file after it's been
/// renamed and reattaches its sidecar. Which algorithm doesn't matter
/// much as long as it's fast and, once released, never changes — every
/// sidecar records the hash of the file it belongs to.
///
/// This is XXH64 (the original xxHash), implemented here in ~60 lines
/// rather than vendored: it runs at several GB/s, far faster than any
/// disk, so the newer XXH3 variant would buy nothing measurable and
/// would cost a dependency or a much larger port.
/// Hashes are written as `xxh64:` + 16 hex digits.
public enum FileHash {
    public static let prefix = "xxh64"

    /// How much of a file one `read()` asks for. Large reads keep the SSD
    /// busy (a memory map faults pages in a few at a time and read about a
    /// quarter as fast); a multiple of 32 so every chunk but the last is
    /// whole XXH64 stripes.
    public static let chunkSize = 4 << 20

    /// Hashes a whole file, read in `chunkSize` pieces into one buffer, so
    /// a 30 MB raw is never held in memory at once. The same value as
    /// `xxh64(Data(contentsOf: url))`.
    ///
    /// `uncached` (`F_NOCACHE`) keeps what is read out of the page cache,
    /// so a big import doesn't push everything else out of memory to keep
    /// files nobody reads again soon. Verify Files uses it to read the
    /// disk's copy.
    public static func xxh64(ofFileAt url: URL, uncached: Bool = false) throws -> UInt64 {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16_384)
        defer { buffer.deallocate() }
        return try xxh64(ofFileAt: url, uncached: uncached, buffer: buffer)
    }

    /// The same, reading through `buffer` (whose size sets the chunk), so
    /// a worker hashing many files allocates it once.
    public static func xxh64(ofFileAt url: URL, uncached: Bool,
                             buffer: UnsafeMutableRawBufferPointer) throws -> UInt64 {
        let fd = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY) } ?? -1 }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if uncached { _ = fcntl(fd, F_NOCACHE, 1) }
        return try xxh64(fileDescriptor: fd, buffer: buffer)
    }

    /// Reads `fd` from where it stands to the end and hashes what it read.
    public static func xxh64(fileDescriptor fd: Int32, buffer: UnsafeMutableRawBufferPointer,
                             seed: UInt64 = 0) throws -> UInt64 {
        guard let base = buffer.baseAddress, buffer.count > 0 else { throw POSIXError(.EINVAL) }
        var hasher = Hasher64(seed: seed)
        while true {
            // Fill the buffer before hashing it: a short read mid-file
            // would otherwise split a stripe (handled, but slower).
            var filled = 0
            while filled < buffer.count {
                let got = Darwin.read(fd, base + filled, buffer.count - filled)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if got == 0 { break }
                filled += got
            }
            hasher.update(UnsafeRawBufferPointer(start: base, count: filled))
            if filled < buffer.count { return hasher.finalize() }
        }
    }

    public static func xxh64(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { xxh64($0, seed: seed) }
    }

    public static func hexString(_ hash: UInt64) -> String {
        String(format: "%016llx", hash)
    }

    // MARK: - XXH64

    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var acc = acc &+ (input &* p2)
        acc = rotl(acc, 31)
        return acc &* p1
    }

    @inline(__always) private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        var acc = acc ^ round(0, val)
        acc = (acc &* p1) &+ p4
        return acc
    }

    /// XXH64 fed in pieces: the same value as hashing their concatenation
    /// in one go (`xxh64(_:seed:)`, kept as the reference).
    public struct Hasher64 {
        private var v1, v2, v3, v4: UInt64
        private let seed: UInt64
        private var total: UInt64 = 0
        /// Bytes of a stripe not yet complete.
        private var pending: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        private var pendingCount = 0

        public init(seed: UInt64 = 0) {
            self.seed = seed
            v1 = seed &+ FileHash.p1 &+ FileHash.p2
            v2 = seed &+ FileHash.p2
            v3 = seed
            v4 = seed &- FileHash.p1
        }

        public mutating func update(_ bytes: UnsafeRawBufferPointer) {
            guard let start = bytes.baseAddress, !bytes.isEmpty else { return }
            total &+= UInt64(bytes.count)
            var offset = 0
            if pendingCount > 0 {
                let take = min(32 - pendingCount, bytes.count)
                var stripe = pending
                let at = pendingCount
                withUnsafeMutableBytes(of: &stripe) { $0.baseAddress!.advanced(by: at).copyMemory(from: start, byteCount: take) }
                pending = stripe
                pendingCount += take
                offset = take
                guard pendingCount == 32 else { return }
                withUnsafeBytes(of: stripe) { consume(stripes: $0) }
                pendingCount = 0
            }
            let whole = (bytes.count - offset) & ~31
            if whole > 0 { consume(stripes: UnsafeRawBufferPointer(start: start + offset, count: whole)) }
            let rest = bytes.count - offset - whole
            if rest > 0 {
                var stripe = pending
                withUnsafeMutableBytes(of: &stripe) { $0.baseAddress!.copyMemory(from: start + offset + whole, byteCount: rest) }
                pending = stripe
                pendingCount = rest
            }
        }

        /// Whole 32-byte stripes, `bytes.count` a multiple of 32.
        private mutating func consume(stripes bytes: UnsafeRawBufferPointer) {
            var a = v1, b = v2, c = v3, d = v4
            var i = 0
            while i < bytes.count {
                a = FileHash.round(a, bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian)
                b = FileHash.round(b, bytes.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self).littleEndian)
                c = FileHash.round(c, bytes.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self).littleEndian)
                d = FileHash.round(d, bytes.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self).littleEndian)
                i += 32
            }
            v1 = a; v2 = b; v3 = c; v4 = d
        }

        public func finalize() -> UInt64 {
            var h: UInt64
            if total >= 32 {
                h = FileHash.rotl(v1, 1) &+ FileHash.rotl(v2, 7) &+ FileHash.rotl(v3, 12) &+ FileHash.rotl(v4, 18)
                h = FileHash.mergeRound(h, v1)
                h = FileHash.mergeRound(h, v2)
                h = FileHash.mergeRound(h, v3)
                h = FileHash.mergeRound(h, v4)
            } else {
                h = seed &+ FileHash.p5
            }
            h = h &+ total
            let count = pendingCount
            return withUnsafeBytes(of: pending) { stripe in
                let tail = UnsafeRawBufferPointer(rebasing: stripe[..<count])
                return FileHash.finish(h, tail: tail)
            }
        }
    }

    /// The tail of fewer than 32 bytes and the final avalanche.
    @inline(__always) private static func finish(_ start: UInt64, tail bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h = start
        var i = 0
        let len = bytes.count
        while i + 8 <= len {
            h ^= round(0, bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian)
            h = (rotl(h, 27) &* p1) &+ p4
            i += 8
        }
        if i + 4 <= len {
            h ^= UInt64(bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian) &* p1
            h = (rotl(h, 23) &* p2) &+ p3
            i += 4
        }
        while i < len {
            h ^= UInt64(bytes[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }

    public static func xxh64(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let len = bytes.count
        var i = 0
        var h: UInt64

        @inline(__always) func read64(_ at: Int) -> UInt64 {
            bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian
        }
        @inline(__always) func read32(_ at: Int) -> UInt32 {
            bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian
        }

        if len >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            let limit = len - 32
            while i <= limit {
                v1 = round(v1, read64(i));      i += 8
                v2 = round(v2, read64(i));      i += 8
                v3 = round(v3, read64(i));      i += 8
                v4 = round(v4, read64(i));      i += 8
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = seed &+ p5
        }

        h = h &+ UInt64(len)

        while i + 8 <= len {
            h ^= round(0, read64(i))
            h = (rotl(h, 27) &* p1) &+ p4
            i += 8
        }
        if i + 4 <= len {
            h ^= UInt64(read32(i)) &* p1
            h = (rotl(h, 23) &* p2) &+ p3
            i += 4
        }
        while i < len {
            h ^= UInt64(bytes[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }

        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }
}
