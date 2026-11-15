import XCTest
@testable import Catalog

final class FileHashTests: XCTestCase {
    /// Reference values from the xxHash project's own test vectors.
    func testKnownVectors() {
        XCTAssertEqual(FileHash.xxh64(Data()), 0xEF46DB3751D8E999)
        XCTAssertEqual(FileHash.xxh64(Data("a".utf8)), 0xD24EC4F1A98C6E5B)
        XCTAssertEqual(FileHash.xxh64(Data("abc".utf8)), 0x44BC2CF5AD770999)
    }

    /// Exercises every branch: the 32-byte stripes, the 8-byte tail, the
    /// 4-byte tail and the single bytes.
    func testLongInputIsStableAndLengthSensitive() {
        let base = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let h1 = FileHash.xxh64(base)
        XCTAssertEqual(h1, FileHash.xxh64(base))
        XCTAssertNotEqual(h1, FileHash.xxh64(base.dropLast()))
        XCTAssertEqual(FileHash.hexString(0xEF46DB3751D8E999), "ef46db3751d8e999")
    }

    // MARK: - Chunked reads (import and Verify Files)

    /// The streaming hasher fed in every kind of piece gives the one-shot
    /// value: pieces shorter than a stripe, ones that end mid-stripe, empty
    /// ones.
    func testStreamingMatchesOneShotForAnySplit() {
        var rng = SystemRandomNumberGenerator()
        for length in [0, 1, 3, 4, 7, 8, 31, 32, 33, 63, 64, 65, 100, 1000, 4099] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let expected = FileHash.xxh64(data)
            for _ in 0..<20 {
                var hasher = FileHash.Hasher64()
                var at = 0
                data.withUnsafeBytes { all in
                    while at < length {
                        let piece = Int.random(in: 0...min(70, length - at), using: &rng)
                        hasher.update(UnsafeRawBufferPointer(rebasing: all[at..<(at + piece)]))
                        at += piece
                    }
                }
                XCTAssertEqual(hasher.finalize(), expected, "length \(length)")
            }
        }
        // A seed carries through too.
        let data = Data((0..<777).map { UInt8($0 & 0xFF) })
        var seeded = FileHash.Hasher64(seed: 42)
        data.withUnsafeBytes { seeded.update($0) }
        XCTAssertEqual(seeded.finalize(), FileHash.xxh64(data, seed: 42))
    }

    /// Catalogs hold hashes made by the old memory-mapped read; the
    /// chunked read must give exactly those, cached or not, with any chunk
    /// size, at sizes around the chunk and stripe boundaries.
    func testChunkedFileHashMatchesMemoryMappedHash() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var rng = SystemRandomNumberGenerator()
        let chunk = FileHash.chunkSize
        let sizes = [0, 1, 31, 32, 33, 4096, 65_537, chunk - 1, chunk, chunk + 1, chunk + 33, 3 * chunk + 17]
        for size in sizes {
            var bytes = [UInt8](repeating: 0, count: size)
            for i in stride(from: 0, to: size, by: 8) {
                let word = UInt64.random(in: .min ... .max, using: &rng)
                withUnsafeBytes(of: word) { w in for j in 0..<min(8, size - i) { bytes[i + j] = w[j] } }
            }
            let url = folder.appendingPathComponent("f\(size).nef")
            try Data(bytes).write(to: url)
            // The old path, as reconcile used it before.
            let old = FileHash.xxh64(try Data(contentsOf: url, options: .mappedIfSafe))
            XCTAssertEqual(try FileHash.xxh64(ofFileAt: url), old, "size \(size)")
            XCTAssertEqual(try FileHash.xxh64(ofFileAt: url, uncached: true), old, "size \(size), uncached")
            XCTAssertEqual(try FileIntegrity.uncachedXXH64(ofFileAt: url), old, "size \(size), verify")
            for small in [32, 4096, 100_000] {
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: small, alignment: 16)
                defer { buffer.deallocate() }
                XCTAssertEqual(try FileHash.xxh64(ofFileAt: url, uncached: false, buffer: buffer), old,
                               "size \(size), chunk \(small)")
            }
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try FileHash.xxh64(ofFileAt: URL(fileURLWithPath: "/nonexistent/\(UUID()).nef")))
    }
}
