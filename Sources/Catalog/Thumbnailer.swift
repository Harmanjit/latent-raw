import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import RawCore

public enum ThumbnailError: Error, CustomStringConvertible {
    case noEmbeddedPreview
    case decodeFailed
    case encodeFailed

    public var description: String {
        switch self {
        case .noEmbeddedPreview: return "the raw file has no embedded preview"
        case .decodeFailed:      return "the embedded preview could not be decoded"
        case .encodeFailed:      return "the thumbnail could not be written"
        }
    }
}

/// Makes catalog thumbnails (DESIGN.md §10).
///
/// For an unedited image the thumbnail is the camera's own embedded JPEG,
/// downscaled — no raw decoding at all. ImageIO decodes a JPEG straight
/// to a reduced size using the codec's built-in scaling, so even a
/// full-size 24 MP preview costs a few milliseconds. The result is
/// written as HEIC, which on Apple Silicon goes through the hardware
/// encoder, and stored in the catalog's `thumbnails/` folder mirroring
/// the image's subpath.
public enum Thumbnailer {
    /// Long-edge size in pixels.
    public static let size = 512

    /// The `thumb_key` recorded for a thumbnail made from the embedded
    /// preview. Edited images will record a hash of their edit instead,
    /// so a stale thumbnail is detected by a key mismatch.
    public static let embeddedPreviewKey = Data("embedded:v1".utf8)

    /// Extracts, downscales, orients and writes. Pure: a file in, a file
    /// out, no database. Safe to call from any thread.
    public static func makeFromEmbeddedPreview(rawFileAt source: URL, to destination: URL) throws {
        let raw = try RawFile(path: source.path, metadataOnly: true)
        guard let jpeg = raw.embeddedJPEGPreview() else { throw ThumbnailError.noEmbeddedPreview }
        let image = try decodeDownscaled(jpeg, orientation: raw.summary.orientation)
        try writeHEIC(image, to: destination)
    }

    /// Decodes `jpeg` at no more than `size` px on the long edge, then
    /// rotates per LibRaw's `flip` if the JPEG itself carried no
    /// orientation tag (ImageIO already honours one when present).
    static func decodeDownscaled(_ jpeg: Data, orientation flip: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
            throw ThumbnailError.decodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError.decodeFailed
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let jpegOrientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if jpegOrientation != 1 { return image }   // ImageIO applied it

        // LibRaw flip: 0 upright, 3 = 180°, 5 = 90° counter-clockwise,
        // 6 = 90° clockwise. Same encoding dcraw has used for decades.
        switch flip {
        case 3: return rotated(image, quarterTurns: 2)
        case 5: return rotated(image, quarterTurns: 3)
        case 6: return rotated(image, quarterTurns: 1)
        default: return image
        }
    }

    /// Rotates clockwise by `quarterTurns` × 90°.
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let swap = turns % 2 == 1
        let outW = swap ? h : w, outH = swap ? w : h

        guard let context = CGContext(data: nil, width: outW, height: outH,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        // CGContext's y axis points up, so a visual clockwise turn is a
        // negative rotation.
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                                       width: CGFloat(w), height: CGFloat(h)))
        return context.makeImage() ?? image
    }

    /// Writes to a temp file beside the destination, then renames, so a
    /// half-written thumbnail never exists under the real name.
    static func writeHEIC(_ image: CGImage, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw ThumbnailError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ThumbnailError.encodeFailed
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
    }

    /// Loads a thumbnail file for display.
    public static func load(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
