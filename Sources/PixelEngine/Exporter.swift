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
    public var software: String = "Latent"

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

    /// Writes `texture` as a file. Rotation and an optional final resize
    /// to `maxLongEdge` happen on the GPU together with the conversion to
    /// the file's bit depth; the CPU never loops over pixels. Returns the
    /// written pixel size.
    @discardableResult
    public func write(_ texture: MTLTexture,
                       to url: URL,
                       settings: ExportSettings,
                       colorSpace: ColorKit.OutputSpace,
                       rotation: ImageRotation = .none,
                       metadata: ExportMetadata? = nil,
                       maxLongEdge: Int? = nil) throws -> (width: Int, height: Int) {
        let cgImage = try cgImage(from: texture, colorSpace: colorSpace, rotation: rotation,
                                  bitsPerComponent: settings.format.bitsPerComponent,
                                  maxLongEdge: maxLongEdge)
        try Self.write(cgImage: cgImage, to: url, settings: settings, metadata: metadata)
        return (cgImage.width, cgImage.height)
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

    /// Output size after rotation and resize.
    static func outputSize(width: Int, height: Int, rotation: ImageRotation, maxLongEdge: Int?) -> (Int, Int) {
        var w = width, h = height
        if rotation.swapsAxes { swap(&w, &h) }
        if let target = maxLongEdge, target > 0, max(w, h) > target {
            let scale = Double(target) / Double(max(w, h))
            w = max(1, Int((Double(w) * scale).rounded()))
            h = max(1, Int((Double(h) * scale).rounded()))
        }
        return (w, h)
    }

    /// One GPU pass: sample the rendered texture (rotated, resized) into
    /// a shared-storage 8- or 16-bit texture the CPU can read directly.
    func packedTexture(from texture: MTLTexture, rotation: ImageRotation,
                       bitsPerComponent: Int, maxLongEdge: Int?) throws -> MTLTexture {
        let (w, h) = Self.outputSize(width: texture.width, height: texture.height,
                                     rotation: rotation, maxLongEdge: maxLongEdge)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: bitsPerComponent == 16 ? .rgba16Unorm : .rgba8Unorm,
            width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared     // read by the CPU straight after
        descriptor.usage = [.shaderWrite]
        guard let dest = gpu.device.makeTexture(descriptor: descriptor),
              let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw ExportError.readbackFailed
        }
        encoder.setComputePipelineState(gpu.packForExportPSO)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(dest, index: 1)
        var turns = UInt32(rotation.rawValue)
        encoder.setBytes(&turns, length: 4, index: 0)
        let pso = gpu.packForExportPSO
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }
        return dest
    }

    /// A CGImage of a rendered (already display-encoded) texture, rotated
    /// and resized as asked, at 8 or 16 bits per channel. The pixels are
    /// packed on the GPU and copied out once (RGBX, alpha ignored).
    public func cgImage(from texture: MTLTexture,
                        colorSpace: ColorKit.OutputSpace,
                        rotation: ImageRotation = .none,
                        bitsPerComponent: Int = 8,
                        maxLongEdge: Int? = nil) throws -> CGImage {
        let packed = try packedTexture(from: texture, rotation: rotation,
                                       bitsPerComponent: bitsPerComponent, maxLongEdge: maxLongEdge)
        let w = packed.width, h = packed.height
        let bytesPerPixel = bitsPerComponent / 8 * 4
        let bytesPerRow = w * bytesPerPixel
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { bytes in
            packed.getBytes(bytes.baseAddress!, bytesPerRow: bytesPerRow,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        let cgColorSpace: CGColorSpace?
        switch colorSpace {
        case .sRGB:      cgColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: cgColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        case .rec2020:   cgColorSpace = CGColorSpace(name: CGColorSpace.itur_2020)
        }
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        if bitsPerComponent == 16 {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                       | CGBitmapInfo.byteOrder16Little.rawValue)
        }
        guard let cgColorSpace,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: bitsPerComponent,
                                  bitsPerPixel: bitsPerComponent * 4, bytesPerRow: bytesPerRow,
                                  space: cgColorSpace, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ExportError.imageCreationFailed
        }
        return image
    }

}
