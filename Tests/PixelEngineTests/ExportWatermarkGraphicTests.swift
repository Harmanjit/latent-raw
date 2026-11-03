import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import PixelEngine

/// The watermark's graphic, font and rotation, and that presets saved
/// before them read and write as they did.
final class ExportWatermarkGraphicTests: XCTestCase {
    /// A 40 x 20 PNG: opaque red on the left half, transparent on the right.
    static func logoPNG() throws -> Data {
        let (w, h) = (40, 20)
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testGraphicIsPlacedScaledAndStampedInItsOwnColours() throws {
        var mark = ExportWatermark()
        mark.style = .graphic
        XCTAssertTrue(mark.isEmpty, "no graphic chosen yet")
        mark.imageData = try Self.logoPNG()
        mark.imageSize = 0.5
        mark.opacity = 1
        mark.corner = .topLeft
        XCTAssertFalse(mark.isEmpty)

        let (w, h) = (100, 80)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let placed = try XCTUnwrap(PlacedWatermark(mark, imageWidth: w, imageHeight: h, space: space))
        // Its longer side is half the picture's short edge.
        XCTAssertEqual(placed.width, 40)
        XCTAssertEqual(placed.height, 20)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { placed.composite(into: $0, imageWidth: w, imageHeight: h, bitsPerComponent: 8) }
        let opaque = ((placed.y + 10) * w + placed.x + 5) * 4
        XCTAssertEqual(bytes[opaque], 255, "red where the logo is solid")
        XCTAssertEqual(bytes[opaque + 1], 0)
        let clear = ((placed.y + 10) * w + placed.x + 35) * 4
        XCTAssertEqual(bytes[clear], 0, "the photo shows through where the logo is transparent")
    }

    func testRotationTurnsTheBox() throws {
        var mark = ExportWatermark(text: "Latent", corner: .bottomRight)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let flat = try XCTUnwrap(PlacedWatermark(mark, imageWidth: 400, imageHeight: 300, space: space))
        mark.rotation = 270
        let turned = try XCTUnwrap(PlacedWatermark(mark, imageWidth: 400, imageHeight: 300, space: space))
        XCTAssertEqual(turned.width, flat.height)
        XCTAssertEqual(turned.height, flat.width)
        XCTAssertEqual(flat.coverage.reduce(0) { $0 + Int($1) }, turned.coverage.reduce(0) { $0 + Int($1) },
                       "the same ink, turned")
        // Still inside its corner.
        XCTAssertLessThanOrEqual(turned.x + turned.width, 400)
        XCTAssertLessThanOrEqual(turned.y + turned.height, 300)
        XCTAssertEqual(ExportWatermark.normalisedRotation(-90), 270)
        XCTAssertEqual(ExportWatermark.normalisedRotation(450), 90)
    }

    func testFontIsUsedWhenInstalledAndFallsBackOtherwise() {
        XCTAssertNotNil(PlacedWatermark.font(named: "Helvetica", size: 20))
        XCTAssertNil(PlacedWatermark.font(named: "No Such Font Family 123", size: 20))
        let system = PlacedWatermark.rasterise("Latent", fontSize: 30)
        let missing = PlacedWatermark.rasterise("Latent", fontName: "No Such Font Family 123", fontSize: 30)
        XCTAssertEqual(system?.coverage, missing?.coverage, "an unknown font is the system font")
        let other = PlacedWatermark.rasterise("Latent", fontName: "Courier", fontSize: 30)
        XCTAssertNotEqual(system?.coverage, other?.coverage)
    }

    /// A preset saved before graphics, fonts and rotation decodes to text
    /// with the system font, unturned; and a default watermark encodes to
    /// exactly the keys it always had.
    func testOlderPresetsReadAndWriteAsBefore() throws {
        let old = #"{"text":"© {year}","corner":"topLeft","size":0.05,"opacity":0.5,"red":1,"green":0,"blue":0}"#
        let decoded = try JSONDecoder().decode(ExportWatermark.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.style, .text)
        XCTAssertNil(decoded.fontName)
        XCTAssertEqual(decoded.rotation, 0)
        XCTAssertNil(decoded.imageData)
        XCTAssertEqual(decoded.corner, .topLeft)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportWatermark())) as? [String: Any]
        XCTAssertEqual(Set(encoded?.keys ?? [:].keys), ["text", "corner", "size", "opacity", "red", "green", "blue"])

        var full = ExportWatermark()
        full.style = .graphic
        full.fontName = "Courier"
        full.rotation = 90
        full.imageData = try Self.logoPNG()
        full.imageSize = 0.3
        let back = try JSONDecoder().decode(ExportWatermark.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(back, full)
    }
}
