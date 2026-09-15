import Foundation
import XCTest
import zlib

/// A deliberately separate, minimal TIFF reader, so the writer is checked
/// against the format rather than against its own idea of it. Little-endian
/// classic TIFF only, which is all the writer makes.
struct TestTIFFReader {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Where the entry's 4-byte value field is.
        let fieldPosition: Int
        /// Where the value's bytes are: the field itself when they fit, else the offset it holds.
        let valuePosition: Int
        let byteLength: Int
        var isInline: Bool { valuePosition == fieldPosition }
    }

    struct Directory {
        let offset: Int
        /// In file order.
        let entries: [Entry]
        let nextOffset: Int
        subscript(tag: UInt16) -> Entry? { entries.first { $0.tag == tag } }
    }

    enum ReadError: Error { case truncated(Int), badHeader, badType(UInt16) }

    let bytes: [UInt8]

    init(url: URL) throws { bytes = Array(try Data(contentsOf: url)) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    static func elementSize(_ type: UInt16) throws -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: throw ReadError.badType(type)
        }
    }

    func u16(_ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { throw ReadError.truncated(at) }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    func u32(_ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { throw ReadError.truncated(at) }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }

    func firstDirectoryOffset() throws -> Int {
        guard bytes.count >= 8, bytes[0] == 0x49, bytes[1] == 0x49, try u16(2) == 42 else { throw ReadError.badHeader }
        return Int(try u32(4))
    }

    func directory(at offset: Int) throws -> Directory {
        let count = Int(try u16(offset))
        var entries: [Entry] = []
        for i in 0..<count {
            let at = offset + 2 + 12 * i
            let type = try u16(at + 2)
            let n = Int(try u32(at + 4))
            let length = n * (try Self.elementSize(type))
            let valuePosition = length <= 4 ? at + 8 : Int(try u32(at + 8))
            guard valuePosition + length <= bytes.count else { throw ReadError.truncated(valuePosition) }
            entries.append(Entry(tag: try u16(at), type: type, count: n, fieldPosition: at + 8,
                                 valuePosition: valuePosition, byteLength: length))
        }
        return Directory(offset: offset, entries: entries, nextOffset: Int(try u32(offset + 2 + 12 * count)))
    }

    // MARK: Values

    /// SHORT or LONG values as integers.
    func integers(_ e: Entry) throws -> [Int] {
        switch e.type {
        case 3: return try (0..<e.count).map { Int(try u16(e.valuePosition + 2 * $0)) }
        case 4: return try (0..<e.count).map { Int(try u32(e.valuePosition + 4 * $0)) }
        default: throw ReadError.badType(e.type)
        }
    }

    func rationals(_ e: Entry) throws -> [(UInt32, UInt32)] {
        try (0..<e.count).map { (try u32(e.valuePosition + 8 * $0), try u32(e.valuePosition + 8 * $0 + 4)) }
    }

    func srationals(_ e: Entry) throws -> [(Int32, Int32)] {
        try rationals(e).map { (Int32(bitPattern: $0.0), Int32(bitPattern: $0.1)) }
    }

    func rawBytes(_ e: Entry) -> [UInt8] { Array(bytes[e.valuePosition..<(e.valuePosition + e.byteLength)]) }

    /// ASCII without its NUL (and checks the NUL is there).
    func ascii(_ e: Entry) throws -> String {
        let raw = rawBytes(e)
        XCTAssertEqual(raw.last, 0, "TIFF text must end with NUL (tag \(e.tag))")
        return String(decoding: raw.dropLast(), as: UTF8.self)
    }

    /// The main-image samples of a tiled, 3-sample half-float directory,
    /// decoded back to `width x height x 3` values (edge padding dropped),
    /// plus the raw full tiles for padding checks.
    func tiledHalfFloats(_ d: Directory) throws -> (pixels: [Float16], tiles: [[UInt8]]) {
        let width = try integers(XCTUnwrap(d[256]))[0], height = try integers(XCTUnwrap(d[257]))[0]
        let tile = try integers(XCTUnwrap(d[322]))[0]
        let offsets = try integers(XCTUnwrap(d[324])), counts = try integers(XCTUnwrap(d[325]))
        let compression = try integers(XCTUnwrap(d[259]))[0]
        let predictor = try d[317].map { try integers($0)[0] } ?? 1
        let across = (width + tile - 1) / tile
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        var tiles: [[UInt8]] = []
        for (index, offset) in offsets.enumerated() {
            var chunk = Array(bytes[offset..<(offset + counts[index])])
            if compression == 8 {
                chunk = try Self.inflate(chunk, expected: tile * tile * 6)
                Self.undoFloatPredictor(&chunk, width: tile, rows: tile, samplesPerPixel: 3, predictor: predictor)
            }
            tiles.append(chunk)
            let x0 = (index % across) * tile, y0 = (index / across) * tile
            for y in 0..<min(tile, height - y0) {
                for x in 0..<min(tile, width - x0) {
                    for c in 0..<3 {
                        let at = ((y * tile + x) * 3 + c) * 2
                        let bits = UInt16(chunk[at]) | UInt16(chunk[at + 1]) << 8
                        pixels[((y0 + y) * width + x0 + x) * 3 + c] = Float16(bitPattern: bits)
                    }
                }
            }
        }
        return (pixels, tiles)
    }

    static func inflate(_ compressed: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expected)
        var length = uLong(expected)
        let status = uncompress(&out, &length, compressed, uLong(compressed.count))
        XCTAssertEqual(status, Z_OK)
        XCTAssertEqual(Int(length), expected)
        return out
    }

    /// The inverse of the writer's predictor, written from TIFF Technical
    /// Note 3 (as LibRaw's DecodeFPDelta does): undo the differences front
    /// to back, then turn byte planes back into little-endian samples.
    static func undoFloatPredictor(_ chunk: inout [UInt8], width: Int, rows: Int, samplesPerPixel: Int, predictor: Int) {
        guard predictor != 1 else { return }
        let factor = predictor == 34894 ? 2 : predictor == 34895 ? 4 : 1
        let distance = samplesPerPixel * factor
        let samples = width * samplesPerPixel, rowBytes = samples * 2
        for row in 0..<rows {
            let base = row * rowBytes
            var planes = Array(chunk[base..<(base + rowBytes)])
            for i in distance..<rowBytes { planes[i] = planes[i] &+ planes[i - distance] }
            for s in 0..<samples {
                chunk[base + s * 2 + 1] = planes[s]
                chunk[base + s * 2] = planes[samples + s]
            }
        }
    }
}
