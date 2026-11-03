import XCTest
import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// JPEG, PNG, TIFF and the other ordinary picture formats, opened through
/// ImageIO as a linear source (`RenderedImageFormat`): what the decoder
/// reports, the unrolled tones, orientation, and that the default render
/// gives the file's own pixels back.
final class RenderedImageTests: XCTestCase {
    nonisolated(unsafe) private static var sharedGPU: GPUContext?
    private static let lock = NSLock()

    private func gpu() throws -> GPUContext {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let gpu = Self.sharedGPU { return gpu }
        let gpu = try GPUContext()
        Self.sharedGPU = gpu
        return gpu
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixtures

    /// An sRGB picture whose pixel (x, y) is `colour(x, y)`, 8 bits.
    static func image(width: Int, height: Int, colour: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = colour(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Writes `image` as `type` with `properties` (an orientation, EXIF).
    func write(_ image: CGImage, name: String, type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var options = properties
        if type == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The 8-bit sRGB values of `image`, row by row, RGBA.
    static func sRGBBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// A ramp in each channel with mixed colours, so every tone and some
    /// saturated hues are checked.
    static func testPattern(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        (UInt8((x * 4) & 255), UInt8((y * 8) & 255), UInt8(((x + y) * 3) & 255))
    }

    // MARK: - Constants and arithmetic

    func testInverseCurveIsSolvedForTheEditDefaults() {
        let defaults = EditParameters()
        XCTAssertEqual(RenderedImageFormat.defaultContrast, defaults.contrast,
                       "a picture would not open looking like itself")
        XCTAssertEqual(RenderedImageFormat.defaultGreyPoint, defaults.greyPoint)
    }

    func testSceneValueInvertsTheSigmoid() {
        for step in 0...1000 {
            let y = Float(step) / 1000 * RenderedImageFormat.maximumDisplayValue
            let x = RenderedImageFormat.sceneValue(display: y)
            XCTAssertEqual(RenderedImageFormat.displayValue(scene: x), y, accuracy: 1e-5, "display \(y)")
        }
        XCTAssertEqual(RenderedImageFormat.sceneValue(display: -1), 0)
        XCTAssertEqual(RenderedImageFormat.sceneValue(display: 0.5), RenderedImageFormat.defaultGreyPoint, accuracy: 1e-6,
                       "middle of the curve is the grey point")
        let white = RenderedImageFormat.sceneValue(display: 1)
        XCTAssertTrue(white.isFinite && white < Float(LinearPlane.maximumValue), "white is capped, finite")
        XCTAssertEqual(white, RenderedImageFormat.sceneValue(display: 2), "above white is white")
        XCTAssertGreaterThan(RenderedImageFormat.displayValue(scene: white) * 255, 254.5, "white comes back as 255")
    }

    func testCameraMatrixMakesTheIdentityProfile() throws {
        let profile = try XCTUnwrap(ColorKit.CameraColorProfile(cameraToXYZRowMajor: RenderedImageFormat.cameraToXYZRowMajor))
        for col in 0..<3 {
            for row in 0..<3 {
                XCTAssertEqual(profile.cameraToWorking[col][row], col == row ? 1 : 0, accuracy: 1e-4)
            }
        }
        // As shot is unit multipliers, and its temperature and tint lead
        // back to them closely enough not to tint the picture.
        let asShot = profile.whiteBalance(fromMultipliers: SIMD4(1, 1, 1, 1))
        let back = profile.multipliers(for: asShot)
        XCTAssertEqual(back.x, 1, accuracy: 2e-3)
        XCTAssertEqual(back.z, 1, accuracy: 2e-3)
        XCTAssertEqual(asShot.temperature, 6504, accuracy: 150, "D65 white")
    }

    func testOrientationMapping() {
        XCTAssertTrue(RenderedImageFormat.orientation(exif: 1) == (false, 0))
        XCTAssertTrue(RenderedImageFormat.orientation(exif: 3) == (false, 3))
        XCTAssertTrue(RenderedImageFormat.orientation(exif: 6) == (false, 6))
        XCTAssertTrue(RenderedImageFormat.orientation(exif: 8) == (false, 5))
        XCTAssertTrue(RenderedImageFormat.orientation(exif: 0) == (false, 0), "missing or bad tag is upright")
    }

    func testDecodableFormats() {
        for ext in ["jpg", "jpeg", "png", "tif", "tiff", "heic"] {
            XCTAssertTrue(RenderedImageFormat.extensions.contains(ext), ext)
        }
        XCTAssertFalse(RenderedImageFormat.extensions.contains("nef"))
        XCTAssertTrue(RenderedImageFormat.handles(path: "/a/B.JPG"))
        XCTAssertFalse(RenderedImageFormat.handles(path: "/a/B.NEF"))
        XCTAssertFalse(RenderedImageFormat.handles(path: "/a/B.dng"), "a DNG is a raw")
    }

    // MARK: - Opening

    func testOpensAPNGAsALinearSource() throws {
        let url = try write(Self.image(width: 64, height: 40, colour: Self.testPattern), name: "scan.png", type: .png)
        let file = try RawFile(path: url.path)
        XCTAssertEqual(file.summary.sourceKind, .linearRGB)
        XCTAssertEqual(file.summary.renderedImage?.format, "PNG")
        XCTAssertEqual(file.summary.renderedImage?.bitsPerComponent, 8)
        XCTAssertEqual(file.summary.rawWidth, 64)
        XCTAssertEqual(file.summary.rawHeight, 40)
        XCTAssertEqual(file.summary.orientation, 0)
        XCTAssertFalse(file.isMetadataOnly)
        let plane = try XCTUnwrap(file.linearPlane)
        // Pixel (10, 3): its red channel unrolled, alpha 1.
        let (r, _, _) = Self.testPattern(x: 10, y: 3)
        let index = (3 * 64 + 10) * 4
        let display = Self.sRGBToLinear(Float(r) / 255)
        // Rec.2020 red takes in a little of every sRGB channel, so the check
        // is against the unrolled value of the converted colour.
        let rec2020 = Self.sRGBToRec2020(SIMD3(display, Self.sRGBToLinear(Float(Self.testPattern(x: 10, y: 3).1) / 255),
                                               Self.sRGBToLinear(Float(Self.testPattern(x: 10, y: 3).2) / 255)))
        XCTAssertEqual(Float(plane.samples[index]), RenderedImageFormat.sceneValue(display: rec2020.x),
                       accuracy: RenderedImageFormat.sceneValue(display: rec2020.x) * 3e-3 + 1e-4)
        XCTAssertEqual(Float(plane.samples[index + 3]), 1)

        // Without decoding: the same summary, no pixels.
        let quick = try RawFile(path: url.path, metadataOnly: true)
        XCTAssertTrue(quick.isMetadataOnly)
        XCTAssertNil(quick.linearPlane)
        XCTAssertEqual(quick.summary.rawWidth, 64)
        XCTAssertEqual(quick.summary.renderedImage?.format, "PNG")
    }

    func testReadsEXIFFromAJPEG() throws {
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:31 14:05:09",
            kCGImagePropertyExifISOSpeedRatings: [400],
            kCGImagePropertyExifExposureTime: 0.004,
            kCGImagePropertyExifFNumber: 5.6,
            kCGImagePropertyExifFocalLength: 35.0,
            kCGImagePropertyExifLensModel: "NIKKOR Z 35mm f/1.8 S",
        ]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z 6"]
        let url = try write(Self.image(width: 32, height: 24, colour: Self.testPattern), name: "DSC_0001.JPG",
                            type: .jpeg, properties: [kCGImagePropertyExifDictionary: exif,
                                                      kCGImagePropertyTIFFDictionary: tiff])
        let summary = try RawFile(path: url.path, metadataOnly: true).summary
        XCTAssertEqual(summary.renderedImage?.format, "JPEG")
        XCTAssertEqual(summary.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(summary.cameraModel, "NIKON Z 6")
        XCTAssertEqual(summary.lensModel, "NIKKOR Z 35mm f/1.8 S")
        XCTAssertEqual(summary.iso, 400)
        XCTAssertEqual(summary.shutter, 0.004, accuracy: 1e-9)
        XCTAssertEqual(summary.aperture, 5.6, accuracy: 1e-9)
        XCTAssertEqual(summary.focalLength, 35)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: summary.captureTime)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 10, 31, 14, 5, 9], "local time, as LibRaw reads a raw's")
    }

    func testAFileWithoutADateTakesItsModificationDate() throws {
        let url = try write(Self.image(width: 8, height: 8, colour: Self.testPattern), name: "scan.png", type: .png)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let summary = try RawFile(path: url.path, metadataOnly: true).summary
        XCTAssertEqual(summary.captureTime.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

    func testSixteenBitTIFFKeepsItsDepth() throws {
        // A 16-bit ramp: drawn through a 16-bit context so the file holds 16 bits.
        let width = 256, height = 4
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt16.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let v = UInt16(x * 257)
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 65535
            }
        }
        let url = try write(context.makeImage()!, name: "scan.tif", type: .tiff)
        let file = try RawFile(path: url.path)
        XCTAssertEqual(file.summary.renderedImage?.format, "TIFF")
        XCTAssertEqual(file.summary.renderedImage?.bitsPerComponent, 16)
        // Greys stay grey and rise monotonically along the ramp.
        let samples = try XCTUnwrap(file.linearPlane).samples
        var previous: Float = -1
        for x in stride(from: 0, to: width, by: 16) {
            let r = Float(samples[x * 4]), g = Float(samples[x * 4 + 1]), b = Float(samples[x * 4 + 2])
            XCTAssertEqual(r, g, accuracy: max(r, 1e-3) * 4e-3)
            XCTAssertEqual(b, g, accuracy: max(g, 1e-3) * 4e-3)
            XCTAssertGreaterThan(g, previous)
            previous = g
        }
    }

    func testTransparencyIsCompositedOverWhite() throws {
        let width = 4, height = 4
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))   // fully transparent
        let url = try write(context.makeImage()!, name: "clear.png", type: .png)
        let samples = try XCTUnwrap(try RawFile(path: url.path).linearPlane).samples
        let white = RenderedImageFormat.sceneValue(display: 1)
        XCTAssertEqual(Float(samples[0]), white, accuracy: white * 2e-3)
        XCTAssertEqual(Float(samples[1]), white, accuracy: white * 2e-3)
    }

    /// Every EXIF orientation: the plane (mirror baked in) turned by the
    /// reported flip shows what ImageIO's own upright rendering shows.
    func testEveryOrientationMatchesImageIO() throws {
        let width = 5, height = 3
        // A distinct colour for every pixel.
        let colour: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in (UInt8(40 + x * 40), UInt8(40 + y * 80), 128) }
        for exif in 1...8 {
            let url = try write(Self.image(width: width, height: height, colour: colour), name: "o\(exif).tif",
                                type: .tiff, properties: [kCGImagePropertyOrientation: exif])
            let file = try RawFile(path: url.path)
            XCTAssertEqual(file.summary.rawWidth, width, "stored size, before turning")
            let samples = try XCTUnwrap(file.linearPlane).samples
            let rotation = ImageRotation(libRawFlip: file.summary.orientation)
            // Which stored pixel each plane pixel came from, read back by its green and red.
            func storedPosition(planeX: Int, planeY: Int) -> (Int, Int) {
                let i = (planeY * width + planeX) * 4
                let display = SIMD3((0..<3).map { RenderedImageFormat.displayValue(scene: Float(samples[i + $0])) })
                let srgb = Self.rec2020ToSRGB(display)
                let r = Self.linearToSRGB(srgb.x) * 255, g = Self.linearToSRGB(srgb.y) * 255
                return (Int(((r - 40) / 40).rounded()), Int(((g - 40) / 80).rounded()))
            }
            // ImageIO's upright picture.
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let upright = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary))
            let uprightBytes = Self.sRGBBytes(upright)
            let swaps = rotation.swapsAxes
            XCTAssertEqual(upright.width, swaps ? height : width, "orientation \(exif)")
            for uy in 0..<upright.height {
                for ux in 0..<upright.width {
                    // The plane pixel the display rotation puts at (ux, uy).
                    let (px, py): (Int, Int)
                    switch rotation {
                    case .none: (px, py) = (ux, uy)
                    case .cw90: (px, py) = (uy, height - 1 - ux)
                    case .cw180: (px, py) = (width - 1 - ux, height - 1 - uy)
                    case .cw270: (px, py) = (width - 1 - uy, ux)
                    }
                    let i = (uy * upright.width + ux) * 4
                    let expected = (Int(((Float(uprightBytes[i]) - 40) / 40).rounded()),
                                    Int(((Float(uprightBytes[i + 1]) - 40) / 80).rounded()))
                    let got = storedPosition(planeX: px, planeY: py)
                    XCTAssertTrue(got == expected, "orientation \(exif) at (\(ux), \(uy)): \(got) vs \(expected)")
                }
            }
        }
    }

    // MARK: - Session and render

    func testSessionTurnsOffRawOnlyStages() throws {
        let url = try write(Self.image(width: 16, height: 16, colour: Self.testPattern), name: "a.jpg", type: .jpeg,
                            properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "24-70mm"],
                                         kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon",
                                                                          kCGImagePropertyTIFFModel: "Canon EOS R5"]])
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: try gpu())
        XCTAssertTrue(session.isRenderedImage)
        XCTAssertFalse(session.supportsAIDenoise)
        XCTAssertTrue(session.lensCorrectionAlreadyApplied, "no lens profile for a JPEG")
        XCTAssertNil(session.lensCorrection)
        XCTAssertEqual(session.sourceGain, 1)
        XCTAssertGreaterThan(session.highlightClipScale, 1000, "highlight reconstruction never triggers")
        XCTAssertNotNil(session.profile)
        XCTAssertEqual(session.asShotMultipliers, SIMD4(1, 1, 1, 1))
    }

    /// The point of unrolling: opened with the editor's defaults, a picture
    /// renders as itself.
    func testDefaultRenderGivesTheFileBack() throws {
        let width = 64, height = 32
        let original = Self.image(width: width, height: height, colour: Self.testPattern)
        let url = try write(original, name: "pattern.png", type: .png)
        let gpu = try gpu()
        let file = try RawFile(path: url.path)
        let session = try ImageSession(file: file, gpu: gpu)
        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance   // as the editor opens it
        let pipeline = RenderPipeline(gpu: gpu)
        let texture = try pipeline.render(session, scale: .full, parameters: parameters, output: .file(.sRGB))
        let rendered = try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB)
        XCTAssertEqual(rendered.width, width)
        let got = Self.sRGBBytes(rendered), want = Self.sRGBBytes(original)
        var worst = 0
        for i in 0..<got.count where i % 4 != 3 {
            worst = max(worst, abs(Int(got[i]) - Int(want[i])))
        }
        XCTAssertLessThanOrEqual(worst, 2, "largest difference in 8-bit levels")

        // And the sliders still work from there: +1 EV brightens mid-grey.
        parameters.exposureEV = 1
        let brighter = Self.sRGBBytes(try Exporter(gpu: gpu).cgImage(
            from: try pipeline.render(session, scale: .full, parameters: parameters, output: .file(.sRGB)),
            colorSpace: .sRGB))
        let mid = (16 * width + 32) * 4 + 1   // green 128
        XCTAssertGreaterThan(Int(brighter[mid]), Int(want[mid]) + 20)
    }

    func testBinnedRenderWorks() throws {
        let url = try write(Self.image(width: 120, height: 80, colour: Self.testPattern), name: "p.png", type: .png)
        let gpu = try gpu()
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance
        let texture = try RenderPipeline(gpu: gpu).render(session, scale: .binned(quads: 2), parameters: parameters,
                                                          output: .file(.sRGB))
        XCTAssertEqual(texture.width, 30)
        XCTAssertEqual(texture.height, 20)
    }

    // MARK: - Colour helpers

    static func sRGBToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ v: Float) -> Float {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    static func sRGBToRec2020(_ c: SIMD3<Float>) -> SIMD3<Float> {
        (ColorKit.rec2020ToXYZ.inverse * ColorKit.sRGBToXYZ) * c
    }

    static func rec2020ToSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        (ColorKit.sRGBToXYZ.inverse * ColorKit.rec2020ToXYZ) * c
    }
}
