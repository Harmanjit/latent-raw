import XCTest
import Metal
import ImageIO
@testable import PixelEngine

/// The export watermark: tokens, placement, lenient decoding, what it does
/// to the file's pixels (only its box changes, in 8 and 16 bits, and nothing
/// at all without one), its gain-map neutralising, and that an in-memory
/// encode is the size of the file.
final class ExportWatermarkTests: XCTestCase {
    nonisolated(unsafe) private static var sharedGPU: GPUContext?

    private func gpu() throws -> GPUContext {
        if let gpu = Self.sharedGPU { return gpu }
        let gpu = try GPUContext()
        Self.sharedGPU = gpu
        return gpu
    }

    func testTokensAreFilledInAnyCase() {
        var date = DateComponents(); date.year = 2019; date.month = 12; date.day = 31; date.hour = 23
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let captured = calendar.date(from: date)!
        let mark = ExportWatermark(text: "© {YEAR} Ana · {name} {Year}")
        XCTAssertEqual(mark.resolved(fileName: "DSC_0042", captureDate: captured, timeZone: utc).text,
                       "© 2019 Ana · DSC_0042 2019")
        XCTAssertEqual(ExportWatermark(text: "{camera}").resolved(fileName: "x", captureDate: captured).text, "{camera}",
                       "unknown tokens stay as typed")
        XCTAssertTrue(ExportWatermark(text: "  \n").isEmpty)
        XCTAssertFalse(ExportWatermark().isEmpty)
    }

    func testCornersKeepTheMarginFromTheShortEdge() {
        // 1000x600: short edge 600, margin 15.
        func origin(_ corner: ExportWatermark.Corner) -> (Int, Int) {
            let o = ExportWatermark(corner: corner).origin(textWidth: 100, textHeight: 20, imageWidth: 1000, imageHeight: 600)
            return (o.x, o.y)
        }
        XCTAssertTrue(origin(.topLeft) == (15, 15))
        XCTAssertTrue(origin(.topRight) == (885, 15))
        XCTAssertTrue(origin(.bottomLeft) == (15, 565))
        XCTAssertTrue(origin(.bottomRight) == (885, 565))
        XCTAssertEqual(ExportWatermark(size: 0.05).fontPixelSize(imageWidth: 1000, imageHeight: 600), 30, accuracy: 1e-4)
    }

    func testDecodingIsLenientAndClamped() throws {
        let empty = try JSONDecoder().decode(ExportWatermark.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ExportWatermark())
        let wild = try JSONDecoder().decode(ExportWatermark.self, from: Data(#"{"text":"hi","corner":"middle","size":9,"opacity":-1,"red":2}"#.utf8))
        XCTAssertEqual(wild.text, "hi")
        XCTAssertEqual(wild.corner, .bottomRight)
        XCTAssertEqual(wild.size, ExportWatermark.sizeRange.upperBound)
        XCTAssertEqual(wild.opacity, ExportWatermark.opacityRange.lowerBound)
        XCTAssertEqual(wild.red, 1)
        let round = ExportWatermark(text: "© {year}", corner: .topLeft, size: 0.05, opacity: 0.4, red: 0.2, green: 0.3, blue: 0.4)
        XCTAssertEqual(try JSONDecoder().decode(ExportWatermark.self, from: JSONEncoder().encode(round)), round)
    }

    func testTextRasterisesToCoverage() throws {
        let raster = try XCTUnwrap(PlacedWatermark.rasterise("© 2026 Latent", fontSize: 40))
        XCTAssertGreaterThan(raster.width, 150)
        XCTAssertGreaterThan(raster.height, 35)
        XCTAssertLessThan(raster.height, 70)
        XCTAssertEqual(raster.coverage.count, raster.width * raster.height)
        XCTAssertEqual(raster.coverage.max(), 255, "solid strokes")
        XCTAssertEqual(raster.coverage.first, 0, "the padding is empty")
        XCTAssertNil(PlacedWatermark.rasterise("", fontSize: 40))
    }

    /// Only the text's box changes, towards the text's colour; the rest of
    /// the file is exactly what it is without a watermark.
    func testWatermarkChangesOnlyItsBox() throws {
        let gpu = try gpu()
        let (w, h) = (320, 200)
        let texture = try grey(gpu, width: w, height: h, value: 0.25)
        let exporter = Exporter(gpu: gpu)
        for bits in [8, 16] {
            let plain = try exporter.cgImage(from: texture, colorSpace: .sRGB, bitsPerComponent: bits)
            let mark = ExportWatermark(text: "WWWW", corner: .bottomRight, size: 0.1, opacity: 1)
            let stamped = try exporter.cgImage(from: texture, colorSpace: .sRGB, bitsPerComponent: bits, watermark: mark)
            let placed = try XCTUnwrap(PlacedWatermark(mark, imageWidth: w, imageHeight: h, colorSpace: .sRGB))
            let box = try XCTUnwrap(placed.clipped(toWidth: w, height: h))
            let a = samples(plain), b = samples(stamped)
            XCTAssertEqual(a.count, b.count)
            var changedInside = 0, brightest = 0.0
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let inside = x >= box.x0 && x < box.x1 && y >= box.y0 && y < box.y1
                    if !inside {
                        if a[i] != b[i] { XCTFail("\(bits)-bit pixel \(x),\(y) outside the box changed"); return }
                    } else if b[i] != a[i] {
                        changedInside += 1
                        brightest = max(brightest, b[i])
                    }
                }
            }
            XCTAssertGreaterThan(changedInside, 50, "\(bits)-bit: the text drew")
            XCTAssertEqual(brightest, 1, accuracy: 0.002, "\(bits)-bit: solid white strokes at full opacity")
            // Bottom right, inside the margin (5 px of a 200 px short edge).
            XCTAssertEqual(box.x1, w - 5)
            XCTAssertEqual(box.y1, h - 5)
        }
    }

