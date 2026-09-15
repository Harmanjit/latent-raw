// The two small pictures a DNG carries besides its raw pixels.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The preview JPEG and the thumbnail, made from one rendered image.
///
/// A raw's pixels mean nothing until a raw converter develops them, which is
/// slow. So a DNG also carries ready-made pictures: an 8-bit RGB thumbnail
/// in IFD0, where the Finder and older readers look first, and a JPEG
/// preview in a SubIFD, big enough for a grid or a quick look. Both show
/// the image as the merge rendered it, stored unrotated like the raw pixels
/// (the file's Orientation tag applies to all three) and encoded as sRGB.
struct DNGPreviewImages {
    struct Thumbnail {
        let width: Int
        let height: Int
        /// Interleaved 8-bit RGB, row by row.
        let rgb: [UInt8]
    }

    struct JPEG {
        let width: Int
        let height: Int
        let data: Data
    }

    let thumbnail: Thumbnail
    let jpeg: JPEG

    init(image: CGImage, thumbnailLongEdge: Int, previewLongEdge: Int, jpegQuality: Double = 0.85) throws {
        guard image.width > 0, image.height > 0, thumbnailLongEdge > 0, previewLongEdge > 0,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw MergeDNGError.previewEncodingFailed }

        let (previewWidth, previewHeight) = Self.fitted(image, longEdge: previewLongEdge)
        let preview = try Self.draw(image, width: previewWidth, height: previewHeight, in: sRGB)
        guard let previewImage = preview.makeImage() else { throw MergeDNGError.previewEncodingFailed }
        jpeg = JPEG(width: previewWidth, height: previewHeight,
                    data: try Self.encodeJPEG(previewImage, quality: jpegQuality))

        // The thumbnail comes from the preview, not the original: already
        // small, so the second resample is cheap.
        let (thumbWidth, thumbHeight) = Self.fitted(previewImage, longEdge: thumbnailLongEdge)
        let thumb = try Self.draw(previewImage, width: thumbWidth, height: thumbHeight, in: sRGB)
        guard let rgbx = thumb.data else { throw MergeDNGError.previewEncodingFailed }
        // The context is RGBX (Core Graphics has no 24-bit format); drop the X.
        let bytes = UnsafeBufferPointer(start: rgbx.assumingMemoryBound(to: UInt8.self), count: thumbWidth * thumbHeight * 4)
        var rgb = [UInt8](repeating: 0, count: thumbWidth * thumbHeight * 3)
        for i in 0..<(thumbWidth * thumbHeight) {
            rgb[i * 3] = bytes[i * 4]
            rgb[i * 3 + 1] = bytes[i * 4 + 1]
            rgb[i * 3 + 2] = bytes[i * 4 + 2]
        }
        thumbnail = Thumbnail(width: thumbWidth, height: thumbHeight, rgb: rgb)
    }

    /// The size with the long edge at most `longEdge`, aspect kept, never
    /// enlarged, and at least 1 x 1.
    static func fitted(_ image: CGImage, longEdge: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        return (max(1, Int((Double(image.width) * scale).rounded())),
                max(1, Int((Double(image.height) * scale).rounded())))
    }

    /// Draws `image` resampled into an 8-bit sRGB context of the given size.
    private static func draw(_ image: CGImage, width: Int, height: Int, in space: CGColorSpace) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw MergeDNGError.previewEncodingFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw MergeDNGError.previewEncodingFailed }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MergeDNGError.previewEncodingFailed }
        return data as Data
    }
}
