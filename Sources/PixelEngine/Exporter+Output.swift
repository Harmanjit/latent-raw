import Foundation
import ImageIO
import CoreGraphics

extension Exporter {
    /// The file properties that come from the export's settings rather
    /// than the photo: the print resolution, and a TIFF's compression.
    /// Settings left at their defaults add nothing, so those files are
    /// written exactly as before.
    static func addOutputProperties(to properties: inout [CFString: Any], settings: ExportSettings) {
        if let ppi = settings.ppi, ppi.isFinite, ppi > 0 {
            // ImageIO writes these as the JPEG's JFIF density, the TIFF and
            // EXIF X/YResolution (in inches), PNG's pHYs, and HEIC's own.
            properties[kCGImagePropertyDPIWidth] = ppi
            properties[kCGImagePropertyDPIHeight] = ppi
        }
        if settings.format == .tiff, settings.tiffCompression != .none {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = settings.tiffCompression.tagValue
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
    }

    /// The pixels as the file stores them, when that isn't the rendered
    /// RGB: one grey channel for a monochrome edit (Gray Gamma 2.2, or
    /// Linear Gray when floating point), or linear floating point for a
    /// 32-bit TIFF and for OpenEXR. Core Graphics converts the rendered
    /// pixels, so a converted colour space's profile is honoured. Anything
    /// else, and any image Core Graphics can't convert, is returned as it is.
    static func finalPixels(_ image: CGImage, settings: ExportSettings) -> CGImage {
        let grey = settings.writesGreyscale
        let floatBits: Int? = settings.writesFloatTIFF ? 32
            : settings.format == .exr ? (settings.exr.half ? 16 : 32) : nil
        guard grey || floatBits != nil, let source = image.colorSpace else { return image }
        let space: CGColorSpace?
        if grey {
            space = CGColorSpace(name: floatBits == nil ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.linearGray)
        } else if settings.format == .exr {
            // Extended, so colours outside sRGB keep their negative values.
            // ImageIO writes an EXR in linear sRGB primaries whatever the
            // image's space (measured), so the conversion is made here.
            space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else {
            space = CGColorSpaceCreateLinearized(source)
        }
        guard let space else { return image }
        let bits = floatBits ?? (image.bitsPerComponent == 16 ? 16 : 8)
        var info = grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        if floatBits != nil { info |= CGBitmapInfo.floatComponents.rawValue }
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if bits == 32 { info |= CGBitmapInfo.byteOrder32Little.rawValue }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bits,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// The lowest JPEG quality tried when fitting a size limit. Below this
    /// a photo falls apart into blocks; failing says so instead.
    public static let minimumLimitedQuality: Float = 0.05

    /// The file `encode` makes, at the highest quality (no higher than the
    /// settings') whose file fits in `maximumBytes`, found by halving the
    /// range seven times: within 1% of quality of the best. Throws
    /// `ExportSizeLimitError` when even the lowest quality is too big.
    public static func encode(_ prepared: EncodableImage, settings: ExportSettings, metadata: ExportMetadata?,
                              limitedTo maximumBytes: Int) throws -> (data: Data, quality: Float) {
        var trial = settings
        let first = try encode(prepared, settings: trial, metadata: metadata)
        if first.count <= maximumBytes || !settings.format.supportsQuality { return (first, settings.quality) }
        var low = minimumLimitedQuality, high = settings.quality
        trial.quality = low
        var best = try encode(prepared, settings: trial, metadata: metadata)
        guard best.count <= maximumBytes else {
            throw ExportSizeLimitError.cannotFit(limit: maximumBytes, smallest: best.count)
        }
        var bestQuality = low
        for _ in 0..<7 {
            let middle = (low + high) / 2
            trial.quality = middle
            let data = try encode(prepared, settings: trial, metadata: metadata)
            if data.count <= maximumBytes {
                best = data; bestQuality = middle; low = middle
            } else {
                high = middle
            }
        }
        return (best, bestQuality)
    }

    /// Writes encoded bytes as `write(cgImage:)` writes a file: under a
    /// temporary name, moved into place when complete.
    public static func write(data: Data, to url: URL, replacingExisting: Bool = true) throws {
        let pending = try SafeFileWriter.begin(url)
        defer { pending.discard() }
        do {
            try data.write(to: pending.url)
        } catch {
            throw ExportError.writeFailed(url)
        }
        try pending.commit(replacingExisting: replacingExisting)
    }
}

public enum ExportSizeLimitError: Error, CustomStringConvertible, Equatable {
    case cannotFit(limit: Int, smallest: Int)

    public var description: String {
        switch self {
        case .cannotFit(let limit, let smallest):
            let format = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
            return "even at the lowest quality the file is \(format(smallest)), over the \(format(limit)) limit; "
                + "export it smaller"
        }
    }
}

extension ExportPlan {
    /// Whether an edit renders in grey only: Black & White on, with no
    /// colour grading or split toning and no shadow tint to colour it.
    /// Greyscale when monochrome writes such an export as one grey channel.
    public static func isMonochrome(_ parameters: EditParameters) -> Bool {
        let c = parameters.colour
        return c.blackAndWhite.enabled && c.grading.isNeutral && c.calibration.shadowTint == 0
    }
}
