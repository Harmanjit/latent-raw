import ImageIO
import XCTest
@testable import MergeKit

/// Every tag of a written DNG, checked with the test's own TIFF reader:
/// field type, count and value, plus the structural rules (sorted tags,
/// even offsets, nothing overlapping).
final class DNGTagTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!
    nonisolated(unsafe) private var reader: TestTIFFReader!
    nonisolated(unsafe) private var result: MergeDNGWriteResult!

    static let width = 700, height = 300

    override func setUpWithError() throws {
        folder = try Fixtures.temporaryFolder()
        var writer = LinearRawDNGWriter(tileSize: 256, previewLongEdge: 200, thumbnailLongEdge: 128)
        writer.availableCapacity = { _ in nil }
        let pixels = try LinearRawPixelSource.buffer(
            Fixtures.pixels(width: Self.width, height: Self.height, maximum: 6), width: Self.width, height: Self.height)
        var metadata = try Fixtures.metadata()
        metadata.defaultCrop = PixelRegion(x: 10, y: 20, width: 600, height: 250)
        result = try writer.write(pixels, maximum: 6, metadata: metadata, recipe: Fixtures.recipe(),
                                  preview: Fixtures.previewImage(), to: folder.appendingPathComponent("tags.dng"))
        reader = try TestTIFFReader(url: result.url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func entry(_ d: TestTIFFReader.Directory, _ tag: UInt16, type: UInt16, count: Int,
                       file: StaticString = #filePath, line: UInt = #line) throws -> TestTIFFReader.Entry {
        let e = try XCTUnwrap(d[tag], "tag \(tag) missing", file: file, line: line)
        XCTAssertEqual(e.type, type, "type of tag \(tag)", file: file, line: line)
        XCTAssertEqual(e.count, count, "count of tag \(tag)", file: file, line: line)
        return e
    }

    private func integers(_ d: TestTIFFReader.Directory, _ tag: UInt16, type: UInt16, _ expected: [Int],
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let e = try entry(d, tag, type: type, count: expected.count, file: file, line: line)
        XCTAssertEqual(try reader.integers(e), expected, "value of tag \(tag)", file: file, line: line)
    }

    private func ascii(_ d: TestTIFFReader.Directory, _ tag: UInt16, _ expected: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let e = try entry(d, tag, type: 2, count: expected.utf8.count + 1, file: file, line: line)
        XCTAssertEqual(try reader.ascii(e), expected, file: file, line: line)
    }

    private func directories() throws -> (ifd0: TestTIFFReader.Directory, raw: TestTIFFReader.Directory,
                                          preview: TestTIFFReader.Directory, exif: TestTIFFReader.Directory) {
        let ifd0 = try reader.directory(at: reader.firstDirectoryOffset())
        let subs = try reader.integers(XCTUnwrap(ifd0[330]))
        let exif = try reader.integers(XCTUnwrap(ifd0[34665]))
        return (ifd0, try reader.directory(at: subs[0]), try reader.directory(at: subs[1]),
                try reader.directory(at: exif[0]))
    }

    // MARK: Tests

    func testIFD0HoldsTheThumbnailAndDNGTags() throws {
        let d = try directories().ifd0
        XCTAssertEqual(d.entries.map(\.tag), [254, 256, 257, 258, 259, 262, 271, 272, 273, 274, 277, 278, 279, 284,
                                              305, 306, 330, 700, 34665, 50706, 50707, 50708, 50721, 50728, 50730,
                                              50778], "exactly these tags, in ascending order")
        XCTAssertEqual(d.nextOffset, 0, "IFD0 is the only top-level directory")

        try integers(d, 254, type: 4, [1])
        try integers(d, 256, type: 4, [128])      // 400 x 300 preview fitted to 128
        try integers(d, 257, type: 4, [96])
        try integers(d, 258, type: 3, [8, 8, 8])
        try integers(d, 259, type: 3, [1])
        try integers(d, 262, type: 3, [2])
        try ascii(d, 271, "Nikon")
        try ascii(d, 272, "D750")
        let strip = try entry(d, 273, type: 4, count: 1)
        try integers(d, 274, type: 3, [6])
        try integers(d, 277, type: 3, [3])
        try integers(d, 278, type: 4, [96])
        try integers(d, 279, type: 4, [128 * 96 * 3])
        try integers(d, 284, type: 3, [1])
        try ascii(d, 305, "Latent 0.9")
        try ascii(d, 306, "2026:09:15 19:20:00")
        _ = try entry(d, 330, type: 4, count: 2)
        let xmp = try entry(d, 700, type: 1, count: try MergeXMP.packet(for: result.recipe).utf8.count)
        XCTAssertEqual(String(decoding: reader.rawBytes(xmp), as: UTF8.self), try MergeXMP.packet(for: result.recipe))
        _ = try entry(d, 34665, type: 4, count: 1)
        XCTAssertEqual(reader.rawBytes(try entry(d, 50706, type: 1, count: 4)), [1, 4, 0, 0])
        XCTAssertEqual(reader.rawBytes(try entry(d, 50707, type: 1, count: 4)), [1, 4, 0, 0])
        try ascii(d, 50708, "Nikon D750")

        let matrix = try reader.srationals(entry(d, 50721, type: 10, count: 9))
        XCTAssertEqual(matrix.map(\.0), [9020, -2890, -715, -4535, 12436, 2348, -934, 1919, 7086])
        XCTAssertEqual(Set(matrix.map(\.1)), [10_000])

        let neutral = try reader.rationals(entry(d, 50728, type: 5, count: 3))
        XCTAssertEqual(Set(neutral.map(\.1)), [1_000_000])
        XCTAssertEqual(neutral.map(\.0), [481_203, 1_000_000, 828_479], "1/cam_mul, green = 1")

        // -1.5 before normalisation, and 6.0 needs 3 stops.
        let baseline = try reader.srationals(entry(d, 50730, type: 10, count: 1))
        XCTAssertEqual(Double(baseline[0].0) / Double(baseline[0].1), 1.5)
        try integers(d, 50778, type: 3, [21])

        // The thumbnail strip is 8-bit RGB of the preview.
        let offset = try reader.integers(strip)[0]
        XCTAssertEqual(offset % 2, 0)
        XCTAssertLessThanOrEqual(offset + 128 * 96 * 3, reader.bytes.count)
    }

    func testSubIFD0IsTheTiledHalfFloatLinearRawImage() throws {
        let d = try directories().raw
        XCTAssertEqual(d.entries.map(\.tag), [254, 256, 257, 258, 259, 262, 277, 284, 322, 323, 324, 325, 339,
                                              50714, 50717, 50719, 50720])
        XCTAssertEqual(d.nextOffset, 0, "child directories end their own chain")
        try integers(d, 254, type: 4, [0])
        try integers(d, 256, type: 4, [Self.width])
        try integers(d, 257, type: 4, [Self.height])
        try integers(d, 258, type: 3, [16, 16, 16])
        try integers(d, 259, type: 3, [1])
        try integers(d, 262, type: 3, [34892])
        try integers(d, 277, type: 3, [3])
        try integers(d, 284, type: 3, [1])
        try integers(d, 322, type: 4, [256])
        try integers(d, 323, type: 4, [256])
        try integers(d, 339, type: 3, [3, 3, 3])
        let black = try reader.rationals(entry(d, 50714, type: 5, count: 3))
        XCTAssertTrue(black.allSatisfy { $0 == (0, 1) })
        try integers(d, 50717, type: 4, [1, 1, 1])
        try integers(d, 50719, type: 4, [10, 20])
        try integers(d, 50720, type: 4, [600, 250])

        // 700 x 300 in 256 px tiles: 3 across, 2 down, every tile full size.
        let offsets = try reader.integers(entry(d, 324, type: 4, count: 6))
        let counts = try reader.integers(entry(d, 325, type: 4, count: 6))
        XCTAssertEqual(counts, Array(repeating: 256 * 256 * 6, count: 6))
        XCTAssertTrue(offsets.allSatisfy { $0 % 2 == 0 }, "tiles start on word boundaries")
        XCTAssertEqual(offsets, offsets.sorted(), "tiles are written in the order they're listed")
        for (a, b) in zip(offsets, offsets.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 256 * 256 * 6) }
    }

    func testSubIFD1IsTheJPEGPreview() throws {
        let d = try directories().preview
        XCTAssertEqual(d.entries.map(\.tag), [254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 50970])
        try integers(d, 254, type: 4, [1])
        try integers(d, 256, type: 4, [200])
        try integers(d, 257, type: 4, [150])
        try integers(d, 258, type: 3, [8, 8, 8])
        try integers(d, 259, type: 3, [7])
        try integers(d, 262, type: 3, [6])
        try integers(d, 277, type: 3, [3])
        try integers(d, 278, type: 4, [150])
        try integers(d, 284, type: 3, [1])
        try integers(d, 50970, type: 4, [1])
        let offset = try reader.integers(entry(d, 273, type: 4, count: 1))[0]
        let length = try reader.integers(entry(d, 279, type: 4, count: 1))[0]
        let jpeg = Data(reader.bytes[offset..<(offset + length)])
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "starts with a JPEG SOI marker")
        XCTAssertEqual(Array(jpeg.suffix(2)), [0xFF, 0xD9], "ends with EOI")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [200, 150])
    }

    func testExifIFDCarriesTheReferenceExposure() throws {
        let d = try directories().exif
        XCTAssertEqual(d.entries.map(\.tag), [33434, 33437, 34855, 36864, 36867, 37386, 42034, 42035, 42036])
        XCTAssertTrue(try reader.rationals(entry(d, 33434, type: 5, count: 1))[0] == (1, 250), "1/250 s as 1/250")
        XCTAssertTrue(try reader.rationals(entry(d, 33437, type: 5, count: 1))[0] == (800, 100))
        try integers(d, 34855, type: 3, [100])
        XCTAssertEqual(reader.rawBytes(try entry(d, 36864, type: 7, count: 4)), Array("0231".utf8))
        try ascii(d, 36867, "2026:09:15 19:00:00")
        XCTAssertTrue(try reader.rationals(entry(d, 37386, type: 5, count: 1))[0] == (3500, 100))
        let spec = try reader.rationals(entry(d, 42034, type: 5, count: 4))
        XCTAssertEqual(spec.map { Double($0.0) / Double($0.1) }, [24, 70, 2.8, 2.8])
        try ascii(d, 42035, "Nikon")
        try ascii(d, 42036, "AF-S NIKKOR 24-70mm f/2.8E ED VR")
    }

    /// Directories, out-of-line values and image chunks: every offset even,
    /// every region inside the file, no two regions overlapping.
    func testLayoutIsAlignedAndNothingOverlaps() throws {
        let all = try directories()
        var regions: [(start: Int, end: Int, what: String)] = [(0, 8, "header")]
        for d in [all.ifd0, all.raw, all.preview, all.exif] {
            XCTAssertEqual(d.offset % 2, 0, "directory at \(d.offset)")
            regions.append((d.offset, d.offset + 2 + 12 * d.entries.count + 4, "directory \(d.offset)"))
            XCTAssertEqual(d.entries.map(\.tag), d.entries.map(\.tag).sorted())
            for e in d.entries where !e.isInline {
                XCTAssertEqual(e.valuePosition % 2, 0, "value of tag \(e.tag)")
                regions.append((e.valuePosition, e.valuePosition + e.byteLength, "tag \(e.tag)"))
            }
            if let offsets = d[273] ?? d[324], let counts = d[279] ?? d[325] {
                for (o, c) in zip(try reader.integers(offsets), try reader.integers(counts)) {
                    XCTAssertEqual(o % 2, 0)
                    regions.append((o, o + c, "chunk at \(o)"))
                }
            }
        }
        regions.sort { $0.start < $1.start }
        for (a, b) in zip(regions, regions.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "\(a.what) overlaps \(b.what)")
        }
        XCTAssertLessThanOrEqual(regions.last!.end, reader.bytes.count)
        XCTAssertEqual(result.byteCount, reader.bytes.count)
        // Inline values are left-justified and zero padded.
        for d in [all.ifd0, all.raw, all.preview, all.exif] {
            for e in d.entries where e.isInline && e.byteLength < 4 {
                XCTAssertEqual(Array(reader.bytes[(e.fieldPosition + e.byteLength)..<(e.fieldPosition + 4)]),
                               [UInt8](repeating: 0, count: 4 - e.byteLength), "padding of tag \(e.tag)")
            }
        }
    }

    func testResultDescribesTheStoredFile() throws {
        XCTAssertEqual(result.normalisation.shift, 3)
        XCTAssertEqual(result.baselineExposure, 1.5)
        XCTAssertEqual(result.recipe.baselineShift, 3)
        XCTAssertEqual(result.recipe.clipLevel, 1, "clip level 8 divided by 2^3")
        XCTAssertEqual(result.url.lastPathComponent, "tags.dng")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["tags.dng"])
    }
}
