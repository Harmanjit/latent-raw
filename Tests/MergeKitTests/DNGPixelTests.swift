import Metal
import XCTest
@testable import MergeKit

/// The stored samples, bit for bit: odd sizes, padded edge tiles, deflate,
/// normalisation, and every pixel source.
final class DNGPixelTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws { folder = try Fixtures.temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func write(_ pixels: LinearRawPixelSource, maximum: Float, tileSize: Int = 512,
                       compression: DNGTileCompression = .none, name: String = "pixels.dng") throws
        -> (result: MergeDNGWriteResult, reader: TestTIFFReader, raw: TestTIFFReader.Directory) {
        var writer = LinearRawDNGWriter(tileSize: tileSize, compression: compression,
                                        previewLongEdge: 64, thumbnailLongEdge: 32)
        writer.availableCapacity = { _ in nil }
        let result = try writer.write(pixels, maximum: maximum, metadata: try Fixtures.metadata(),
                                      recipe: Fixtures.recipe(), preview: Fixtures.previewImage(width: 64, height: 48),
                                      to: folder.appendingPathComponent(name))
        let reader = try TestTIFFReader(url: result.url)
        let ifd0 = try reader.directory(at: reader.firstDirectoryOffset())
        let raw = try reader.directory(at: reader.integers(XCTUnwrap(ifd0[330]))[0])
        return (result, reader, raw)
    }

    /// Pixels divided by 2^shift, as the file should hold them.
    private func stored(_ pixels: [Float16], shift: Int) -> [Float16] {
        pixels.map { $0 * Float16(Float(sign: .plus, exponent: -shift, significand: 1)) }
    }

    private func assertBitIdentical(_ actual: [Float16], _ expected: [Float16], file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let mismatch = zip(actual, expected).enumerated().first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
        XCTAssertNil(mismatch, "first differing sample \(mismatch ?? -1)", file: file, line: line)
    }

    func testOddSizesRoundTripBitForBitWithZeroPaddedEdgeTiles() throws {
        for (width, height, tile) in [(517, 389, 512), (130, 77, 32), (1, 1, 16), (512, 513, 512)] {
            let pixels = Fixtures.pixels(width: width, height: height, maximum: 0.9)
            let (_, reader, raw) = try write(try .buffer(pixels, width: width, height: height), maximum: 0.9,
                                             tileSize: tile, name: "odd-\(width)x\(height).dng")
            let (decoded, tiles) = try reader.tiledHalfFloats(raw)
            assertBitIdentical(decoded, pixels)

            let across = (width + tile - 1) / tile, down = (height + tile - 1) / tile
            XCTAssertEqual(tiles.count, across * down, "\(width)x\(height)")
            // Every sample outside the image, in every edge tile, is +0.
            for (index, bytes) in tiles.enumerated() {
                XCTAssertEqual(bytes.count, tile * tile * 6)
                let x0 = (index % across) * tile, y0 = (index / across) * tile
                var nonZeroPadding = 0
                for y in 0..<tile {
                    for x in 0..<tile where x0 + x >= width || y0 + y >= height {
                        let at = (y * tile + x) * 6
                        if bytes[at..<(at + 6)].contains(where: { $0 != 0 }) { nonZeroPadding += 1 }
                    }
                }
                XCTAssertEqual(nonZeroPadding, 0, "padding pixels in tile \(index), \(width)x\(height)")
            }
        }
    }

    func testNormalisationDividesEverySampleExactly() throws {
        let (width, height) = (300, 200)
        let pixels = Fixtures.pixels(width: width, height: height, maximum: 100)
        let (result, reader, raw) = try write(try .buffer(pixels, width: width, height: height), maximum: 100)
        XCTAssertEqual(result.normalisation.shift, 7, "100 fits under 2^7 = 128")
        let decoded = try reader.tiledHalfFloats(raw).pixels
        assertBitIdentical(decoded, stored(pixels, shift: 7))
        XCTAssertLessThanOrEqual(ExposureNormalisation.maximum(of: decoded), 1)
        XCTAssertEqual(ExposureNormalisation.maximum(of: decoded), Float(Float16(100)) / 128)
    }

    /// Values so small that dividing them leaves half floats' normal range
    /// (below 2^-14) must round exactly as half-float arithmetic does, and
    /// signs, zeros and ±1 must survive.
    func testNormalisationRoundsTinyValuesLikeHalfFloatArithmetic() throws {
        let special: [Float16] = [0, -0.0, 1, -1, 8, -8, 0.001, -0.001, 0.0003, 7e-5, Float16.leastNormalMagnitude,
                                  Float16.leastNonzeroMagnitude, 3 * Float16.leastNonzeroMagnitude, 0.000123]
        let width = special.count, height = 1
        let pixels = special.flatMap { [$0, $0 / 2, -$0] }
        let (result, reader, raw) = try write(try .buffer(pixels, width: width, height: height), maximum: 8, tileSize: 16)
        XCTAssertEqual(result.normalisation.shift, 3)
        assertBitIdentical(try reader.tiledHalfFloats(raw).pixels, stored(pixels, shift: 3))
    }

