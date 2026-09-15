import XCTest
@testable import MergeKit

/// The general TIFF layer on small hand-built files.
final class TIFFLayoutTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws { folder = try Fixtures.temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ topLevel: [TIFFDirectory]) throws -> TestTIFFReader {
        var layout = try TIFFLayout(topLevel: topLevel)
        let url = folder.appendingPathComponent(UUID().uuidString + ".tif")
        let size = try LinearRawDNGWriter.write(&layout, toNewFileAt: url)
        let reader = try TestTIFFReader(url: url)
        XCTAssertEqual(reader.bytes.count, size)
        XCTAssertLessThanOrEqual(size, layout.maximumFileSize)
        return reader
    }

    func testEveryFieldTypeInlineAndOutOfLine() throws {
        var d = TIFFDirectory()
        d.set(1, .bytes([7]))                                        // 1 byte: inline
        d.set(2, .bytes([1, 2, 3, 4, 5]))                            // 5 bytes: out of line
        d.set(3, .ascii("abc"))                                      // 4 with NUL: inline
        d.set(4, .ascii("abcd"))                                     // 5 with NUL: out of line
        d.set(5, .shorts([0xBEEF, 2]))
        d.set(6, .shorts([1, 2, 3]))
        d.set(7, .longs([0xDEADBEEF]))
        d.set(8, .rationals([TIFFRational(3, 4)]))
        d.set(9, .srationals([TIFFSRational(-3, 4), TIFFSRational(5, -6)]))
        d.set(10, .undefined([9, 9]))
        d.set(11, .slongs([-2]))
        d.set(12, .floats([1.5]))
        d.set(13, .doubles([-0.25]))
        let r = try write([d])
        let read = try r.directory(at: r.firstDirectoryOffset())

        XCTAssertEqual(read.entries.map(\.tag), Array(1...13))
        XCTAssertEqual(read.entries.map(\.type), [1, 1, 2, 2, 3, 3, 4, 5, 10, 7, 9, 11, 12])
        XCTAssertEqual(read.entries.map(\.isInline), [true, false, true, false, true, false, true, false, false,
                                                      true, true, true, false])
        XCTAssertEqual(r.rawBytes(read[1]!), [7])
        XCTAssertEqual(r.rawBytes(read[2]!), [1, 2, 3, 4, 5])
        XCTAssertEqual(try r.ascii(read[3]!), "abc")
        XCTAssertEqual(try r.ascii(read[4]!), "abcd")
        XCTAssertEqual(try r.integers(read[5]!), [0xBEEF, 2])
        XCTAssertEqual(try r.integers(read[6]!), [1, 2, 3])
        XCTAssertEqual(try r.integers(read[7]!), [0xDEADBEEF])
        XCTAssertTrue(try r.rationals(read[8]!)[0] == (3, 4))
        XCTAssertTrue(try r.srationals(read[9]!).elementsEqual([(-3, 4), (5, -6)], by: ==))
        XCTAssertEqual(try r.u32(read[11]!.valuePosition), UInt32(bitPattern: -2))
        XCTAssertEqual(Float(bitPattern: try r.u32(read[12]!.valuePosition)), 1.5)
        let low = UInt64(try r.u32(read[13]!.valuePosition)), high = UInt64(try r.u32(read[13]!.valuePosition + 4))
        XCTAssertEqual(Double(bitPattern: low | high << 32), -0.25)
        for e in read.entries where !e.isInline { XCTAssertEqual(e.valuePosition % 2, 0, "tag \(e.tag)") }
    }

    func testChainsChildrenAndOddLengthChunks() throws {
        var child = TIFFDirectory()
        child.set(273, .imageChunkOffsets)
        child.set(279, .imageChunkByteCounts)
        child.imageData = TIFFImageData(chunkCount: 3, maximumByteCount: 9) { emit in
            for chunk in [[1], [2, 3, 4], [5, 6]] as [[UInt8]] { try chunk.withUnsafeBytes { try emit($0) } }
        }
        var first = TIFFDirectory()
        first.set(330, .directories([child, TIFFDirectory()]))
        var second = TIFFDirectory()
        second.set(305, .ascii("second"))
        let r = try write([first, second])

        let ifd0 = try r.directory(at: r.firstDirectoryOffset())
        let ifd1 = try r.directory(at: ifd0.nextOffset)
        XCTAssertEqual(try r.ascii(ifd1[305]!), "second")
        XCTAssertEqual(ifd1.nextOffset, 0)
        let children = try r.integers(ifd0[330]!).map { try r.directory(at: $0) }
        XCTAssertEqual(children.map(\.nextOffset), [0, 0], "child directories aren't in the top-level chain")
        let offsets = try r.integers(children[0][273]!), counts = try r.integers(children[0][279]!)
        XCTAssertEqual(counts, [1, 3, 2])
        XCTAssertTrue(offsets.allSatisfy { $0 % 2 == 0 }, "\(offsets)")
        XCTAssertEqual(zip(offsets, counts).flatMap { r.bytes[$0..<($0 + $1)] }, [1, 2, 3, 4, 5, 6])
    }

    func testAProducerThatEmitsTheWrongNumberOfChunksFails() throws {
        for emitted in [1, 3] {
            var d = TIFFDirectory()
            d.set(324, .imageChunkOffsets)
            d.set(325, .imageChunkByteCounts)
            d.imageData = TIFFImageData(chunkCount: 2, maximumByteCount: 8) { emit in
                for _ in 0..<emitted { try [0, 0, 0, 0].withUnsafeBytes { try emit($0) } }
            }
            XCTAssertThrowsError(try write([d])) { error in
                guard case MergeDNGError.internalInconsistency = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testRefusesFilesOverFourGigabytes() {
        var d = TIFFDirectory()
        d.set(324, .imageChunkOffsets)
        d.imageData = TIFFImageData(chunkCount: 1, maximumByteCount: Int(UInt32.max)) { _ in }
        XCTAssertThrowsError(try TIFFLayout(topLevel: [d])) { error in
            guard case MergeDNGError.fileTooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testRationalsRefuseWhatTheyCantHold() {
        XCTAssertNil(TIFFRational(-1, denominator: 10))
        XCTAssertNil(TIFFRational(.nan, denominator: 10))
        XCTAssertNil(TIFFRational(5_000, denominator: 1_000_000))
        XCTAssertEqual(TIFFRational(0.481203, denominator: 1_000_000), TIFFRational(481_203, 1_000_000))
        XCTAssertNil(TIFFSRational(.infinity, denominator: 10))
        XCTAssertNil(TIFFSRational(-3000, denominator: 1_000_000))
        XCTAssertEqual(TIFFSRational(-0.0715, denominator: 10_000), TIFFSRational(-715, 10_000))
    }
}
