import XCTest
import ImageIO
import CoreGraphics
@testable import PixelEngine

/// HDR Output's settings and file forms: when a file is full HDR or gets
/// a gain map, the PQ image Core Graphics makes, and the encoders that
/// keep each (HEIC and AVIF), read back with ImageIO.
final class ExportHDROutputTests: XCTestCase {
    func testFullHDRNeedsHEICOrAVIFAndSDRPixelsGetAGainMapInstead() {
        var settings = ExportSettings(format: .heic, hdrGainMap: true)
        XCTAssertTrue(settings.writesGainMap, "Maximize Compatibility is the default")
        XCTAssertFalse(settings.writesFullHDR)
        settings.hdrFull = true
        XCTAssertTrue(settings.writesFullHDR)
        XCTAssertFalse(settings.writesGainMap, "one or the other, never both")
        settings.format = .avif
        XCTAssertTrue(settings.writesFullHDR)
        settings.format = .jpeg
        XCTAssertFalse(settings.writesFullHDR, "JPEG has no 10-bit PQ form")
        XCTAssertTrue(settings.writesGainMap)
        settings.format = .heic
        settings.watermark = ExportWatermark()
        XCTAssertFalse(settings.writesFullHDR)
        XCTAssertTrue(settings.writesGainMap)
        settings.watermark = nil
        settings.outputSharpening = OutputSharpening(medium: .screen, strength: .standard)
        XCTAssertFalse(settings.writesFullHDR)
        settings.outputSharpening = nil
        settings.hdrGainMap = false
        XCTAssertFalse(settings.writesFullHDR || settings.writesGainMap, "HDR Output off writes SDR")
    }

    func testUnavailableFormatsSayWhy() {
        for format in [ExportSettings.Format.avif, .jxl] {
            XCTAssertEqual(format.unavailableReason == nil, format.isAvailable, format.displayName)
            XCTAssertEqual(ExportSettings.Format.unavailable.contains(format), !format.isAvailable)
        }
        XCTAssertTrue(ExportSettings.Format.allCases.allSatisfy { $0.unavailableReason == nil })
    }

    /// Linear 1.0 (SDR white) lands at BT.2408's 203 cd/m², and 4.0 four
    /// times brighter: highlights keep their headroom.
    func testPQImagePutsSDRWhiteAt203Nits() throws {
        let w = 8, h = 2
        var pixels = [Float16](repeating: 1, count: w * h * 4)
        for x in 0..<w { for c in 0..<3 { pixels[(w + x) * 4 + c] = 4 } }   // second row 4.0
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = try Exporter.pqImage(halfFloatRGBA: data, width: w, height: h, colorSpace: .displayP3)
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.itur_2100_PQ as String)
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        let codes = bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        let rowWords = image.bytesPerRow / 2
        XCTAssertEqual(Self.nits(codes[0]), 203, accuracy: 3)
        XCTAssertEqual(Self.nits(codes[rowWords]), 812, accuracy: 12)
    }

    /// Full HDR files read back as 10-bit PQ, and an AVIF keeps a gain map
    /// as a HEIC does.
    func testHEICAndAVIFKeepTheirHDRForms() throws {
        let w = 32, h = 16
        let ramp = (0..<(w * h)).flatMap { i -> [Float16] in
            let v = Float16(Float(i % w) / Float(w) * 4); return [v, v, v, 1]
        }
        let pq = try Exporter.pqImage(halfFloatRGBA: ramp.withUnsafeBytes { Data($0) }, width: w, height: h,
                                      colorSpace: .sRGB)
        for format in [ExportSettings.Format.heic, .avif] where format.isAvailable {
            var settings = ExportSettings(format: format, quality: 0.9, hdrGainMap: true)
            settings.hdrFull = true
            let data = try Exporter.encode(Exporter.EncodableImage(image: pq), settings: settings)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 10, format.displayName)
            XCTAssertTrue((properties[kCGImagePropertyProfileName as String] as? String ?? "").contains("PQ"),
                          "\(format.displayName) isn't tagged PQ")
        }

        guard ExportSettings.Format.avif.isAvailable else { return }
        let sdr = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let range = GainMap.log2Range(headroom: 4)
        let map = GainMap(width: w / 2, height: h / 2, pixels: Data(repeating: 200, count: w / 2 * h / 2 * 4),
                          headroom: 4, minimumLog2: range.minimum, maximumLog2: range.maximum)
        let data = try Exporter.encode(Exporter.EncodableImage(image: sdr, gainMap: map),
                                       settings: ExportSettings(format: .avif, hdrGainMap: true))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap))
    }

    /// SMPTE ST 2084: a PQ code value (16-bit) to cd/m².
    static func nits(_ code: UInt16) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let e = pow(Double(code) / 65535, 1 / m2)
        return 10000 * pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1)
    }
}
