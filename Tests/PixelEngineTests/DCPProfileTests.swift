import XCTest
import ColorKit

/// Malformed numeric tags in an imported .dcp must be refused, never trap.
/// (Lives in PixelEngineTests because there is no ColorKit test target.)
final class DCPProfileTests: XCTestCase {

    /// A little-endian "IIRC" file whose entries carry raw TIFF types and
    /// already-encoded value bytes.
    static func dcp(_ tags: [(tag: Int, type: UInt16, count: Int, bytes: Data)]) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let sorted = tags.sorted { $0.tag < $1.tag }
        let ifdSize = 2 + sorted.count * 12 + 4
        var extra = Data()
        var ifd = le16(UInt16(sorted.count))
        for t in sorted {
            ifd += le16(UInt16(t.tag)) + le16(t.type) + le32(UInt32(t.count))
            if t.bytes.count <= 4 {
                ifd += t.bytes + Data(repeating: 0, count: 4 - t.bytes.count)
            } else {
                ifd += le32(UInt32(8 + ifdSize + extra.count))
                extra += t.bytes
            }
        }
        ifd += le32(0)
        return Data([0x49, 0x49, 0x52, 0x43]) + le32(8) + ifd + extra
    }

    static func floats(_ v: [Float]) -> Data {
        v.reduce(Data()) { d, f in d + withUnsafeBytes(of: f.bitPattern.littleEndian) { Data($0) } }
    }
    static func doubles(_ v: [Double]) -> Data {
        v.reduce(Data()) { d, f in d + withUnsafeBytes(of: f.bitPattern.littleEndian) { Data($0) } }
    }

    static let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    static let colorMatrix1 = (tag: 50721, type: UInt16(11), count: 9, bytes: floats(identity))

    func testValidFloatTagsStillParse() throws {
        let p = try DCPProfile(data: Self.dcp([
            Self.colorMatrix1,
            (50778, 11, 1, Self.floats([17])),
        ]))
        XCTAssertEqual(p.calibration1.illuminant, 17)
    }

    func testNaNIlluminantThrows() {
        XCTAssertThrowsError(try DCPProfile(data: Self.dcp([
            Self.colorMatrix1,
            (50778, 11, 1, Self.floats([.nan])),
        ])))
    }

    func testInfiniteEncodingThrows() {
        XCTAssertThrowsError(try DCPProfile(data: Self.dcp([
            Self.colorMatrix1,
            (51107, 11, 1, Self.floats([.infinity])),
        ])))
    }

    func testHugeDoubleHueSatDimsThrows() {
        XCTAssertThrowsError(try DCPProfile(data: Self.dcp([
            Self.colorMatrix1,
            (50937, 12, 3, Self.doubles([1e300, 2, 1])),
            (50938, 11, 6, Self.floats([0, 1, 1, 0, 1, 1])),
        ])))
    }

    func testHugeDoubleLookDimsThrows() {
        XCTAssertThrowsError(try DCPProfile(data: Self.dcp([
            Self.colorMatrix1,
            (50981, 12, 3, Self.doubles([.nan, 2, 1])),
            (50982, 11, 6, Self.floats([0, 1, 1, 0, 1, 1])),
        ])))
    }
}
