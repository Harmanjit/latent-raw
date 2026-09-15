import Foundation

/// What a Photo Merge result says about itself, read from the
/// `latent:Merge` element of its XMP packet.
///
/// The element holds a JSON recipe (kind, sources, options and more; see
/// docs/PhotoMerge.md). Rendering needs only four of its values and the
/// optional lens, so only those are decoded, and every other key is
/// ignored: a later version of Latent can add to the recipe without this
/// reader failing on it.
///
/// A file with no such element, or one whose element doesn't hold usable
/// JSON with these four values, has no merge info (`nil`). That is never
/// an error: the file still opens, as an ordinary linear DNG.
public struct LinearMergeInfo: Sendable, Equatable, Codable {
    /// "hdr", "panorama" or "hdrPanorama". Kept as the string the file
    /// holds, so a kind this version doesn't know still opens.
    public let kind: String
    /// The stored value at or above which a pixel was clipped in every
    /// source frame. Highlight reconstruction treats this, not 1.0, as the
    /// sensor's white. Always finite and above zero.
    public let clipLevel: Float
    /// True when lens corrections (distortion, vignetting, chromatic
    /// aberration) are already in the pixels, as for a panorama: applying
    /// a lens profile again would correct the lens twice.
    public let lensApplied: Bool
    /// How many stops the writer divided the pixels by to keep the
    /// brightest value at or below 1.0, and added to BaselineExposure.
    public let baselineShift: Int
    /// The reference frame's lens exactly as its raw file described it, or
    /// nil for a recipe written before merges recorded it.
    public let lens: Lens?

    public init(kind: String, clipLevel: Float, lensApplied: Bool, baselineShift: Int, lens: Lens? = nil) {
        self.kind = kind
        self.clipLevel = clipLevel
        self.lensApplied = lensApplied
        self.baselineShift = baselineShift
        self.lens = lens
    }

    public static let namespace = "https://github.com/Harmanjit/latent-raw/ns/1.0/"
    public static let elementName = "Merge"

    enum CodingKeys: String, CodingKey {
        case kind, clipLevel, lensApplied, baselineShift, lens
    }

