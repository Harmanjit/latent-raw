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
    public enum Format: String, Sendable, CaseIterable {
        case jpeg
        case png
        case tiff

        public var displayName: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png:  return "PNG"
            case .tiff: return "TIFF (16-bit)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png:  return "png"
            case .tiff: return "tif"
            }
        }

        public var contentType: UTType {
            switch self {
            case .jpeg: return .jpeg
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
            case .jpeg, .png: return 8
            case .tiff:       return 16
            }
        }

        public var supportsQuality: Bool { self == .jpeg }
    }

    public var format: Format
    /// JPEG quality, 0...1. Ignored for the lossless formats.
    public var quality: Float

    public init(format: Format = .jpeg, quality: Float = 0.92) {
        self.format = format
        self.quality = quality
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
                       colorSpace: ColorKit.OutputSpace) throws {
        let pixels = try readBack(texture)
        let cgImage = try makeImage(from: pixels,
                                     width: texture.width, height: texture.height,
                                     settings: settings, colorSpace: colorSpace)

        guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, settings.format.contentType.identifier as CFString, 1, nil) else {
            throw ExportError.destinationCreationFailed(url)
        }

        var properties: [CFString: Any] = [:]
        if settings.format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] =
                max(0, min(1, settings.quality))
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed(url)
        }
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
