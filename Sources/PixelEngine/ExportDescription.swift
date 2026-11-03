import Foundation
import ImageIO

/// The title, caption, creator and copyright an export carries, written
/// where other applications look for them: the IPTC block (Object Name,
/// Caption/Abstract, By-line, Copyright Notice), the TIFF dictionary
/// (Image Description, Artist, Copyright) and XMP (dc:title,
/// dc:description, dc:creator, dc:rights). Empty fields are left out and
/// leave whatever the raw itself said in place.
public struct ExportDescription: Sendable, Equatable {
    public var title: String?
    public var caption: String?
    public var creator: String?
    public var copyright: String?

    public init(title: String? = nil, caption: String? = nil, creator: String? = nil, copyright: String? = nil) {
        self.title = Self.clean(title)
        self.caption = Self.clean(caption)
        self.creator = Self.clean(creator)
        self.copyright = Self.clean(copyright)
    }

    public var isEmpty: Bool { title == nil && caption == nil && creator == nil && copyright == nil }

    /// "Ann Smith; Bo Lee": one name each in By-line and dc:creator.
    var creators: [String] {
        (creator ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    func apply(tiff: inout [String: Any], iptc: inout [String: Any]) {
        if let title { iptc[kCGImagePropertyIPTCObjectName as String] = title }
        if let caption {
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = caption
            tiff[kCGImagePropertyTIFFImageDescription as String] = caption
        }
        if !creators.isEmpty {
            iptc[kCGImagePropertyIPTCByline as String] = creators
            tiff[kCGImagePropertyTIFFArtist as String] = creators.joined(separator: "; ")
        }
        if let copyright {
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = copyright
            tiff[kCGImagePropertyTIFFCopyright as String] = copyright
        }
    }

    /// The same values in XMP, which ImageIO lets win over the
    /// dictionaries when a file has both. Set through the IPTC properties,
    /// so ImageIO gives each the structure the standard asks for (a
    /// language alternative for the title, an ordered list of creators).
    func apply(xmp: CGMutableImageMetadata) {
        let iptc = kCGImagePropertyIPTCDictionary
        // The raw's own values go first: ImageIO won't encode a file whose
        // dc:rights it was asked to set over one already there.
        let replaced = [(title != nil, "dc:title"), (caption != nil, "dc:description"),
                        (!creators.isEmpty, "dc:creator"), (copyright != nil, "dc:rights")]
        for (isSet, path) in replaced where isSet {
            CGImageMetadataRemoveTagWithPath(xmp, nil, path as CFString)
        }
        if let title {
            CGImageMetadataSetValueMatchingImageProperty(xmp, iptc, kCGImagePropertyIPTCObjectName, title as CFString)
        }
        if let caption {
            CGImageMetadataSetValueMatchingImageProperty(xmp, iptc, kCGImagePropertyIPTCCaptionAbstract, caption as CFString)
            CGImageMetadataSetValueMatchingImageProperty(xmp, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFImageDescription, caption as CFString)
        }
        if !creators.isEmpty {
            CGImageMetadataSetValueMatchingImageProperty(xmp, iptc, kCGImagePropertyIPTCByline, creators as CFArray)
        }
        if let copyright {
            CGImageMetadataSetValueMatchingImageProperty(xmp, iptc, kCGImagePropertyIPTCCopyrightNotice, copyright as CFString)
        }
    }
}