    func testDeflateTilesDecodeToTheSameSamples() throws {
        let (width, height) = (300, 130)
        let pixels = Fixtures.pixels(width: width, height: height, maximum: 3)
        for predictor in FloatPredictor.allCases {
            let (result, reader, raw) = try write(try .buffer(pixels, width: width, height: height), maximum: 3,
                                                  tileSize: 128, compression: .deflate(predictor),
                                                  name: "deflate-\(predictor.rawValue).dng")
            XCTAssertEqual(try reader.integers(XCTUnwrap(raw[259])), [8])
            XCTAssertEqual(try reader.integers(XCTUnwrap(raw[317])), [Int(predictor.rawValue)])
            let decoded = try reader.tiledHalfFloats(raw).pixels
            assertBitIdentical(decoded, stored(pixels, shift: 2))
            XCTAssertEqual(result.byteCount, reader.bytes.count)
            if predictor != .none {
                XCTAssertLessThan(result.byteCount, width * height * 6, "the predictor makes the ramp compress")
            }
        }
    }

    func testRGBABufferSourceDropsAlpha() throws {
        let (width, height) = (70, 33)
        let rgb = Fixtures.pixels(width: width, height: height, maximum: 1)
        var rgba: [Float16] = []
        for i in 0..<(width * height) { rgba += [rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2], 42] }
        let (_, reader, raw) = try write(try .buffer(rgba, width: width, height: height, channelsPerPixel: 4),
                                         maximum: 1, tileSize: 32)
        assertBitIdentical(try reader.tiledHalfFloats(raw).pixels, rgb)
    }

    func testClosureSourceIsAskedForEachTileInReadingOrder() throws {
        let (width, height) = (100, 40)
        let pixels = Fixtures.pixels(width: width, height: height, maximum: 1)
        let buffer = try LinearRawPixelSource.buffer(pixels, width: width, height: height)
        nonisolated(unsafe) var asked: [PixelRegion] = []
        let source = LinearRawPixelSource(width: width, height: height) { region, rgb in
            asked.append(region)
            try buffer.fill(region, rgb)
        }
        _ = try write(source, maximum: 1, tileSize: 32)
        XCTAssertEqual(asked, [
            PixelRegion(x: 0, y: 0, width: 32, height: 32), PixelRegion(x: 32, y: 0, width: 32, height: 32),
            PixelRegion(x: 64, y: 0, width: 32, height: 32), PixelRegion(x: 96, y: 0, width: 4, height: 32),
            PixelRegion(x: 0, y: 32, width: 32, height: 8), PixelRegion(x: 32, y: 32, width: 32, height: 8),
            PixelRegion(x: 64, y: 32, width: 32, height: 8), PixelRegion(x: 96, y: 32, width: 4, height: 8),
        ])
    }

    func testTextureSourceMatchesTheBufferSourceForPrivateAndSharedTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let (width, height) = (300, 211)
        let rgb = Fixtures.pixels(width: width, height: height, maximum: 5)
        var rgba: [Float16] = []
        rgba.reserveCapacity(width * height * 4)
        for i in 0..<(width * height) { rgba += [rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2], 1] }

        for storage in [MTLStorageMode.shared, .private] {
            let texture = try TextureFixtures.texture(rgba, width: width, height: height, storage: storage,
                                                      device: device, queue: queue)
            XCTAssertEqual(try ExposureNormalisation.maximum(of: texture, commandQueue: queue), 5)
            // A band shorter than a tile exercises the slicing too.
            let source = try LinearRawPixelSource.texture(texture, commandQueue: queue, bandHeight: 50)
            let (result, reader, raw) = try write(source, maximum: 5, tileSize: 128, name: "texture-\(storage.rawValue).dng")
            XCTAssertEqual(result.normalisation.shift, 3)
            assertBitIdentical(try reader.tiledHalfFloats(raw).pixels, stored(rgb, shift: 3))
        }
    }

    func testTextureSourceRefusesOtherPixelFormats() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4,
                                                                  mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        XCTAssertThrowsError(try LinearRawPixelSource.texture(texture, commandQueue: queue))
        XCTAssertThrowsError(try ExposureNormalisation.maximum(of: texture, commandQueue: queue))
    }
}

enum TextureFixtures {
    /// An rgba16Float texture holding `rgba`, in the given storage mode.
    static func texture(_ rgba: [Float16], width: Int, height: Int, storage: MTLStorageMode,
                        device: MTLDevice, queue: MTLCommandQueue) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let shared = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        rgba.withUnsafeBytes {
            shared.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        guard storage == .private else { return shared }
        descriptor.storageMode = .private
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: shared, to: copy)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return copy
    }
}
