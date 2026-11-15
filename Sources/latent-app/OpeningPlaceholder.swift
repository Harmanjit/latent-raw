import SwiftUI
import ImageIO
import RawCore
import Catalog
import PixelEngine

/// The camera's embedded JPEG of a raw being opened, shown in Loupe the
/// moment it is decoded (about 50 ms) and replaced by Latent's own render
/// once the raw has decoded (plan fix #18). It looks like the camera's
/// rendering, not Latent's, so the picture visibly changes when the render
/// arrives; it is only used where its framing matches (no crop or
/// perspective change in the stored edit).
///
/// `@unchecked Sendable`: a CGImage is immutable once made.
struct OpeningPlaceholder: @unchecked Sendable, Equatable {
    let image: CGImage
    let url: URL

    static func == (a: OpeningPlaceholder, b: OpeningPlaceholder) -> Bool {
        a.url == b.url && a.image === b.image
    }

    /// The long edge it is decoded at: enough for a full-screen Loupe on
    /// most displays, and quick (the JPEG decoder scales as it decodes).
    static let maxPixelSize = 2560

    /// Reads the embedded JPEG through the raw decoder (in its isolated
    /// service when there is one, as the thumbnailer does; metadata only,
    /// so a few milliseconds), decodes it with ImageIO turned upright, and
    /// turns it by the user's quarter turns. nil for a rendered image
    /// (it opens quickly anyway) and for a raw without a preview.
    static func make(url: URL, userRotation: Int, maxPixelSize: Int = maxPixelSize) -> OpeningPlaceholder? {
        guard !RenderedImageFormat.handles(path: url.path),
              let raw = try? RawFile(path: url.path, metadataOnly: true),
              let jpeg = raw.embeddedJPEGPreview(),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // ImageIO turned it by the JPEG's own orientation tag; without
        // one, the raw's orientation applies, as for thumbnails.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1 {
            image = Thumbnailer.rotated(image, quarterTurns: ImageRotation(libRawFlip: raw.summary.orientation).rawValue)
        }
        image = Thumbnailer.rotated(image, quarterTurns: userRotation)
        return OpeningPlaceholder(image: image, url: url)
    }
}

extension EditorModel {
    /// Starts decoding the placeholder for `url` off the main thread.
    nonisolated static func startPlaceholder(url: URL, userRotation: Int) -> Task<OpeningPlaceholder?, Never> {
        Task.detached(priority: .userInitiated) {
            OpeningPlaceholder.make(url: url, userRotation: userRotation)
        }
    }

    /// Whether the camera's JPEG is framed as the render will be: true with
    /// no stored edit, or one without a crop or perspective change. An
    /// edit that can't be read is treated as framed differently.
    nonisolated static func placeholderMatchesFraming(_ editStackJSON: String?) -> Bool {
        guard let editStackJSON else { return true }
        guard let stack = try? EditStack.decode(json: editStackJSON) else { return false }
        return stack.modules.crop == nil && stack.modules.perspective == nil
    }
}

/// The placeholder over the viewport, fitted as the image is at fit.
struct OpeningPlaceholderView: View {
    let placeholder: OpeningPlaceholder
    let background: Color
    let mirrored: Bool

    var body: some View {
        ZStack {
            background
            Image(decorative: placeholder.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
