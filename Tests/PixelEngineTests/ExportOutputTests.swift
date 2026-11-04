import XCTest
import Metal
import ImageIO
import CoreGraphics
@testable import PixelEngine
@testable import RawCore
import ColorKit

/// The export options added for Lightroom parity, in PixelEngine: output
/// sharpening (GPU against its CPU twin, and nothing when off), image
/// sizing, colour space conversion, resolution, TIFF options, Limit File
/// Size, metadata levels and the AVIF / JPEG XL availability check.
final class ExportOutputTests: XCTestCase {
    nonisolated(unsafe) private static var sharedGPU: GPUContext?

    private func gpu() throws -> GPUContext {
        if let gpu = Self.sharedGPU { return gpu }
        let gpu = try GPUContext()
        Self.sharedGPU = gpu
        return gpu
    }

    private func texture(_ gpu: GPUContext, width: Int, height: Int, texels: [Float16]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        texels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func samples16(_ image: CGImage) -> [UInt16] {
        let data = image.dataProvider!.data! as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }.map { UInt16(littleEndian: $0) }
    }

    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("latent-output-\(UUID().uuidString).\(ext)")
    }

    /// A step from dark to light grey down the middle, with a flat area
    /// on each side: the shape sharpening is for.
    private func edgeTexels(width w: Int, height h: Int) -> [Float16] {
        var texels = [Float16](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float16 = x < w / 2 ? 0.25 : 0.75
                for c in 0..<3 { texels[(y * w + x) * 4 + c] = v }
            }
        }
        return texels
    }

    // MARK: - Output sharpening

    /// Off by default: the settings have none, and a file written with them
    /// is the same file as before the option existed.
    func testSharpeningIsOffByDefaultAndChangesNothing() throws {
        let gpu = try gpu()
        let (w, h) = (40, 24)
        let source = try texture(gpu, width: w, height: h, texels: edgeTexels(width: w, height: h))
        let settings = ExportSettings(format: .tiff)
        XCTAssertNil(settings.outputSharpening)
        let exporter = Exporter(gpu: gpu)
        let before = try exporter.cgImage(from: source, colorSpace: .sRGB, bitsPerComponent: 16)
        let after = try exporter.encodableImage(source, settings: settings, colorSpace: .sRGB).image
        XCTAssertEqual(samples16(before), samples16(after))
    }

    /// The GPU's sharpen matches its CPU twin, leaves flat areas alone and
    /// steepens the edge (darker on the dark side, lighter on the light).
    func testSharpeningMatchesReferenceAndSteepensEdges() throws {
        let gpu = try gpu()
        let (w, h) = (40, 24)
        let texels = edgeTexels(width: w, height: h)
        let source = try texture(gpu, width: w, height: h, texels: texels)
        let sharpening = OutputSharpening(medium: .matte, strength: .high)
        var settings = ExportSettings(format: .tiff)
        settings.outputSharpening = sharpening
        settings.ppi = 300
        let image = try Exporter(gpu: gpu).encodableImage(source, settings: settings, colorSpace: .sRGB).image
        let actual = samples16(image)

        let pixels = (0..<(w * h)).map { i in
            SIMD3<Float>(Float(texels[i * 4]), Float(texels[i * 4 + 1]), Float(texels[i * 4 + 2]))
        }
        let expected = OutputSharpening.reference(pixels, width: w, height: h, filter: sharpening.filter(ppi: 300))
        var worst: Float = 0
        for i in 0..<(w * h) {
            for c in 0..<3 { worst = max(worst, abs(Float(actual[i * 4 + c]) / 65535 - expected[i][c])) }
        }
        XCTAssertLessThan(worst, 0.002, "GPU and CPU sharpening differ by \(worst)")

        let row = 12 * w
        XCTAssertEqual(Float(actual[(row + 2) * 4]) / 65535, 0.25, accuracy: 0.001, "flat dark area")
        XCTAssertEqual(Float(actual[(row + w - 3) * 4]) / 65535, 0.75, accuracy: 0.001, "flat light area")
        XCTAssertLessThan(Float(actual[(row + w / 2 - 1) * 4]) / 65535, 0.24, "dark side of the edge darkened")
        XCTAssertGreaterThan(Float(actual[(row + w / 2) * 4]) / 65535, 0.76, "light side of the edge lightened")
    }

    func testSharpeningSettingsFollowMediumAndResolution() {
        let screen = OutputSharpening(medium: .screen).filter(ppi: nil)
        let matte = OutputSharpening(medium: .matte).filter(ppi: 300)
        let glossy = OutputSharpening(medium: .glossy).filter(ppi: 300)
        XCTAssertGreaterThan(matte.amount, glossy.amount, "matte paper needs more than glossy")
        XCTAssertGreaterThan(matte.sigma, OutputSharpening(medium: .matte).filter(ppi: 180).sigma,
                             "a finer print grid spreads ink over more pixels")
        XCTAssertLessThan(OutputSharpening(medium: .screen, strength: .low).filter(ppi: nil).amount, screen.amount)
        XCTAssertLessThan(screen.amount, OutputSharpening(medium: .screen, strength: .high).filter(ppi: nil).amount)
        for filter in [screen, matte, glossy] {
            XCTAssertLessThanOrEqual(filter.radius, OutputSharpening.maximumRadius)
        }
    }

    // MARK: - Image sizing

    func testSizingModesComeDownToALongEdge() {
        let (w, h) = (6000, 4000)
        XCTAssertEqual(ExportSizing(mode: .longEdge, longEdge: 2048).targetLongEdge(width: w, height: h), 2048)
        XCTAssertEqual(ExportSizing(mode: .shortEdge, shortEdge: 1000).targetLongEdge(width: w, height: h), 1500)
        // Width & height: a portrait box limits a landscape photo by its width.
        XCTAssertEqual(ExportSizing(mode: .widthHeight, width: 1200, height: 1600).targetLongEdge(width: w, height: h), 1200)
        // Dimensions turns with the photo: the same box allows 1600 on the long side.
        XCTAssertEqual(ExportSizing(mode: .dimensions, width: 1200, height: 1600).targetLongEdge(width: w, height: h), 1600)
        // 6 MP of a 3:2 photo is 3000 x 2000.
        XCTAssertEqual(ExportSizing(mode: .megapixels, megapixels: 6).targetLongEdge(width: w, height: h), 3000)
        XCTAssertEqual(ExportSizing(mode: .percentage, percentage: 25).targetLongEdge(width: w, height: h), 1500)
    }

    func testDontEnlargeHoldsTheFullSize() {
        let big = ExportSizing(mode: .longEdge, longEdge: 8000)
        XCTAssertEqual(big.targetLongEdge(width: 6000, height: 4000), 6000)
        var enlarge = big
        enlarge.dontEnlarge = false
        XCTAssertEqual(enlarge.targetLongEdge(width: 6000, height: 4000), 8000)
        XCTAssertEqual(ExportSizing(mode: .percentage, percentage: 300).targetLongEdge(width: 600, height: 400), 600)

        let full = ExportPlan.target(for: big, rawWidth: 6000, rawHeight: 4000, crop: .none, rotation: .none)
        XCTAssertNil(full.maxLongEdge)
        XCTAssertFalse(full.enlarges)
        let larger = ExportPlan.target(for: enlarge, rawWidth: 6000, rawHeight: 4000, crop: .none, rotation: .none)
        XCTAssertEqual(larger.maxLongEdge, 8000)
        XCTAssertTrue(larger.enlarges)
    }

    /// The exporter enlarges only when told to, with the same resampler.
    func testExporterEnlargesOnlyWhenAllowed() throws {
        let gpu = try gpu()
        let (w, h) = (30, 20)
        let source = try texture(gpu, width: w, height: h, texels: edgeTexels(width: w, height: h))
        var settings = ExportSettings(format: .png)
        let kept = try Exporter(gpu: gpu).encodableImage(source, settings: settings, colorSpace: .sRGB, maxLongEdge: 60)
        XCTAssertEqual(kept.image.width, 30)
        settings.enlarges = true
        let grown = try Exporter(gpu: gpu).encodableImage(source, settings: settings, colorSpace: .sRGB, maxLongEdge: 60)
        XCTAssertEqual(grown.image.width, 60)
        XCTAssertEqual(grown.image.height, 40)
    }

    // MARK: - Colour spaces

    /// A Rec. 2020 render converted into Adobe RGB, ProPhoto and an ICC
    /// profile is tagged with that profile and shows the same colour.
    func testConvertedColourSpacesKeepTheColourAndEmbedTheProfile() throws {
        let gpu = try gpu()
        // sRGB orange, as the render would hold it in Rec. 2020 with the sRGB curve.
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let wide = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma))
        let orange = try XCTUnwrap(CGColor(colorSpace: srgb, components: [0.9, 0.5, 0.2, 1])?
            .converted(to: wide, intent: .relativeColorimetric, options: nil)?.components)
        let (w, h) = (8, 8)
        var texels = [Float16](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) { for c in 0..<3 { texels[i * 4 + c] = Float16(Float(orange[c])) } }
        let source = try texture(gpu, width: w, height: h, texels: texels)

        let icc = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericRGBLinear)?.copyICCData() as Data?)
        let profiles: [ExportColorProfile] = [.adobeRGB, .proPhoto,
                                              ExportColorProfile(kind: .icc, name: "Linear test", iccData: icc)]
        for profile in profiles {
            XCTAssertTrue(profile.needsConversion)
            XCTAssertEqual(String(describing: profile.renderSpace), String(describing: ColorKit.OutputSpace.rec2020))
            var settings = ExportSettings(format: .tiff)
            settings.colorProfile = profile
            let url = temporary("tif")
            defer { try? FileManager.default.removeItem(at: url) }
            let prepared = try Exporter(gpu: gpu).encodableImage(source, settings: settings, colorSpace: .rec2020)
            try Exporter.write(cgImage: prepared.image, to: url, settings: settings)

            let file = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, nil))
            XCTAssertEqual(image.bitsPerComponent, 16, profile.name)
            let tagged = try XCTUnwrap(image.colorSpace?.copyICCData() as Data?)
            let expected = try XCTUnwrap(profile.cgColorSpace?.copyICCData() as Data?)
            XCTAssertEqual(tagged, expected, "\(profile.name) is embedded")
            // Drawn back into sRGB, the colour is the orange it started as.
            var back = [UInt8](repeating: 0, count: 4)
            back.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertEqual(Double(back[0]), 0.9 * 255, accuracy: 3, profile.name)
            XCTAssertEqual(Double(back[1]), 0.5 * 255, accuracy: 3, profile.name)
            XCTAssertEqual(Double(back[2]), 0.2 * 255, accuracy: 3, profile.name)
        }
    }

    func testRenderedSpacesNeedNoConversionAndGainMapsStayWithThem() {
        XCTAssertFalse(ExportColorProfile.sRGB.needsConversion)
        XCTAssertFalse(ExportColorProfile.displayP3.needsConversion)
        var settings = ExportSettings(format: .jpeg, hdrGainMap: true)
        XCTAssertTrue(settings.writesGainMap)
        settings.colorProfile = .adobeRGB
        XCTAssertFalse(settings.writesGainMap, "a gain map describes the render's own primaries")
        // A grey or unreadable profile can't be exported into.
        XCTAssertNil(ExportColorProfile(kind: .icc, name: "none", iccData: Data([1, 2, 3])).cgColorSpace)
        let grey = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)?.copyICCData() as Data?
        XCTAssertNil(ExportColorProfile(kind: .icc, name: "grey", iccData: grey).cgColorSpace)
    }

    func testInstalledProfilesAreRGBAndLeaveOutTheBuiltInOnes() {
        let profiles = ExportColorProfile.installedProfiles()
        for profile in profiles {
            XCTAssertNotNil(ExportColorProfile.icc(at: profile.url), profile.name)
            XCTAssertFalse(profile.name.localizedCaseInsensitiveContains("Adobe RGB (1998)"))
        }
        XCTAssertEqual(profiles.map(\.name), profiles.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    // MARK: - File properties

    func testResolutionAndTIFFCompressionAreWritten() throws {
        let image = try ExportMetadataTests.image(width: 64, height: 48, space: CGColorSpace.sRGB)
        for format in ExportSettings.Format.available {
            var settings = ExportSettings(format: format)
            settings.ppi = 300
            let url = temporary(format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            try Exporter.write(cgImage: image, to: url, settings: settings)
            let props = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
            XCTAssertEqual(props[kCGImagePropertyDPIWidth as String] as? Double ?? 0, 300, accuracy: 0.5, format.rawValue)
        }
        for compression in TIFFCompression.allCases {
            var settings = ExportSettings(format: .tiff)
            settings.tiffCompression = compression
            settings.tiffBitDepth = 8
            XCTAssertEqual(settings.bitsPerComponent, 8)
            let url = temporary("tif")
            defer { try? FileManager.default.removeItem(at: url) }
            try Exporter.write(cgImage: image, to: url, settings: settings)
            let props = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
            let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFCompression as String] as? Int ?? 1, compression.tagValue,
                           compression.title)
        }
        // Defaults write neither, as before.
        let plain = ExportSettings(format: .tiff)
        XCTAssertNil(plain.ppi)
        XCTAssertEqual(plain.bitsPerComponent, 16)
        XCTAssertEqual(plain.tiffCompression, .none)
    }

    /// Limit File Size lowers the quality until the file fits, and says so
    /// when nothing fits.
    func testLimitFileSizeFitsOrRefuses() throws {
        // Noise compresses badly, so the limit has work to do.
        let (w, h) = (256, 256)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        for i in 0..<bytes.count { seed = seed &* 1103515245 &+ 12345; bytes[i] = UInt8(truncatingIfNeeded: seed >> 16) }
        let image = try XCTUnwrap(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let prepared = Exporter.EncodableImage(image: image)
        let settings = ExportSettings(format: .jpeg, quality: 0.95)
        let full = try Exporter.encode(prepared, settings: settings)
        let limit = full.count / 3
        let fitted = try Exporter.encode(prepared, settings: settings, metadata: nil, limitedTo: limit)
        XCTAssertLessThanOrEqual(fitted.data.count, limit)
        XCTAssertLessThan(fitted.quality, 0.95)
        // Already small enough: the quality asked for, untouched.
        let roomy = try Exporter.encode(prepared, settings: settings, metadata: nil, limitedTo: full.count * 2)
        XCTAssertEqual(roomy.quality, 0.95)
        XCTAssertEqual(roomy.data, full)
        XCTAssertThrowsError(try Exporter.encode(prepared, settings: settings, metadata: nil, limitedTo: 100)) { error in
            guard case ExportSizeLimitError.cannotFit = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Metadata levels

    private func written(_ level: ExportMetadataLevel) throws -> [String: Any] {
        var metadata = ExportMetadata()
        metadata.source = SourceMetadata(imageData: try ExportMetadataTests.richSourceJPEG())
        metadata.keywords = ["latent"]
        metadata.rating = 4
        metadata.includeLocation = true
        metadata.level = level
        let url = temporary("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(cgImage: try ExportMetadataTests.image(width: 32, height: 24, space: CGColorSpace.sRGB), to: url,
                           settings: ExportSettings(format: .jpeg), metadata: metadata)
        return try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
    }

    private func tiff(_ props: [String: Any]) -> [String: Any] { props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:] }
    private func exif(_ props: [String: Any]) -> [String: Any] { props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:] }
    private func iptc(_ props: [String: Any]) -> [String: Any] { props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:] }

    func testMetadataLevelsKeepTheirShare() throws {
        let all = try written(.all)
        XCTAssertEqual(tiff(all)[kCGImagePropertyTIFFModel as String] as? String, "Camera X")
        XCTAssertNotNil(all[kCGImagePropertyGPSDictionary as String])

        let noCamera = try written(.allExceptCameraInfo)
        XCTAssertNil(tiff(noCamera)[kCGImagePropertyTIFFModel as String])
        XCTAssertNil(tiff(noCamera)[kCGImagePropertyTIFFMake as String])
        XCTAssertNil(exif(noCamera)[kCGImagePropertyExifMeteringMode as String])
        XCTAssertNil(exif(noCamera)[kCGImagePropertyExifBodySerialNumber as String])
        XCTAssertEqual(exif(noCamera)[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:06:01 12:34:56")
        XCTAssertEqual(iptc(noCamera)[kCGImagePropertyIPTCKeywords as String] as? [String], ["source", "latent"])
        XCTAssertEqual(tiff(noCamera)[kCGImagePropertyTIFFCopyright as String] as? String, "CC0")
        XCTAssertNotNil(noCamera[kCGImagePropertyGPSDictionary as String], "location follows its own switch")

        let contact = try written(.copyrightAndContact)
        XCTAssertEqual(tiff(contact)[kCGImagePropertyTIFFCopyright as String] as? String, "CC0")
        XCTAssertEqual(tiff(contact)[kCGImagePropertyTIFFArtist as String] as? String, "A. Photographer")
        XCTAssertNil(tiff(contact)[kCGImagePropertyTIFFModel as String])
        XCTAssertNil(contact[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(iptc(contact)[kCGImagePropertyIPTCKeywords as String])
        XCTAssertNil(exif(contact)[kCGImagePropertyExifDateTimeOriginal as String])

        let copyright = try written(.copyrightOnly)
        XCTAssertEqual(tiff(copyright)[kCGImagePropertyTIFFCopyright as String] as? String, "CC0")
        XCTAssertNil(tiff(copyright)[kCGImagePropertyTIFFArtist as String])
        XCTAssertNil(iptc(copyright)[kCGImagePropertyIPTCStarRating as String])
        XCTAssertEqual(copyright[kCGImagePropertyOrientation as String] as? Int ?? 1, 1, "still upright")
    }

    // MARK: - Formats

    func testAVIFAndJPEGXLAreOfferedOnlyWhenThisMacWritesThem() throws {
        let encodable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        XCTAssertEqual(ExportSettings.Format.allCases, [.jpeg, .heic, .png, .tiff])
        for format in [ExportSettings.Format.avif, .jxl] {
            XCTAssertEqual(format.isAvailable, encodable.contains(format.contentType.identifier), format.displayName)
            XCTAssertEqual(ExportSettings.Format.available.contains(format), format.isAvailable)
            XCTAssertTrue(format.supportsQuality)
            XCTAssertEqual(format.supportsGainMap, format == .avif)
        }
        let image = try ExportMetadataTests.image(width: 64, height: 48, space: CGColorSpace.sRGB)
        for format in ExportSettings.Format.available where !ExportSettings.Format.allCases.contains(format) {
            let url = temporary(format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            try Exporter.write(cgImage: image, to: url, settings: ExportSettings(format: format, quality: 0.8))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.contentType.identifier)
        }
    }

    // MARK: - DNG parameters

    /// A DNG bakes the scene-referred edit and leaves the look out.
    func testSceneReferredKeepsCorrectionsAndDropsTheLook() {
        var edit = EditParameters()
        edit.exposureEV = 1.2
        edit.whiteBalance = .init(temperature: 4200, tint: 3)
        edit.denoiseLuminance = 0.4
        edit.clarity = 0.5
        edit.vibrance = 0.3
        edit.sharpenAmount = 1
        edit.toneCurve = ToneCurve(points: [SIMD2(0, 0.1), SIMD2(1, 0.9)])
        edit.crop = CropParameters(centre: [0.4, 0.5], size: [0.5, 0.5])
        let defaults = EditParameters()
        let baked = ExportPlan.sceneReferred(edit, defaults: defaults)
        XCTAssertEqual(baked.exposureEV, 1.2)
        XCTAssertEqual(baked.whiteBalance, edit.whiteBalance)
        XCTAssertEqual(baked.denoiseLuminance, 0.4)
        XCTAssertEqual(baked.crop, edit.crop)
        XCTAssertEqual(baked.clarity, defaults.clarity)
        XCTAssertEqual(baked.vibrance, defaults.vibrance)
        XCTAssertEqual(baked.sharpenAmount, defaults.sharpenAmount)
        XCTAssertEqual(baked.toneCurve, defaults.toneCurve)
    }
}
