import Foundation
import CoreGraphics
import ImageIO
import simd
import XCTest
import RawCore
import MergeKit

/// The portrait test asset (TestAssets/portrait, NASA's public-domain
/// portrait of Zena Cardman, fetched by `scripts/fetch_test_assets.sh
/// --portrait`) in the two forms the face tests need: an sRGB CGImage,
/// and a LinearRaw DNG a `RawFile` and `ImageSession` can open, written
/// once per process with MergeKit's writer.
///
/// The DNG says it is a Nikon D750 (the camera LibRaw has a matrix for,
/// like every other linear fixture) and holds the photograph converted
/// into that camera's space with its white as the neutral, so a render
/// of its defaults gives the photograph back near enough for Vision and
/// the colour gates. Everything skips when the JPEG is absent.
enum PortraitFixture {
    static let relativePath = "portrait/zena_cardman_nasa_portrait.jpg"
    /// The DNG's long edge: 3000 px keeps the face about 750 px across
    /// (Vision's fit wants 80) and the file under 50 MB.
    static let dngLongEdge = 3000

    static var jpegURL: URL { TestAssets.url(relativePath) }

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: jpegURL.path) }

    static func skipUnlessAvailable() throws {
        try XCTSkipUnless(isAvailable, "No portrait in TestAssets/portrait/: run scripts/fetch_test_assets.sh --portrait")
    }

    /// The portrait upright, scaled so its long edge is `longEdge`, as
    /// sRGB RGBX 8-bit (the layout `Exporter.cgImage` reads back).
    static func image(longEdge: Int) throws -> CGImage {
        try skipUnlessAvailable()
        guard let source = CGImageSourceCreateWithURL(jpegURL as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError("The portrait JPEG could not be decoded")
        }
        let scale = CGFloat(longEdge) / CGFloat(max(full.width, full.height))
        let width = Int((CGFloat(full.width) * scale).rounded()), height = Int((CGFloat(full.height) * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FixtureError("No sRGB context for the portrait")
        }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError("The portrait could not be scaled") }
        return image
    }

    /// The LinearRaw DNG, written on first use into a folder of this
    /// process's own (removed at exit).
    static func dngURL() throws -> URL {
        try skipUnlessAvailable()
        return try dng.get()
    }

    private static let folder: URL = {
        atexit { try? FileManager.default.removeItem(at: portraitFixtureFolder) }
        return portraitFixtureFolder
    }()

    private static let dng: Result<URL, any Error> = Result {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try writeDNG(scale: exposureScale, to: folder.appendingPathComponent("portrait.dng"))
    }

    /// What the linear pixels are multiplied by before they are stored.
    /// The pipeline's default look lifts a linear source by about a stop
    /// and a half, so at 1 the render is washed out (the face's median
    /// L* 91, the lips 84, no room for the teeth gate); 0.35 puts the
    /// face where the JPEG has it (L* 72.75 against 72, the lips 60.3
    /// against 60.2), measured on the default render.
    static let exposureScale: Float = 0.35

    /// Writes the DNG at `url`; `scale` multiplies the linear pixels.
    static func writeDNG(scale: Float, to url: URL) throws -> URL {
        let image = try self.image(longEdge: dngLongEdge)
        let width = image.width, height = image.height
        guard let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else {
            throw FixtureError("The scaled portrait is not RGBX")
        }
        // sRGB's curve undone, once per code value.
        let linear = (0..<256).map { v -> Float in
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        // The photograph in the D750's camera space: linear sRGB to XYZ
        // (D65), then XYZ to camera through the matrix LibRaw has for
        // that body. Its neutral is the camera's own white, so as-shot
        // white balance followed by LibRaw's matrix (normalised to that
        // white) gives the sRGB values back.
        let cameraXYZ = simd_float3x3(rows: [SIMD3(0.9020, -0.2890, -0.0715),
                                             SIMD3(-0.4535, 1.2436, 0.2348),
                                             SIMD3(-0.0934, 0.1919, 0.7086)])
        let sRGBXYZ = simd_float3x3(rows: [SIMD3(0.4124564, 0.3575761, 0.1804375),
                                           SIMD3(0.2126729, 0.7151522, 0.0721750),
                                           SIMD3(0.0193339, 0.1191920, 0.9503041)])
        let toCamera = cameraXYZ * sRGBXYZ
        let cameraWhite = toCamera * SIMD3<Float>(1, 1, 1)
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        let rowBytes = image.bytesPerRow
        data.withUnsafeBytes { bytes in
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * rowBytes + x * 4, o = (y * width + x) * 3
                    let rgb = SIMD3(linear[Int(bytes[i])], linear[Int(bytes[i + 1])], linear[Int(bytes[i + 2])])
                    let camera = simd_clamp(toCamera * rgb * scale, SIMD3(repeating: 0), SIMD3(repeating: 1))
                    pixels[o] = Float16(camera.x)
                    pixels[o + 1] = Float16(camera.y)
                    pixels[o + 2] = Float16(camera.z)
                }
            }
        }
        let metadata = MergeDNGMetadata(
            make: "Nikon", model: "D750",
            colorMatrix1: (0..<3).flatMap { r in (0..<3).map { c in Double(cameraXYZ[c][r]) } },
            asShotNeutral: [Double(cameraWhite.x / cameraWhite.y), 1, Double(cameraWhite.z / cameraWhite.y)],
            software: "Latent tests",
            captureDate: Date(timeIntervalSince1970: 1_505_433_600), exposureTime: 1.0 / 125, fNumber: 8, iso: 100)
        let recipe = MergeRecipe(kind: .hdr, clipLevel: 1, lensApplied: false, reference: 0,
                                 sources: [.init(path: jpegURL.lastPathComponent, hash: "portrait", captureTime: 0)])
        let writer = LinearRawDNGWriter(previewLongEdge: 400, thumbnailLongEdge: 128, freeSpaceMargin: 0)
        let preview = try self.image(longEdge: 400)
        return try writer.write(.buffer(pixels, width: width, height: height), maximum: 1, metadata: metadata,
                                recipe: recipe, preview: preview, to: url).url
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The fixture folder for `atexit`, which takes a C function pointer and
/// so can't capture.
private let portraitFixtureFolder = FileManager.default.temporaryDirectory
    .appendingPathComponent("latent-portrait-fixture-\(getpid())", isDirectory: true)
