import Foundation
import ImageIO

/// How much of a photo's metadata an export writes, as Lightroom's
/// Include menu offers it. `ExportMetadata` builds everything first; the
/// level then keeps only its share, so every level reads the same source.
///
/// - **All**: everything `ExportMetadata` describes.
/// - **All except camera info**: drops what identifies the camera and how
///   it was set (make, model, lens, exposure, maker notes, serial numbers);
///   keeps the capture date, IPTC fields, keywords and rating. Location
///   still follows its own switch.
/// - **Copyright and contact**: only the copyright notice, the creator and
///   their contact details.
/// - **Copyright only**: only the copyright notice.
///
/// The technical fields every file needs whatever the level (its pixel
/// size, colour space and upright orientation) always stay.
public enum ExportMetadataLevel: String, Sendable, Codable, CaseIterable {
    case all
    case allExceptCameraInfo
    case copyrightAndContact
    case copyrightOnly

    public var title: String {
        switch self {
        case .all: "All"
        case .allExceptCameraInfo: "All except camera info"
        case .copyrightAndContact: "Copyright and contact"
        case .copyrightOnly: "Copyright only"
        }
    }

    /// Whether keywords and the rating go into the file at this level.
    public var includesKeywordsAndRating: Bool { self == .all || self == .allExceptCameraInfo }

    /// Whether location can be written at this level (its switch decides).
    public var allowsLocation: Bool { self == .all || self == .allExceptCameraInfo }

    // MARK: - Filtering

    static let tiffKey = kCGImagePropertyTIFFDictionary as String
    static let exifKey = kCGImagePropertyExifDictionary as String
    static let iptcKey = kCGImagePropertyIPTCDictionary as String
    static let gpsKey = kCGImagePropertyGPSDictionary as String

    /// EXIF fields every level keeps: they describe the file, not the photo.
    static let technicalExif: Set<String> = [
        kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
        kCGImagePropertyExifColorSpace as String,
    ]

    /// EXIF fields "all except camera info" keeps besides the technical
    /// ones: when the photo was taken, and words about it.
    static let dateExif: Set<String> = [
        kCGImagePropertyExifDateTimeOriginal as String, kCGImagePropertyExifDateTimeDigitized as String,
        kCGImagePropertyExifSubsecTime as String, kCGImagePropertyExifSubsecTimeOriginal as String,
        kCGImagePropertyExifSubsecTimeDigitized as String, kCGImagePropertyExifOffsetTime as String,
        kCGImagePropertyExifOffsetTimeOriginal as String, kCGImagePropertyExifOffsetTimeDigitized as String,
        kCGImagePropertyExifUserComment as String,
    ]

    /// TIFF fields that name the camera.
    static let cameraTIFF: Set<String> = [kCGImagePropertyTIFFMake as String, kCGImagePropertyTIFFModel as String]

    /// XMP namespaces that describe the camera and its settings.
    static let cameraNamespaces: Set<String> = [
        "http://ns.adobe.com/exif/1.0/aux/",  // aux: lens, serial numbers, firmware
        "http://cipa.jp/exif/1.0/",           // exifEX: lens and body details
    ]
    static let exifNamespace = "http://ns.adobe.com/exif/1.0/"
    static let tiffNamespace = "http://ns.adobe.com/tiff/1.0/"
    static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    static let rightsNamespace = "http://ns.adobe.com/xap/1.0/rights/"
    static let iptcCoreNamespace = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
    static let photoshopNamespace = "http://ns.adobe.com/photoshop/1.0/"

