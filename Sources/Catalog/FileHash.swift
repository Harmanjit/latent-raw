import Foundation

/// Content hashing for catalog identity (DESIGN.md §5.3, §6).
///
/// The hash is how Latent recognises a file after it's been renamed, and
/// how import spots duplicates. Which algorithm doesn't matter much as
/// long as it's fast and, once released, never changes — every sidecar
/// records the hash of the file it belongs to.
///
/// This is XXH64 (the original xxHash), implemented here in ~60 lines
/// rather than vendored: it runs at several GB/s, far faster than any
/// disk, so the newer XXH3 variant the design doc names would buy
/// nothing measurable and would cost a dependency or a much larger port.
/// Hashes are written as `xxh64:` + 16 hex digits.
public enum FileHash {
    public static let prefix = "xxh64"

    /// Hashes a whole file. Memory-mapped, so a 30 MB raw doesn't get
    /// copied into a Data buffer first.
    public static func xxh64(ofFileAt url: URL) throws -> UInt64 {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return xxh64(data)
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
