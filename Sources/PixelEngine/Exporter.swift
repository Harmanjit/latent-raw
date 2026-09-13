import Foundation
import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import ColorKit

public enum ExportError: Error, CustomStringConvertible {
    case readbackFailed
    case imageCreationFailed
    case destinationCreationFailed(URL)
    case writeFailed(URL)

    public var description: String {
        switch self {
        case .readbackFailed:
            return "Could not read the rendered image back from the GPU"
        case .imageCreationFailed:
            return "Could not build an image from the rendered pixels"
        case .destinationCreationFailed(let url):
            return "Could not create a file at \(url.path)"
        case .writeFailed(let url):
            return "Could not finish writing \(url.path)"
        }
    }
}

/// What to write, and how.
public struct ExportSettings: Sendable {
    public enum Format: String, Sendable, CaseIterable, Codable {
        case jpeg
        case heic
        case png
        case tiff

        public var displayName: String {
            switch self {
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .png:  return "PNG"
            case .tiff: return "TIFF (16-bit)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .png:  return "png"
            case .tiff: return "tif"
            }
        }

        public var contentType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .png:  return .png
            case .tiff: return .tiff
            }
        }

        /// JPEG and PNG are written at 8 bits per channel; TIFF at 16.
        ///
        /// Eight bits is fine for anything being viewed or shared — it's
        /// what screens show. It becomes a real loss when the file is going
        /// into another editor, because the tone curve has already
        /// compressed a wide scene range into that byte, and any further
        /// adjustment pulls gaps open in the gradients. That's what the
        /// 16-bit option is for.
        var bitsPerComponent: Int {
            switch self {
            case .jpeg, .heic, .png: return 8
            case .tiff:              return 16
            }
        }

        public var supportsQuality: Bool { self == .jpeg || self == .heic }
    }

    public var format: Format
    /// JPEG/HEIC quality, 0...1. Ignored for the lossless formats.
    public var quality: Float

    public init(format: Format = .jpeg, quality: Float = 0.92) {
        self.format = format
        self.quality = quality
    }
}

/// What gets written into the file besides pixels. A file with no
/// metadata is an orphan: no camera, no date, no keywords. These land in
/// the standard EXIF / TIFF / IPTC fields every browser and editor reads.
public struct ExportMetadata: Sendable, Equatable {
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Int?
    public var shutter: Double?      // seconds
    public var aperture: Double?
    public var focalLength: Double?  // mm
    public var captureDate: Date?
    public var keywords: [String] = []
    public var rating: Int = 0
    public var software: String = "rawhead"

    public init() {}

    /// The ImageIO properties dictionary for this metadata.
    public var imageIOProperties: [CFString: Any] {
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: software]
        if let m = cameraMake { tiff[kCGImagePropertyTIFFMake] = m }
        if let m = cameraModel { tiff[kCGImagePropertyTIFFModel] = m }
        var exif: [CFString: Any] = [:]
        if let iso { exif[kCGImagePropertyExifISOSpeedRatings] = [iso] }
        if let shutter { exif[kCGImagePropertyExifExposureTime] = shutter }
        if let aperture { exif[kCGImagePropertyExifFNumber] = aperture }
        if let focalLength { exif[kCGImagePropertyExifFocalLength] = focalLength }
        if let lensModel { exif[kCGImagePropertyExifLensModel] = lensModel }
        if let captureDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exif[kCGImagePropertyExifDateTimeOriginal] = f.string(from: captureDate)
            tiff[kCGImagePropertyTIFFDateTime] = f.string(from: captureDate)
        }
        var iptc: [CFString: Any] = [:]
        if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = keywords }
        if rating > 0 { iptc[kCGImagePropertyIPTCStarRating] = rating }
        var props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: tiff,
                                      kCGImagePropertyExifDictionary: exif]
        if !iptc.isEmpty { props[kCGImagePropertyIPTCDictionary] = iptc }
        return props
    }
}

/// Writes a rendered texture to a file.
///
/// The texture is expected to be **already display-encoded** — the colour
/// stage applies the camera matrix, tone mapping, the output-space
/// transform and the encoding curve. This type only reads back, quantizes,
/// and tags.
///
/// Tagging matters more than it looks: an untagged file is a guess for
/// whoever opens it, and the usual guess is sRGB. Exporting Display P3
/// pixels untagged would make every saturated colour render wrong
/// everywhere else. The pipeline knows which space it produced, so that
/// knowledge is carried into the file's ICC profile.
public final class Exporter {
    private let gpu: GPUContext

    public init(gpu: GPUContext) {
        self.gpu = gpu
    }

    public func write(_ texture: MTLTexture,
                       to url: URL,
                       settings: ExportSettings,
                       colorSpace: ColorKit.OutputSpace,
                       rotation: ImageRotation = .none,
                       metadata: ExportMetadata? = nil) throws {
        var pixels = try readBack(texture)
        var width = texture.width, height = texture.height
        if rotation != .none {
            // The pipeline renders the sensor as recorded; the file gets
            // real rotated pixels rather than an orientation tag, because
            // not every viewer honours the tag.
            pixels = Self.rotate(pixels, width: width, height: height, rotation: rotation)
            if rotation.swapsAxes { swap(&width, &height) }
        }
        let cgImage = try makeImage(from: pixels,
                                     width: width, height: height,
                                     settings: settings, colorSpace: colorSpace)

        try Self.write(cgImage: cgImage, to: url, settings: settings, metadata: metadata)
    }

