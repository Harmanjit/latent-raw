import Foundation
import ImageIO

/// The photo's own metadata, for exports to carry: EXIF, TIFF, GPS, IPTC
/// and ExifAux as ImageIO reads them, plus the XMP fields those
/// dictionaries don't cover (captions in XMP only, IPTC Extension
/// locations, other applications' namespaces).
///
/// Reading it parses the raw file, so in the app it happens in the
/// decoder service, like everything else that parses a raw. What crosses
/// back is two binary property lists and nothing else: the dictionaries,
/// and the XMP tags as a tree of plain dictionaries rather than an XMP
/// packet, so the app never runs an XML parser on bytes the service made.
///
/// The service also removes what describes the raw's storage rather than
/// the photo (compression, CFA pattern, the orientation the pixels no
/// longer have, source-frame coordinates, Camera Raw's edit settings).
/// What depends on the finished file (pixel size, colour space) and
/// Latent's own keywords and rating are set at export (`ExportMetadata`).
public struct SourceMetadata: Sendable, Equatable {
    /// Binary plist: a dictionary holding the carried ImageIO property
    /// dictionaries (keys such as "{Exif}") and the DPI values.
    public let properties: Data
    /// Binary plist: an array of XMP tag trees (see `xmpNode`), or nil
    /// when the file has no XMP fields beyond the dictionaries.
    public let xmpTags: Data?

    /// Neither payload is anywhere near this for a real photo. A peer
    /// sending more is refused, so a compromised service can't make the
    /// app decode something huge.
    static let maxPayloadBytes = 4 << 20
    /// Nested XMP deeper than this is dropped; real files go 3 or 4 deep.
    static let maxXMPDepth = 8

    public enum ReadError: Error, CustomStringConvertible {
        case payloadTooLarge(Int)
        public var description: String {
            switch self {
            case .payloadTooLarge(let n): "source metadata of \(n) bytes refused"
            }
        }
    }

