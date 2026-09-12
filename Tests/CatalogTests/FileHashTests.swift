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
}