    /// Writes an already-built CGImage. The image's own colour space tag
    /// is embedded as the file's ICC profile.
    public static func write(cgImage: CGImage, to url: URL, settings: ExportSettings,
                             metadata: ExportMetadata? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, settings.format.contentType.identifier as CFString, 1, nil) else {
            throw ExportError.destinationCreationFailed(url)
        }
        var properties: [CFString: Any] = metadata?.imageIOProperties ?? [:]
        if settings.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, settings.quality))
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed(url)
        }
    }

    /// Resamples so the long edge is `maxLongEdge` pixels (never upscales).
    /// High-quality interpolation; the input is normally already close
    /// to the target size because the render was binned to suit.
    public static func resized(_ image: CGImage, maxLongEdge: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge, maxLongEdge > 0 else { return image }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// An 8-bit CGImage of a rendered (already display-encoded) texture,
    /// rotated as asked. For thumbnails and previews that stay in memory.
    public func cgImage(from texture: MTLTexture,
                        colorSpace: ColorKit.OutputSpace,
                        rotation: ImageRotation = .none) throws -> CGImage {
        var pixels = try readBack(texture)
        var width = texture.width, height = texture.height
        if rotation != .none {
            pixels = Self.rotate(pixels, width: width, height: height, rotation: rotation)
            if rotation.swapsAxes { swap(&width, &height) }
        }
        return try makeImage(from: pixels, width: width, height: height,
                             settings: ExportSettings(format: .png), colorSpace: colorSpace)
    }

    // MARK: - Rotation

    /// Rotates an RGBA half-float buffer by quarter turns clockwise.
    static func rotate(_ src: [Float16], width w: Int, height h: Int,
                       rotation: ImageRotation) -> [Float16] {
        let outW = rotation.swapsAxes ? h : w
        let outH = rotation.swapsAxes ? w : h
        var dst = [Float16](repeating: 0, count: outW * outH * 4)
        let size = CGSize(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                // Map the *centre* of the source pixel so the result lands
                // on integer coordinates for every rotation.
                let p = rotation.imagePoint(fromSensorPoint: CGPoint(x: Double(x) + 0.5,
                                                                     y: Double(y) + 0.5),
                                            sensorSize: size)
                let ox = Int(p.x), oy = Int(p.y)
                let s = (y * w + x) * 4, d = (oy * outW + ox) * 4
                dst[d] = src[s]; dst[d + 1] = src[s + 1]
                dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
            }
        }
        return dst
    }

    // MARK: - Readback

    private func readBack(_ texture: MTLTexture) throws -> [Float16] {
        try TextureReadback.float16Pixels(of: texture, gpu: gpu)
    }

    // MARK: - Quantization

    private func makeImage(from pixels: [Float16], width: Int, height: Int,
                            settings: ExportSettings,
                            colorSpace: ColorKit.OutputSpace) throws -> CGImage {
        let cgColorSpace: CGColorSpace?
        switch colorSpace {
        case .sRGB:      cgColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: cgColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        case .rec2020:   cgColorSpace = CGColorSpace(name: CGColorSpace.itur_2020)
        }
        guard let cgColorSpace else { throw ExportError.imageCreationFailed }

        let pixelCount = width * height
        let bitsPerComponent = settings.format.bitsPerComponent
        let bytesPerPixel = (bitsPerComponent / 8) * 3   // no alpha in exports
        let bytesPerRow = width * bytesPerPixel

        var data: Data
        if bitsPerComponent == 8 {
            var bytes = [UInt8](repeating: 0, count: pixelCount * 3)
            for i in 0..<pixelCount {
                for c in 0..<3 {
                    let v = max(0, min(1, Float(pixels[i * 4 + c])))
                    bytes[i * 3 + c] = UInt8(v * 255 + 0.5)
                }
            }
            data = Data(bytes)
        } else {
            var values = [UInt16](repeating: 0, count: pixelCount * 3)
            for i in 0..<pixelCount {
                for c in 0..<3 {
                    let v = max(0, min(1, Float(pixels[i * 4 + c])))
                    values[i * 3 + c] = UInt16(v * 65535 + 0.5)
                }
            }
            data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw ExportError.imageCreationFailed
        }

        // 16-bit samples are little-endian on Apple Silicon; CoreGraphics
        // needs telling, or the bytes are read the wrong way round and the
        // image comes out as noise.
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if bitsPerComponent == 16 {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                       | CGBitmapInfo.byteOrder16Little.rawValue)
        }

        guard let image = CGImage(width: width, height: height,
                                   bitsPerComponent: bitsPerComponent,
                                   bitsPerPixel: bitsPerComponent * 3,
                                   bytesPerRow: bytesPerRow,
                                   space: cgColorSpace,
                                   bitmapInfo: bitmapInfo,
                                   provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportError.imageCreationFailed
        }
        return image
    }
}
