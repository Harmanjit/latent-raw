import Foundation

/// The filter bar's settings as JSON, for named filter presets. Every key
/// is optional on the way in, so a preset saved before a criterion existed
/// reads back with that criterion off (its rating as At least). The
/// Recently Added view is a moment's list, not a setting, and isn't kept.
extension LibraryFilter: Codable {
    private enum CodingKeys: String, CodingKey {
        case minRating, maxRating, ratingOperator, flags, editedOnly, uneditedOnly
        case camera, lens, keyword, noKeywords, text, textScope, finderTag
        case labels, excludedLabels
        case isoRange, focalRange, apertureRange, shutterRange, captureDateRange
        case fileKind, copyKind, integrity
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minRating = try c.decodeIfPresent(Int.self, forKey: .minRating) ?? 0
        maxRating = try c.decodeIfPresent(Int.self, forKey: .maxRating) ?? 5
        ratingOperator = (try? c.decodeIfPresent(RatingOperator.self, forKey: .ratingOperator)) ?? .atLeast
        flags = Set((try c.decodeIfPresent([Int].self, forKey: .flags) ?? []).compactMap(ImageFlag.init(rawValue:)))
        editedOnly = try c.decodeIfPresent(Bool.self, forKey: .editedOnly) ?? false
        uneditedOnly = try c.decodeIfPresent(Bool.self, forKey: .uneditedOnly) ?? false
        camera = try c.decodeIfPresent(String.self, forKey: .camera)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
        noKeywords = try c.decodeIfPresent(Bool.self, forKey: .noKeywords) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        textScope = (try? c.decodeIfPresent(TextSearchScope.self, forKey: .textScope)) ?? .names
        finderTag = try c.decodeIfPresent(String.self, forKey: .finderTag)
        labels = Set((try c.decodeIfPresent([String].self, forKey: .labels) ?? []).compactMap(LabelFilterChoice.init(code:)))
        excludedLabels = Set((try c.decodeIfPresent([String].self, forKey: .excludedLabels) ?? [])
            .compactMap(LabelFilterChoice.init(code:)))
        isoRange = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .isoRange)
        focalRange = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .focalRange)
        apertureRange = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .apertureRange)
        shutterRange = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .shutterRange)
        captureDateRange = try c.decodeIfPresent(ClosedRange<Date>.self, forKey: .captureDateRange)
        fileKind = (try? c.decodeIfPresent(FileKindFilter.self, forKey: .fileKind)) ?? .any
        copyKind = (try? c.decodeIfPresent(CopyKindFilter.self, forKey: .copyKind)) ?? .any
        integrity = (try? c.decodeIfPresent(FileIntegrity.State.self, forKey: .integrity)) ?? nil
    }

    /// Only what differs from the default is written, so a preset holds
    /// just the criteria it sets.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if minRating != 0 { try c.encode(minRating, forKey: .minRating) }
        if maxRating != 5 { try c.encode(maxRating, forKey: .maxRating) }
        if ratingOperator != .atLeast { try c.encode(ratingOperator, forKey: .ratingOperator) }
        if !flags.isEmpty { try c.encode(flags.map(\.rawValue).sorted(), forKey: .flags) }
        if editedOnly { try c.encode(true, forKey: .editedOnly) }
        if uneditedOnly { try c.encode(true, forKey: .uneditedOnly) }
        try c.encodeIfPresent(camera, forKey: .camera)
        try c.encodeIfPresent(lens, forKey: .lens)
        try c.encodeIfPresent(keyword, forKey: .keyword)
        if noKeywords { try c.encode(true, forKey: .noKeywords) }
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if textScope != .names { try c.encode(textScope, forKey: .textScope) }
        try c.encodeIfPresent(finderTag, forKey: .finderTag)
        if !labels.isEmpty { try c.encode(labels.map(\.code).sorted(), forKey: .labels) }
        if !excludedLabels.isEmpty { try c.encode(excludedLabels.map(\.code).sorted(), forKey: .excludedLabels) }
        try c.encodeIfPresent(isoRange, forKey: .isoRange)
        try c.encodeIfPresent(focalRange, forKey: .focalRange)
        try c.encodeIfPresent(apertureRange, forKey: .apertureRange)
        try c.encodeIfPresent(shutterRange, forKey: .shutterRange)
        try c.encodeIfPresent(captureDateRange, forKey: .captureDateRange)
        if fileKind != .any { try c.encode(fileKind, forKey: .fileKind) }
        if copyKind != .any { try c.encode(copyKind, forKey: .copyKind) }
        try c.encodeIfPresent(integrity, forKey: .integrity)
    }
}

extension LabelFilterChoice {
    /// How a preset writes the choice: the label's word, or "none" / "custom".
    public var code: String {
        switch self {
        case .color(let color): color.rawValue
        case .none: "none"
        case .custom: "custom"
        }
    }

    public init?(code: String) {
        switch code {
        case "none": self = .none
        case "custom": self = .custom
        default:
            guard let color = ColorLabel(rawValue: code) else { return nil }
            self = .color(color)
        }
    }
}
