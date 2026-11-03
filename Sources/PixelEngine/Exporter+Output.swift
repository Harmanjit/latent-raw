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
