import Foundation
import ImageIO

extension ExportDescription {
    /// The IPTC Core fields beyond title, caption, creator and copyright:
    /// written to the IPTC block (Headline, Sub-location, City,
    /// Province/State, Country, Country Code, By-line Title, Special
    /// Instructions and the creator's contact info) and to XMP through the
    /// same properties, so ImageIO files each under photoshop: or
    /// Iptc4xmpCore: as the standard asks. Empty fields are left out.
    public struct More: Sendable, Equatable {
        public var headline: String?
        public var sublocation: String?
        public var city: String?
        public var state: String?
        public var country: String?
        public var countryCode: String?
        public var creatorJobTitle: String?
        public var creatorEmail: String?
        public var creatorURL: String?
        public var instructions: String?

        public init(headline: String? = nil, sublocation: String? = nil, city: String? = nil, state: String? = nil,
                    country: String? = nil, countryCode: String? = nil, creatorJobTitle: String? = nil,
                    creatorEmail: String? = nil, creatorURL: String? = nil, instructions: String? = nil) {
            func clean(_ text: String?) -> String? {
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return text
            }
            self.headline = clean(headline); self.sublocation = clean(sublocation); self.city = clean(city)
            self.state = clean(state); self.country = clean(country); self.countryCode = clean(countryCode)
            self.creatorJobTitle = clean(creatorJobTitle); self.creatorEmail = clean(creatorEmail)
            self.creatorURL = clean(creatorURL); self.instructions = clean(instructions)
        }

        public var isEmpty: Bool { self == More() }

        /// The creator's job title and contact details only, for the
        /// Copyright and contact level.
        public var contactOnly: More {
            More(creatorJobTitle: creatorJobTitle, creatorEmail: creatorEmail, creatorURL: creatorURL)
        }

        /// Without the place names, for an export whose location switch is off.
        public var withoutPlaces: More {
            var copy = self
            copy.sublocation = nil; copy.city = nil; copy.state = nil; copy.country = nil; copy.countryCode = nil
            return copy
        }

        /// Each field's IPTC property and its XMP path.
        private var simple: [(CFString, String, String?)] {
            [(kCGImagePropertyIPTCHeadline, "photoshop:Headline", headline),
             (kCGImagePropertyIPTCSubLocation, "Iptc4xmpCore:Location", sublocation),
             (kCGImagePropertyIPTCCity, "photoshop:City", city),
             (kCGImagePropertyIPTCProvinceState, "photoshop:State", state),
             (kCGImagePropertyIPTCCountryPrimaryLocationName, "photoshop:Country", country),
             (kCGImagePropertyIPTCCountryPrimaryLocationCode, "Iptc4xmpCore:CountryCode", countryCode),
             (kCGImagePropertyIPTCBylineTitle, "photoshop:AuthorsPosition", creatorJobTitle),
             (kCGImagePropertyIPTCSpecialInstructions, "photoshop:Instructions", instructions)]
        }

        private var contactInfo: [String: Any] {
            var info: [String: Any] = [:]
            if let creatorEmail { info[kCGImagePropertyIPTCContactInfoEmails as String] = creatorEmail }
            if let creatorURL { info[kCGImagePropertyIPTCContactInfoWebURLs as String] = creatorURL }
            return info
        }

        func apply(iptc: inout [String: Any]) {
            for (key, _, value) in simple {
                if let value { iptc[key as String] = value }
            }
            let info = contactInfo
            if !info.isEmpty { iptc[kCGImagePropertyIPTCCreatorContactInfo as String] = info }
        }

        func apply(xmp: CGMutableImageMetadata) {
            let iptc = kCGImagePropertyIPTCDictionary
            for (key, path, value) in simple {
                guard let value else { continue }
                // The raw's own value goes first, as for dc:rights: ImageIO
                // won't encode a property set over one already there.
                CGImageMetadataRemoveTagWithPath(xmp, nil, path as CFString)
                CGImageMetadataSetValueMatchingImageProperty(xmp, iptc, key, value as CFString)
            }
        }
    }

    /// This description with `more` in place of its own.
    public func with(more: More) -> ExportDescription {
        var copy = self
        copy.more = more
        return copy
    }

    /// Without the place names (`More.withoutPlaces`).
    public var withoutPlaces: ExportDescription { with(more: more.withoutPlaces) }
}
