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
/// written as JPEG and stored in the catalog's `thumbnails/` folder
/// mirroring the image's subpath.
///
/// JPEG, not HEIC (plan #31): at 512 px a HEIC took 17-27 ms to encode,
/// more than decoding the preview, and 4-5 ms to load back, against under
/// 1 ms and about 0.5 ms for a JPEG. The JPEG qualities are set so each
/// matches or beats the HEIC it replaced (PSNR against the unencoded
/// thumbnail), at about twice the bytes: some 35 KB a thumbnail.
public enum Thumbnailer {
    /// Long-edge size in pixels.
    public static let size = 512

    /// JPEG quality thumbnails are written at, unless Settings › Performance
    /// asks for another (`ThumbnailGenerationSettings.Quality`).
    public static let defaultQuality = 0.8

    /// The thumbnail file format's version, part of every `thumb_key`.
    /// Bumping it makes every existing thumbnail stale, so the next pass
    /// makes it again. 1: HEIC files; 2: JPEG files (plan #31). This is
    /// the thumbnail cache's own version, not the edit stack's schema.
    public static let cacheVersion = 2

    /// The `thumb_key` recorded for a thumbnail made from the embedded
    /// preview. Edited images record a hash of their edit instead, so a
    /// stale thumbnail is detected by a key mismatch (DESIGN.md §10).
    public static let embeddedPreviewKey = Data("embedded:v\(cacheVersion)".utf8)

    /// The key for a thumbnail rendered from `editStackJSON`. Version 1
    /// keys were "edit:" and the hash, with no version.
    public static func key(forEditStack editStackJSON: String) -> Data {
        Data("edit:v\(cacheVersion):".utf8) + ImageRecord.hashData(FileHash.xxh64(Data(editStackJSON.utf8)))
    }

    /// What an image's thumbnail *should* be keyed by right now.
    public static func expectedKey(editStackJSON: String?) -> Data {
        editStackJSON.map(key(forEditStack:)) ?? embeddedPreviewKey
    }

    /// Writes an already-rendered, camera-oriented image as a thumbnail.
    /// Used for edited images, whose pixels come from the pipeline.
    public static func write(_ image: CGImage, to destination: URL, quality: Double = defaultQuality) throws {
        try writeJPEG(image, to: destination, quality: quality)
    }

    /// Extracts, downscales, orients and writes. Pure: a file in, a file
    /// out, no database. Safe to call from any thread.
    public static func makeFromEmbeddedPreview(rawFileAt source: URL, to destination: URL,
                                               quality: Double = defaultQuality) throws {
        // A JPEG, TIFF and the like is its own preview.
        if RenderedImageFormat.handles(path: source.path) {
            try writeJPEG(try decodeDownscaled(imageAt: source), to: destination, quality: quality)
            return
        }
        let raw = try RawFile(path: source.path, metadataOnly: true)
        guard let jpeg = raw.embeddedJPEGPreview() else { throw ThumbnailError.noEmbeddedPreview }
        try makeFromEmbeddedPreview(jpeg, orientation: raw.summary.orientation, to: destination, quality: quality)
    }

    /// The same from a raw's embedded JPEG already in hand (a reconcile
    /// read it; `ThumbnailHandoff`). `orientation` is LibRaw's `flip`.
    public static func makeFromEmbeddedPreview(_ jpeg: Data, orientation: Int, to destination: URL,
                                               quality: Double = defaultQuality) throws {
        try writeJPEG(try decodeDownscaled(jpeg, orientation: orientation), to: destination, quality: quality)
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

    /// Decodes a picture file at no more than `size` px on the long edge,
    /// turned (and mirrored) upright by its own orientation tag, as an
    /// embedded preview is.
    static func decodeDownscaled(imageAt url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ThumbnailError.decodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                              options as CFDictionary) else {
            throw ThumbnailError.decodeFailed
        }
        return image
    }

    /// Rotates clockwise by `quarterTurns` × 90°.
    public static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
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
    static func writeJPEG(_ image: CGImage, to destination: URL, quality: Double = defaultQuality) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = FileOperations.companionTemporaryURL(for: destination)

        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1)]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ThumbnailError.encodeFailed
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
    }

    /// Removes the version 1 (HEIC) thumbnail beside `destination`, once
    /// the JPEG that replaces it is written.
    static func removeLegacyFile(replacedBy destination: URL) {
        let legacy = Catalog.legacyThumbnailURL(for: destination)
        guard legacy != destination else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Loads a thumbnail file for display.
    public static func load(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