    /// The share of `properties` and `xmp` this level writes.
    func filtered(properties: [String: Any], xmp: CGMutableImageMetadata?) -> ([String: Any], CGImageMetadata?) {
        switch self {
        case .all:
            return (properties, xmp)
        case .allExceptCameraInfo:
            var props = properties
            var tiff = props[Self.tiffKey] as? [String: Any] ?? [:]
            for key in Self.cameraTIFF { tiff[key] = nil }
            props[Self.tiffKey] = tiff
            let exif = props[Self.exifKey] as? [String: Any] ?? [:]
            props[Self.exifKey] = exif.filter { Self.technicalExif.contains($0.key) || Self.dateExif.contains($0.key) }
            // Everything else that is about the camera: ExifAux, maker
            // notes, the DNG and raw dictionaries.
            for key in props.keys where key == kCGImagePropertyExifAuxDictionary as String
                || key.hasPrefix("{Maker") || key == kCGImagePropertyDNGDictionary as String
                || key == kCGImagePropertyRawDictionary as String || key == kCGImagePropertyCIFFDictionary as String {
                props[key] = nil
            }
            let kept = xmp.map { Self.copying($0) { namespace, name in
                if Self.cameraNamespaces.contains(namespace) { return false }
                if namespace == Self.exifNamespace { return name.hasPrefix("DateTime") || name == "UserComment" }
                if namespace == Self.tiffNamespace { return name != "Make" && name != "Model" }
                return true
            } } ?? nil
            return (props, kept)
        case .copyrightAndContact, .copyrightOnly:
            let contact = self == .copyrightAndContact
            var props: [String: Any] = [:]
            if let orientation = properties[kCGImagePropertyOrientation as String] {
                props[kCGImagePropertyOrientation as String] = orientation
            }
            let tiffIn = properties[Self.tiffKey] as? [String: Any] ?? [:]
            var tiffKeep: Set<String> = [kCGImagePropertyTIFFCopyright as String, kCGImagePropertyTIFFOrientation as String]
            if contact { tiffKeep.insert(kCGImagePropertyTIFFArtist as String) }
            props[Self.tiffKey] = tiffIn.filter { tiffKeep.contains($0.key) }
            let exifIn = properties[Self.exifKey] as? [String: Any] ?? [:]
            props[Self.exifKey] = exifIn.filter { Self.technicalExif.contains($0.key) }
            let iptcIn = properties[Self.iptcKey] as? [String: Any] ?? [:]
            var iptcKeep: Set<String> = [kCGImagePropertyIPTCCopyrightNotice as String]
            if contact {
                iptcKeep.formUnion([kCGImagePropertyIPTCByline as String, kCGImagePropertyIPTCBylineTitle as String,
                                    kCGImagePropertyIPTCCreatorContactInfo as String, kCGImagePropertyIPTCCredit as String])
            }
            let iptc = iptcIn.filter { iptcKeep.contains($0.key) }
            if !iptc.isEmpty { props[Self.iptcKey] = iptc }
            let kept = xmp.map { Self.copying($0) { namespace, name in
                if namespace == Self.rightsNamespace { return true }
                if namespace == Self.dcNamespace { return name == "rights" || (contact && name == "creator") }
                guard contact else { return false }
                if namespace == Self.iptcCoreNamespace { return name == "CreatorContactInfo" }
                if namespace == Self.photoshopNamespace { return name == "AuthorsPosition" || name == "Credit" }
                return false
            } } ?? nil
            return (props, kept)
        }
    }

    /// A new metadata object holding the top-level tags of `source` that
    /// `keep` accepts; nil when none are left.
    static func copying(_ source: CGImageMetadata, keep: (String, String) -> Bool) -> CGImageMetadata? {
        let result = CGImageMetadataCreateMutable()
        var added = false
        for tag in CGImageMetadataCopyTags(source) as? [CGImageMetadataTag] ?? [] {
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  keep(namespace, name) else { continue }
            _ = CGImageMetadataRegisterNamespaceForPrefix(result, namespace as CFString, prefix as CFString, nil)
            added = CGImageMetadataSetTagWithPath(result, nil, "\(prefix):\(name)" as CFString, tag) || added
        }
        return added ? result : nil
    }
}