    func testOpacityBlendsTowardsTheColour() throws {
        let mark = ExportWatermark(text: "I", size: 0.5, opacity: 0.5, red: 1, green: 0, blue: 0)
        let placed = try XCTUnwrap(PlacedWatermark(mark, imageWidth: 100, imageHeight: 100, colorSpace: .sRGB))
        var pixels = [UInt8](repeating: 100, count: 100 * 100 * 4)
        pixels.withUnsafeMutableBytes { placed.composite(into: $0, imageWidth: 100, imageHeight: 100, bitsPerComponent: 8) }
        let solid = placed.coverage.firstIndex(of: 255).map { i -> Int in
            let cx = i % placed.width, cy = i / placed.width
            return ((cy + placed.y) * 100 + cx + placed.x) * 4
        }
        let i = try XCTUnwrap(solid)
        XCTAssertEqual(Int(pixels[i]), 178, accuracy: 1)       // 100 + (255 - 100) / 2
        XCTAssertEqual(Int(pixels[i + 1]), 50, accuracy: 1)
        XCTAssertEqual(Int(pixels[i + 2]), 50, accuracy: 1)
        XCTAssertEqual(pixels[i + 3], 100, "the unused byte is left alone")
    }

    func testP3ColourIsConverted() {
        let red = ExportWatermark(red: 1, green: 0, blue: 0)
        let p3 = PlacedWatermark.encodedColor(red, in: .displayP3)
        XCTAssertLessThan(p3.x, 0.95, "sRGB red sits inside P3")
        XCTAssertGreaterThan(p3.y, 0.1)
        XCTAssertEqual(PlacedWatermark.encodedColor(red, in: .sRGB), SIMD3<Float>(1, 0, 0))
    }

    func testGainMapHasNoGainUnderSolidText() throws {
        let mark = ExportWatermark(text: "I", corner: .topLeft, size: 0.6, opacity: 1)
        let placed = try XCTUnwrap(PlacedWatermark(mark, imageWidth: 64, imageHeight: 64, colorSpace: .sRGB))
        let map = GainMap(width: 32, height: 32, pixels: Data(repeating: 255, count: 32 * 32 * 4), headroom: 4,
                          minimumLog2: -1, maximumLog2: 3)
        let out = placed.neutralising(map, imageWidth: 64, imageHeight: 64)
        let bytes = [UInt8](out.pixels)
        // Neutral is 255 * 1 / 4: gain 0 in a -1...3 range.
        XCTAssertTrue(bytes.contains(64), "a pixel wholly under the text has no gain")
        XCTAssertEqual(bytes[(31 * 32 + 31) * 4], 255, "far from the text the map is untouched")
    }

    /// The in-memory encode the size estimate and the comparison use is the
    /// file `write` makes, byte for byte in size.
    func testInMemoryEncodeIsTheFileSize() throws {
        let gpu = try gpu()
        let texture = try grey(gpu, width: 256, height: 160, value: 0.6)
        let exporter = Exporter(gpu: gpu)
        var metadata = ExportMetadata(); metadata.cameraModel = "Test"; metadata.keywords = ["a"]
        for format in [ExportSettings.Format.jpeg, .heic, .png] {
            let settings = ExportSettings(format: format, quality: 0.7, watermark: ExportWatermark(text: "© 2026"))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("latent-wm-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try exporter.write(texture, to: url, settings: settings, colorSpace: .sRGB, metadata: metadata)
            let prepared = try exporter.encodableImage(texture, settings: settings, colorSpace: .sRGB)
            let data = try Exporter.encode(prepared, settings: settings, metadata: metadata)
            let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertEqual(data.count, fileSize, format.displayName)
        }
    }

    // MARK: - Helpers

    private func grey(_ gpu: GPUContext, width: Int, height: Int, value: Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        var texels = [Float16](repeating: Float16(value), count: width * height * 4)
        for i in 0..<(width * height) { texels[i * 4 + 3] = 1 }
        texels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    /// Samples as 0...1, four per pixel, whatever the bit depth.
    private func samples(_ image: CGImage) -> [Double] {
        let data = image.dataProvider!.data! as Data
        if image.bitsPerComponent == 16 {
            return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }.map { Double(UInt16(littleEndian: $0)) / 65535 }
        }
        return data.map { Double($0) / 255 }
    }
}