    /// Reads the metadata of the raw at `path`: in the decoder service when
    /// the app bundle carries it, in this process otherwise (tests, CLI).
    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RawFileError.fileNotFound(path: path)
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw RawFileError.mmapFailed(errno: errno) }
        defer { close(fd) }
        if RawDecoderXPC.isServiceAvailable {
            self = try RawDecoderClient.shared.readMetadata(fileDescriptor: fd)
        } else {
            try self.init(fileDescriptor: fd)
        }
    }

    /// In-process read over a read-only map of `fd`. The decoder service
    /// runs this on the descriptor it is handed.
    public init(fileDescriptor fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw RawFileError.mmapFailed(errno: errno) }
        let length = Int(st.st_size)
        guard length > 0, let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != MAP_FAILED else {
            throw RawFileError.mmapFailed(errno: errno)
        }
        // ImageIO reads the mapped pages directly; the map goes when the
        // last reference to the data does.
        let data = Data(bytesNoCopy: mapped, count: length, deallocator: .unmap)
        self.init(imageData: data)
    }

    /// What a reply from the service carries, size-checked.
    init(properties: Data, xmpTags: Data?) throws {
        for payload in [properties, xmpTags ?? Data()] where payload.count > Self.maxPayloadBytes {
            throw ReadError.payloadTooLarge(payload.count)
        }
        self.properties = properties
        self.xmpTags = xmpTags
    }

    /// Reads and cleans the metadata of an encoded image. A file ImageIO
    /// can't read gives empty metadata, not an error: the export still gets
    /// the fields LibRaw reported.
    init(imageData: Data) {
        var carried: [String: Any] = [:]
        var nodes: [[String: Any]] = []
        if let source = CGImageSourceCreateWithData(imageData as CFData,
                                                    [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            if let all = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] {
                carried = Self.scrubbed(all)
            }
            if let xmp = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
                nodes = Self.xmpNodes(xmp)
            }
        }
        properties = (try? PropertyListSerialization.data(fromPropertyList: carried, format: .binary, options: 0))
            ?? Data()
        xmpTags = nodes.isEmpty ? nil
            : try? PropertyListSerialization.data(fromPropertyList: nodes, format: .binary, options: 0)
    }

    // MARK: - Property dictionaries

    /// The dictionaries worth carrying. Everything else in ImageIO's
    /// result describes the source image (its pixel size, depth, colour
    /// model) or is a maker's private block that can't be written back.
    static var carriedDictionaries: [String] {
        [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
         kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary].map { $0 as String }
    }
    static var carriedValues: [String] {
        [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight].map { $0 as String }
    }

    /// Tags that describe how the raw stored its pixels, not the photo.
    /// Copied into a JPEG they would lie about it (a "CFA" photometric
    /// interpretation, the camera's orientation for pixels Latent has
    /// already turned upright). Colour description goes too: the embedded
    /// profile says what the colours are. Pixel size and colour space are
    /// removed here and set afresh for the written file.
    /// (Computed, because CF strings aren't `Sendable`.)
    static var structuralTags: [String: [String]] {
        [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
                kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
                kCGImagePropertyTIFFTransferFunction, kCGImagePropertyTIFFWhitePoint,
                kCGImagePropertyTIFFPrimaryChromaticities, kCGImagePropertyTIFFOrientation,
            ].map { $0 as String },
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifCompressedBitsPerPixel,
                kCGImagePropertyExifCFAPattern, kCGImagePropertyExifGamma,
                kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                kCGImagePropertyExifColorSpace,
                // Positions and densities in the sensor's pixel grid, wrong
                // once the image is cropped, turned or resized.
                kCGImagePropertyExifSubjectArea, kCGImagePropertyExifSubjectLocation,
                kCGImagePropertyExifFocalPlaneXResolution, kCGImagePropertyExifFocalPlaneYResolution,
                kCGImagePropertyExifFocalPlaneResolutionUnit,
            ].map { $0 as String },
            // Autofocus areas, in the uncropped, unrotated frame.
            kCGImagePropertyExifAuxDictionary as String: ["AFInfo"],
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCImageOrientation as String],
        ]
    }

    /// The carried part of ImageIO's properties, structural tags removed
    /// and every value checked to be a property-list type.
    static func scrubbed(_ all: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in carriedValues {
            if let value = all[key] as? NSNumber { result[key] = value }
        }
        let structural = structuralTags
        for key in carriedDictionaries {
            guard var dictionary = all[key] as? [String: Any] else { continue }
            for tag in structural[key] ?? [] { dictionary[tag] = nil }
            if let clean = plistValue(dictionary, depth: 0) as? [String: Any], !clean.isEmpty {
                result[key] = clean
            }
        }
        return result
    }

    /// `value` if it (and everything inside it) is a property-list type.
    /// Anything else is dropped rather than failing the whole encode.
    static func plistValue(_ value: Any, depth: Int) -> Any? {
        guard depth <= maxXMPDepth else { return nil }
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n
        case let d as Data: return d
        case let d as Date: return d
        case let a as [Any]: return a.compactMap { plistValue($0, depth: depth + 1) }
        case let d as [String: Any]: return d.compactMapValues { plistValue($0, depth: depth + 1) }
        default: return nil
        }
    }

    /// The carried dictionaries, decoded for the export. Filtered again to
    /// the expected keys and shapes: the data came from another process.
    public func imageProperties() -> [String: Any] {
        guard let decoded = try? PropertyListSerialization.propertyList(from: properties, format: nil)
                as? [String: Any] else { return [:] }
        var result: [String: Any] = [:]
        for key in Self.carriedValues {
            if let value = decoded[key] as? NSNumber { result[key] = value }
        }
        for key in Self.carriedDictionaries {
            if let value = decoded[key] as? [String: Any] { result[key] = value }
        }
        return result
    }

    // MARK: - XMP

    /// Namespaces ImageIO writes from the property dictionaries on its own,
    /// as EXIF tags. Carrying them as XMP too would mean every value changed
    /// at export (orientation, pixel size, colour space) has to change in
    /// two places. ExifAux ("aux") is not among them: it has no EXIF form,
    /// and once an export has XMP, ImageIO writes it only from there.
    static var namespacesFromDictionaries: Set<String> {
        Set([kCGImageMetadataNamespaceExif, kCGImageMetadataNamespaceExifEX,
             kCGImageMetadataNamespaceTIFF].map { $0 as String } + ["http://ns.apple.com/ImageIO/1.0/"])
    }
    /// Whole namespaces dropped. Camera Raw's develop settings ("crs")
    /// describe edits Latent didn't make; left in, Adobe software would
    /// apply them to pixels that are already rendered. Gain map
    /// descriptions describe a map the new file doesn't have.
    static let droppedPrefixes: Set<String> = ["crs", "hdrgm", "HDRGainMap"]
    static let droppedNamespaces: Set<String> = [
        "http://ns.adobe.com/camera-raw-settings/1.0/", "http://ns.adobe.com/hdr-gain-map/1.0/",
        "http://ns.apple.com/HDRGainMap/1.0/",
    ]
    /// Single tags that go stale: an old preview, the source's colour
    /// profile, and the source file's identity (a new file claiming the
    /// raw's document and instance IDs would confuse asset managers).
    static let droppedTags: Set<String> = [
        "http://ns.adobe.com/xap/1.0/ Thumbnails", "http://ns.adobe.com/photoshop/1.0/ ICCProfile",
        "http://ns.adobe.com/xap/1.0/mm/ DocumentID", "http://ns.adobe.com/xap/1.0/mm/ InstanceID",
    ]

    /// The top-level XMP tags to carry, each as a tree of plain values:
    /// ["namespace", "prefix", "name", "type", "value"], where value is a
    /// string, an array of child nodes, or a dictionary of field nodes.
    static func xmpNodes(_ metadata: CGImageMetadata) -> [[String: Any]] {
        let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []
        let fromDictionaries = namespacesFromDictionaries
        return tags.compactMap { tag in
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  !fromDictionaries.contains(namespace), !droppedNamespaces.contains(namespace),
                  !droppedPrefixes.contains(prefix), !droppedTags.contains("\(namespace) \(name)") else { return nil }
            return xmpNode(tag, depth: 0)
        }
    }

    static func xmpNode(_ tag: CGImageMetadataTag, depth: Int) -> [String: Any]? {
        guard depth <= maxXMPDepth,
              let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
              let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
              let name = CGImageMetadataTagCopyName(tag) as String?,
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        let type = CGImageMetadataTagGetType(tag)
        var node: [String: Any] = ["namespace": namespace, "prefix": prefix, "name": name,
                                   "type": Int(type.rawValue)]
        switch type {
        case .default, .string:
            guard let string = value as? String else { return nil }
            node["value"] = string
        case .arrayUnordered, .arrayOrdered, .alternateArray:
            guard let items = value as? [CGImageMetadataTag] else { return nil }
            node["value"] = items.compactMap { xmpNode($0, depth: depth + 1) }
        case .alternateText:
            // ImageIO can only build the default language of an alternative
            // (and itself reads the others back wrongly), so that is what is
            // carried. Only at the top level, where a path can address it.
            guard depth == 0, let items = value as? [CGImageMetadataTag] else { return nil }
            let isDefault: (CGImageMetadataTag) -> Bool = { item in
                let qualifiers = CGImageMetadataTagCopyQualifiers(item) as? [CGImageMetadataTag] ?? []
                return qualifiers.contains { CGImageMetadataTagCopyValue($0) as? String == "x-default" }
            }
            guard let chosen = items.first(where: isDefault) ?? items.first,
                  let string = CGImageMetadataTagCopyValue(chosen) as? String else { return nil }
            node["value"] = string
        case .structure:
            guard let fields = value as? [String: CGImageMetadataTag] else { return nil }
            node["value"] = fields.compactMapValues { xmpNode($0, depth: depth + 1) }
        default:
            return nil
        }
        return node
    }

    /// The carried XMP rebuilt as metadata for the export, through
    /// ImageIO's tag API (no XMP parsing). nil when there is none.
    public func xmpMetadata() -> CGMutableImageMetadata? {
        guard let xmpTags,
              let nodes = try? PropertyListSerialization.propertyList(from: xmpTags, format: nil)
                as? [[String: Any]] else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        var added = false
        for node in nodes {
            guard let prefix = node["prefix"] as? String, let name = node["name"] as? String,
                  Self.isXMLName(prefix), Self.isXMLName(name),
                  let rawType = node["type"] as? Int, Self.register(node, in: metadata) else { continue }
            let path = "\(prefix):\(name)" as CFString
            if rawType == Int(CGImageMetadataType.alternateText.rawValue) {
                guard let string = node["value"] as? String else { continue }
                added = CGImageMetadataSetValueWithPath(metadata, nil, "\(prefix):\(name)[x-default]" as CFString,
                                                        string as CFString) || added
            } else if let tag = Self.xmpTag(node, in: metadata, depth: 0) {
                added = CGImageMetadataSetTagWithPath(metadata, nil, path, tag) || added
            }
        }
        return added ? metadata : nil
    }

    static func xmpTag(_ node: [String: Any], in metadata: CGMutableImageMetadata, depth: Int) -> CGImageMetadataTag? {
        guard depth <= maxXMPDepth,
              let namespace = node["namespace"] as? String, let prefix = node["prefix"] as? String,
              let name = node["name"] as? String, let rawType = node["type"] as? Int,
              let type = CGImageMetadataType(rawValue: Int32(clamping: rawType)),
              register(node, in: metadata) else { return nil }
        let value: CFTypeRef
        switch type {
        case .default, .string:
            guard let string = node["value"] as? String else { return nil }
            value = string as CFString
        case .arrayUnordered, .arrayOrdered, .alternateArray:
            guard let items = node["value"] as? [[String: Any]] else { return nil }
            value = items.compactMap { xmpTag($0, in: metadata, depth: depth + 1) } as CFArray
        case .structure:
            guard let fields = node["value"] as? [String: [String: Any]] else { return nil }
            value = fields.compactMapValues { xmpTag($0, in: metadata, depth: depth + 1) } as CFDictionary
        default:
            return nil
        }
        return CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString, type, value)
    }

    /// Makes the node's prefix known to `metadata`. Registering a prefix
    /// that is already known fails harmlessly; only a prefix ImageIO has
    /// bound to a different namespace makes the node unusable.
    static func register(_ node: [String: Any], in metadata: CGMutableImageMetadata) -> Bool {
        guard let namespace = node["namespace"] as? String, let prefix = node["prefix"] as? String,
              !namespace.isEmpty, isXMLName(prefix) else { return false }
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, prefix as CFString, nil)
        return true
    }

    /// A plain XML name, so a prefix or tag name can't change the meaning
    /// of the ImageIO path it is put into.
    static func isXMLName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.utf8.count <= 128,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