    /// Checks the values as well as their types, both when the recipe is
    /// read from the file and when the decoder service's reply is read in
    /// the app, so a clip level of zero or below can never reach a shader.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        clipLevel = try container.decode(Float.self, forKey: .clipLevel)
        lensApplied = try container.decode(Bool.self, forKey: .lensApplied)
        baselineShift = try container.decode(Int.self, forKey: .baselineShift)
        // The lens only improves lens-profile matching, so a damaged one is
        // dropped (the DNG's EXIF lens tags stand in) rather than costing
        // the clip level and lens state, which rendering can't do without.
        lens = (try? container.decodeIfPresent(Lens.self, forKey: .lens)) ?? nil
        guard clipLevel.isFinite, clipLevel > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .clipLevel, in: container,
                                                   debugDescription: "clipLevel must be finite and above zero")
        }
    }

    /// The recipe's `"lens"` object: a merge's reference frame's lens, as
    /// LibRaw read it from that frame's raw file.
    ///
    /// **Why the recipe carries it.** Lens profiles are matched on more
    /// than a name (`LensMatcher`): maker-notes names, maker lens IDs and
    /// Nikon's lens ID and type, which live in the camera's maker notes. A
    /// merge's DNG has no maker notes, and EXIF has no tags for those IDs,
    /// so without this copy the merge would be matched on less than its
    /// source frames were, and could get a different profile. A linear
    /// source's `RawSummary` uses these values in place of what LibRaw
    /// reads from the DNG's EXIF lens tags.
    ///
    /// The JSON is flat, one key per field, named as the Swift properties
    /// are. Keys this version doesn't know are ignored, and a missing key
    /// reads as "the file didn't say" (empty text, 0), as LibRaw reports it.
    public struct Lens: Sendable, Equatable, Codable {
        /// The EXIF lens name, as the raw reported it (often empty: many
        /// cameras record the lens only in their maker notes).
        public let model: String
        public let identity: LensIdentity

        public init(model: String, identity: LensIdentity) {
            self.model = model
            self.identity = identity
        }

        enum CodingKeys: String, CodingKey {
            case model, make, makerNotesName, makerLensID, nikonLensID, nikonLensType
            case minFocal, maxFocal, maxApertureAtMinFocal, maxApertureAtMaxFocal, cropFactor
        }

        /// LibRaw's `LIBRAW_LENS_NOT_SET`: the maker lens ID of a file that
        /// doesn't have one. JSON numbers hold it exactly (it is written as
        /// an integer), but a missing key means the same thing.
        public static let makerLensIDNotSet = UInt64.max

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            identity = LensIdentity(
                make: try c.decodeIfPresent(String.self, forKey: .make) ?? "",
                makerNotesName: try c.decodeIfPresent(String.self, forKey: .makerNotesName) ?? "",
                makerLensID: try c.decodeIfPresent(UInt64.self, forKey: .makerLensID) ?? Self.makerLensIDNotSet,
                nikonLensID: try c.decodeIfPresent(UInt8.self, forKey: .nikonLensID) ?? 0,
                nikonLensType: try c.decodeIfPresent(UInt8.self, forKey: .nikonLensType) ?? 0,
                minFocal: try c.decodeIfPresent(Double.self, forKey: .minFocal) ?? 0,
                maxFocal: try c.decodeIfPresent(Double.self, forKey: .maxFocal) ?? 0,
                maxApertureAtMinFocal: try c.decodeIfPresent(Double.self, forKey: .maxApertureAtMinFocal) ?? 0,
                maxApertureAtMaxFocal: try c.decodeIfPresent(Double.self, forKey: .maxApertureAtMaxFocal) ?? 0,
                cropFactor: try c.decodeIfPresent(Double.self, forKey: .cropFactor) ?? 0)
        }

        /// Every field, unknowns included, so a reader never has to guess
        /// whether a missing key was left out on purpose.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            let i = identity
            try c.encode(model, forKey: .model)
            try c.encode(i.make, forKey: .make)
            try c.encode(i.makerNotesName, forKey: .makerNotesName)
            try c.encode(i.makerLensID, forKey: .makerLensID)
            try c.encode(i.nikonLensID, forKey: .nikonLensID)
            try c.encode(i.nikonLensType, forKey: .nikonLensType)
            // LibRaw hands over any NaN as is; JSON has no NaN (the encoder
            // would throw), and "unknown" is 0 everywhere else.
            func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
            try c.encode(finite(i.minFocal), forKey: .minFocal)
            try c.encode(finite(i.maxFocal), forKey: .maxFocal)
            try c.encode(finite(i.maxApertureAtMinFocal), forKey: .maxApertureAtMinFocal)
            try c.encode(finite(i.maxApertureAtMaxFocal), forKey: .maxApertureAtMaxFocal)
            try c.encode(finite(i.cropFactor), forKey: .cropFactor)
        }
    }

    /// Reads the merge info from an XMP packet, or nil when there is none
    /// or it can't be used. Never throws: a damaged packet is simply no
    /// merge info.
    ///
    /// The packet is parsed with Foundation's XML parser, with namespaces,
    /// so the element is found by its namespace URI whatever prefix the
    /// writer chose. The JSON may sit in a CDATA section (as Latent writes
    /// it) or as escaped text; the parser hands back the same characters
    /// either way. In the app this runs in the decoder service, beside
    /// LibRaw: the app itself never parses a file's XML.
    public static func parse(xmpPacket: Data) -> LinearMergeInfo? {
        // Real packets are a few kilobytes. Anything far larger isn't worth
        // parsing for four values.
        guard !xmpPacket.isEmpty, xmpPacket.count <= 1 << 20 else { return nil }
        let finder = ElementFinder()
        let parser = XMLParser(data: xmpPacket)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = finder
        _ = parser.parse()
        // A parse error after the element was read (a packet cut short
        // after it, say) doesn't spoil what was found.
        guard let json = finder.text, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LinearMergeInfo.self, from: data)
    }

    /// Collects the text of the first `latent:Merge` element, or the value
    /// of a `latent:Merge` attribute (XMP allows simple properties either
    /// way, and some tools rewrite one form as the other).
    private final class ElementFinder: NSObject, XMLParserDelegate {
        var text: String?
        private var collecting: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard text == nil, collecting == nil else { return }
            if namespaceURI == LinearMergeInfo.namespace, elementName == LinearMergeInfo.elementName {
                collecting = ""
                return
            }
            // With namespace processing on, attribute names keep their
            // prefix, so the prefix has to be matched to the namespace.
            for (name, value) in attributes {
                let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1] == LinearMergeInfo.elementName,
                      attributes["xmlns:\(parts[0])"] == LinearMergeInfo.namespace
                        || prefixes[parts[0]] == LinearMergeInfo.namespace else { continue }
                text = value
                parser.abortParsing()
                return
            }
        }

        /// Prefixes in scope, from `didStartMappingPrefix`.
        private var prefixes: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix] = namespaceURI
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            collecting?.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            collecting?.append(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard let collected = collecting, namespaceURI == LinearMergeInfo.namespace,
                  elementName == LinearMergeInfo.elementName else { return }
            text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            collecting = nil
            parser.abortParsing()
        }
    }
}
