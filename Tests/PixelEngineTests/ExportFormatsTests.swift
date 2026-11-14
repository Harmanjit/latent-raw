import XCTest
import CoreGraphics
import ImageIO
import Metal
import ColorKit
@testable import PixelEngine

/// Borders, the deeper PNG, HEIC and TIFF files, OpenEXR, PDF, the stored
/// rendering intent and the metadata extras, on synthetic pixels: none of
/// it needs a raw, and every default leaves an export as it was.
final class ExportFormatsTests: XCTestCase {
    /// A `w` × `h` RGBX image of one colour, 8 or 16 bits, in sRGB, laid
    /// out as the exporter makes its images.
    private func solid(_ w: Int, _ h: Int, bits: Int = 8, rgb: (Double, Double, Double) = (0.8, 0.3, 0.2)) -> CGImage {
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: w * bits / 2,
                                space: space, bitmapInfo: info)!
        context.setFillColor(CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A distinct corner pixel, to check the copy lands where it should.
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: h - 1, width: 1, height: 1))
        return context.makeImage()!
    }

    /// The 8-bit RGBX bytes of pixel (x, y), counted from the top.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let bpp = image.bitsPerPixel / 8
        let start = y * image.bytesPerRow + x * bpp
        return Array(data[start..<start + bpp])
    }

    private func properties(of data: Data) -> [String: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    // MARK: - Border

    func testBorderLayoutPercentAndPixels() {
        var border = ExportBorder()
        border.size = 10
        XCTAssertEqual(border.layout(width: 200, height: 100),
                       ExportBorder.Layout(width: 240, height: 140, imageX: 20, imageY: 20))
        border.unit = .pixels
        border.size = 7
        XCTAssertEqual(border.layout(width: 200, height: 100),
                       ExportBorder.Layout(width: 214, height: 114, imageX: 7, imageY: 7))
    }

    func testBorderAspectGrowsTheShortSidesAndPositions() {
        var border = ExportBorder()
        border.size = 0
        border.aspect = .square
        XCTAssertEqual(border.layout(width: 300, height: 200),
                       ExportBorder.Layout(width: 300, height: 300, imageX: 0, imageY: 50))
        // 4:5 portrait round a landscape picture: the Instagram case.
        border.aspect = .fourFive
        border.orientation = .portrait
        let l = border.layout(width: 400, height: 300)
        XCTAssertEqual(l.width, 400)
        XCTAssertEqual(l.height, 500)
        border.positionY = 0
        XCTAssertEqual(border.layout(width: 400, height: 300).imageY, 0)
        // Matching the picture turns 4:5 into 5:4 for a landscape photo.
        border.orientation = .matchPicture
        border.positionY = 0.5
        XCTAssertEqual(border.layout(width: 400, height: 300),
                       ExportBorder.Layout(width: 400, height: 320, imageX: 0, imageY: 10))
        border.aspect = .custom
        border.customWidth = 2
        border.customHeight = 1
        XCTAssertEqual(border.layout(width: 100, height: 100).width, 200)
    }

    func testBorderCopiesThePictureUnchangedAndDrawsTheCanvas() throws {
        for bits in [8, 16] {
            let image = solid(10, 6, bits: bits)
            var border = ExportBorder()
            border.unit = .pixels
            border.size = 4
            border.color = .white
            border.lineWidth = 1
            border.lineOffset = 1
            border.lineColor = .black
            let framed = try border.apply(to: image)
            XCTAssertEqual(framed.width, 18)
            XCTAssertEqual(framed.height, 14)
            XCTAssertEqual(framed.bitsPerComponent, bits)
            for y in 0..<6 {
                for x in 0..<10 {
                    XCTAssertEqual(pixel(framed, x + 4, y + 4), pixel(image, x, y), "pixel \(x),\(y) at \(bits) bits")
                }
            }
            let top = UInt8(bits == 8 ? 255 : 255)
            XCTAssertEqual(pixel(framed, 0, 0).prefix(3).allSatisfy { $0 == top }, true, "border is white")
            // The line: one pixel wide, one pixel out from the picture.
            XCTAssertEqual(pixel(framed, 2, 6).prefix(bits / 8 * 3).allSatisfy { $0 == 0 }, true, "line is black")
            XCTAssertEqual(pixel(framed, 3, 6).prefix(3).allSatisfy { $0 == top }, true, "gap is the border colour")
        }
    }

    func testBorderDecodesLenientlyAndSettingsStayPlainWithout() throws {
        let partial = try JSONDecoder().decode(ExportBorder.self, from: Data(#"{"size":3,"aspect":"nonsense"}"#.utf8))
        XCTAssertEqual(partial.size, 3)
        XCTAssertEqual(partial.aspect, .none)
        XCTAssertEqual(try JSONDecoder().decode(ExportBorder.self, from: Data("{}".utf8)), ExportBorder())

        var settings = ExportSettings(format: .jpeg, hdrGainMap: true)
        XCTAssertTrue(settings.writesGainMap)
        settings.border = ExportBorder()
        XCTAssertFalse(settings.writesGainMap, "a bordered file is SDR")
        settings.border?.size = 0
        XCTAssertFalse(settings.hasBorder)
        XCTAssertTrue(settings.writesGainMap)
    }

    // MARK: - Bit depths

    func testDefaultBitDepthsAreUnchanged() {
        XCTAssertEqual(ExportSettings(format: .png).bitsPerComponent, 8)
        XCTAssertEqual(ExportSettings(format: .heic).bitsPerComponent, 8)
        XCTAssertEqual(ExportSettings(format: .jpeg).bitsPerComponent, 8)
        var tiff = ExportSettings(format: .tiff)
        XCTAssertEqual(tiff.bitsPerComponent, 16)
        tiff.tiffBitDepth = 8
        XCTAssertEqual(tiff.bitsPerComponent, 8)
        tiff.tiffBitDepth = 32
        XCTAssertEqual(tiff.bitsPerComponent, 16, "a float TIFF renders at 16 and widens as it is encoded")
        XCTAssertTrue(tiff.writesFloatTIFF)
        var png = ExportSettings(format: .png)
        png.pngBitDepth = 16
        XCTAssertEqual(png.bitsPerComponent, 16)
        var heic = ExportSettings(format: .heic)
        heic.heicBitDepth = 10
        XCTAssertEqual(heic.bitsPerComponent, 16)
        // Neither option touches another format.
        var jpeg = ExportSettings(format: .jpeg)
        jpeg.pngBitDepth = 16
        jpeg.heicBitDepth = 10
        XCTAssertEqual(jpeg.bitsPerComponent, 8)
    }

    func testSixteenBitPNGAndTenBitHEIC() throws {
        var png = ExportSettings(format: .png)
        png.pngBitDepth = 16
        let pngData = try Exporter.encode(.init(image: solid(16, 8, bits: 16)), settings: png)
        XCTAssertEqual(properties(of: pngData)[kCGImagePropertyDepth as String] as? Int, 16)

        var heic = ExportSettings(format: .heic)
        heic.heicBitDepth = 10
        let heicData = try Exporter.encode(.init(image: solid(64, 32, bits: 16)), settings: heic)
        XCTAssertEqual(properties(of: heicData)[kCGImagePropertyDepth as String] as? Int, 10)
        let plain = try Exporter.encode(.init(image: solid(64, 32)), settings: ExportSettings(format: .heic))
        XCTAssertEqual(properties(of: plain)[kCGImagePropertyDepth as String] as? Int, 8)
    }

    func testFloatAndGreyscaleTIFF() throws {
        var float = ExportSettings(format: .tiff)
        float.tiffBitDepth = 32
        let floatProps = properties(of: try Exporter.encode(.init(image: solid(8, 8, bits: 16)), settings: float))
        XCTAssertEqual(floatProps[kCGImagePropertyDepth as String] as? Int, 32)
        XCTAssertEqual(floatProps[kCGImagePropertyIsFloat as String] as? Bool, true)

        var grey = ExportSettings(format: .tiff)
        grey.greyscaleWhenMonochrome = true
        let colour = properties(of: try Exporter.encode(.init(image: solid(8, 8, bits: 16)), settings: grey))
        XCTAssertEqual(colour[kCGImagePropertyColorModel as String] as? String, "RGB", "a colour edit stays colour")
        grey.editIsMonochrome = true
        let mono = properties(of: try Exporter.encode(.init(image: solid(8, 8, bits: 16)), settings: grey))
        XCTAssertEqual(mono[kCGImagePropertyColorModel as String] as? String, "Gray")
        XCTAssertEqual(mono[kCGImagePropertyDepth as String] as? Int, 16)
        grey.tiffBitDepth = 32
        let monoFloat = properties(of: try Exporter.encode(.init(image: solid(8, 8, bits: 16)), settings: grey))
        XCTAssertEqual(monoFloat[kCGImagePropertyColorModel as String] as? String, "Gray")
        XCTAssertEqual(monoFloat[kCGImagePropertyDepth as String] as? Int, 32)
    }

    func testMonochromeEdit() {
        var p = EditParameters()
        XCTAssertFalse(ExportPlan.isMonochrome(p))
        p.colour.blackAndWhite.enabled = true
        XCTAssertTrue(ExportPlan.isMonochrome(p))
        p.colour.calibration.shadowTint = 10
        XCTAssertFalse(ExportPlan.isMonochrome(p), "a tinted black and white has colour")
    }

    // MARK: - OpenEXR

    func testEXREncodesHalfAndFloatWhereAvailable() throws {
        try XCTSkipUnless(ExportSettings.Format.exr.isAvailable, "this Mac's ImageIO has no OpenEXR encoder")
        XCTAssertTrue(ExportSettings.Format.menu.contains(.exr))
        XCTAssertFalse(ExportSettings.Format.available.contains(.exr))
        XCTAssertFalse(ExportSettings.Format.allCases.contains(.exr))
        var settings = ExportSettings(format: .exr)
        let half = properties(of: try Exporter.encode(.init(image: solid(8, 8, bits: 16)), settings: settings))
        XCTAssertEqual(half[kCGImagePropertyDepth as String] as? Int, 16)
        XCTAssertEqual(half[kCGImagePropertyIsFloat as String] as? Bool, true)
        settings.exr.half = false
        let full = properties(of: try Exporter.encode(.init(image: solid(8, 8, bits: 16)), settings: settings))
        XCTAssertEqual(full[kCGImagePropertyDepth as String] as? Int, 32)
    }

    func testEXRFromALinearTextureKeepsHighlights() throws {
        try XCTSkipUnless(ExportSettings.Format.exr.isAvailable, "this Mac's ImageIO has no OpenEXR encoder")
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 1,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // A neutral grey well above SDR white, and a dark one.
        var pixels: [Float16] = [4, 4, 4, 1, 0.1, 0.1, 0.1, 1]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 16)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-exr-\(UUID().uuidString).exr")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = ExportSettings(format: .exr)
        settings.exr.half = false
        let size = try Exporter.writeEXR(linearRec2020: texture, commandQueue: queue, settings: settings, to: url)
        XCTAssertEqual(size.width, 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 32)
        let data = image.dataProvider!.data! as Data
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(8)) }
        // Neutral greys have the same values in every set of primaries.
        XCTAssertEqual(floats[0], 4, accuracy: 0.02)
        XCTAssertEqual(floats[1], 4, accuracy: 0.02)
        XCTAssertEqual(floats[4], 0.1, accuracy: 0.002)
    }

    // MARK: - PDF

    func testPDFPagesFitTheImageOrThePaper() throws {
        var options = ExportPDFOptions()
        options.marginMM = 0
        let fit = options.layout(pixelWidth: 3000, pixelHeight: 2000, ppi: 300, hasCaption: false)
        XCTAssertEqual(fit.page.width, 720, accuracy: 0.01)
        XCTAssertEqual(fit.page.height, 480, accuracy: 0.01)
        options.pageSize = .a4
        options.marginMM = 10
        let a4 = options.layout(pixelWidth: 3000, pixelHeight: 2000, ppi: 300, hasCaption: true)
        XCTAssertGreaterThan(a4.page.width, a4.page.height, "A4 turns to match a landscape photo")
        XCTAssertEqual(a4.image.width / a4.image.height, 1.5, accuracy: 0.001)
        XCTAssertNotNil(a4.caption)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.writePDF(solid(300, 200), options: options, caption: "DSC_0001", ppi: 300, to: url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
        let box = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 841.89, accuracy: 0.01)
    }

    // MARK: - Rendering intent

    func testRenderingIntentDefaultsAndChoice() throws {
        XCTAssertEqual(ExportColorProfile.adobeRGB.renderingIntent, .relativeColorimetric)
        XCTAssertEqual(ExportColorProfile(kind: .icc, name: "Paper").renderingIntent, .perceptual)
        var adobe = ExportColorProfile.adobeRGB
        adobe.intent = .perceptual
        XCTAssertEqual(adobe.renderingIntent, .perceptual)
        // A profile without an intent encodes as it always did.
        let json = String(decoding: try JSONEncoder().encode(ExportColorProfile.proPhoto), as: UTF8.self)
        XCTAssertFalse(json.contains("intent"))
        let old = try JSONDecoder().decode(ExportColorProfile.self, from: Data(#"{"kind":"icc","name":"Lab"}"#.utf8))
        XCTAssertNil(old.intent)
        XCTAssertEqual(old.renderingIntent, .perceptual)
        for intent in RenderingIntent.allCases {
            XCTAssertNotEqual(ExportColorProfile.cgIntent(intent), .defaultIntent, "\(intent) maps to an intent")
        }
    }

    // MARK: - Metadata extras

    func testKeywordHierarchyAndEmbeddedEdit() throws {
        var metadata = ExportMetadata()
        metadata.keywords = ["Places|France|Paris", "Dog"]
        let plain = try Exporter.encode(.init(image: solid(16, 16)), settings: ExportSettings(), metadata: metadata)
        XCTAssertNil(hierarchy(in: plain), "off by default")

        metadata.writesKeywordHierarchy = true
        let edit = #"{"schemaVersion":1,"modules":{"exposure":{"ev":0.5}},"note":"quotes \" and <tags>"}"#
        metadata.embeddedEditJSON = edit
        for format in [ExportSettings.Format.jpeg, .tiff, .png, .heic] {
            let data = try Exporter.encode(.init(image: solid(16, 16)), settings: ExportSettings(format: format),
                                           metadata: metadata)
            XCTAssertEqual(hierarchy(in: data), ["Places|France|Paris", "Dog"], format.displayName)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("latent-edit-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            XCTAssertEqual(ExportMetadata.embeddedEdit(in: url), edit, format.displayName)
        }

        // The copyright levels filter the hierarchy out with the keywords;
        // the edit, asked for by its own switch, stays.
        metadata.level = .copyrightOnly
        let data = try Exporter.encode(.init(image: solid(16, 16)), settings: ExportSettings(format: .tiff),
                                       metadata: metadata)
        XCTAssertNil(hierarchy(in: data))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-edit-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertEqual(ExportMetadata.embeddedEdit(in: url), edit)
    }

    private func hierarchy(in data: Data) -> [String]? {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        guard let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        var found: [String]?
        CGImageMetadataEnumerateTagsUsingBlock(xmp, nil, nil) { _, tag in
            if (CGImageMetadataTagCopyName(tag) as String?) == "hierarchicalSubject",
               let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
                found = values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
                return false
            }
            return true
        }
        return found
    }
}
