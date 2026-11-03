import Foundation

/// The rules of a smart collection: criteria combined with all or any, as
/// in Lightroom's Smart Collection dialog. Stored as JSON in the
/// collection's row, so adding a field later only adds a case here.
public struct SmartCollectionRules: Codable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case all, any

        public var title: String {
            switch self {
            case .all: "all"
            case .any: "any"
            }
        }
    }

    public var match: Match
    public var criteria: [SmartCriterion]

    public init(match: Match = .all, criteria: [SmartCriterion] = []) {
        self.match = match
        self.criteria = criteria
    }

    /// Whether `record` belongs. No criteria matches nothing, so an empty
    /// smart collection doesn't quietly show the whole folder.
    public func matches(_ record: ImageRecord, isEdited: Bool, keywords: Set<String>, now: Date = Date()) -> Bool {
        guard !criteria.isEmpty else { return false }
        switch match {
        case .all: return criteria.allSatisfy { $0.matches(record, isEdited: isEdited, keywords: keywords, now: now) }
        case .any: return criteria.contains { $0.matches(record, isEdited: isEdited, keywords: keywords, now: now) }
        }
    }

    /// Whether a change from `old` to `new` can change what these rules
    /// say about the photo, so the grid knows to filter again.
    public func dependsOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
        criteria.contains { $0.field.dependsOnChange(from: old, to: new) }
    }

    /// Whether the rules read keywords or the edited badge, which live
    /// outside the record.
    public var readsKeywords: Bool { criteria.contains { $0.field == .keyword } }
    public var readsEdits: Bool { criteria.contains { $0.field == .edited } }

    /// The filter bar's settings as rules, for Save Filter as Smart
    /// Collection. All its criteria must hold at once, as in the bar.
    public init(filter: LibraryFilter) {
        var criteria: [SmartCriterion] = []
        if filter.minRating > 0 {
            criteria.append(SmartCriterion(.rating, .atLeast, "\(filter.minRating)"))
        }
        if !filter.flags.isEmpty {
            let values = filter.flags.map(\.rawValue).sorted(by: >).map(String.init).joined(separator: ",")
            criteria.append(SmartCriterion(.flag, .is, values))
        }
        if filter.editedOnly { criteria.append(SmartCriterion(.edited, .is, "true")) }
        if let camera = filter.camera { criteria.append(SmartCriterion(.camera, .is, camera)) }
        if let lens = filter.lens { criteria.append(SmartCriterion(.lens, .is, lens)) }
        if let keyword = filter.keyword { criteria.append(SmartCriterion(.keyword, .is, keyword)) }
        if let tag = filter.finderTag { criteria.append(SmartCriterion(.finderTag, .is, tag)) }
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { criteria.append(SmartCriterion(.fileName, .contains, text)) }
        self.init(match: .all, criteria: criteria)
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public init?(json: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = decoded
    }
}

/// One line of a smart collection: a field, how to compare, and a value
/// kept as text (a number, a date as yyyy-MM-dd, a flag's raw values).
public struct SmartCriterion: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case rating, flag, label, edited, keyword, camera, lens, fileName, fileType, finderTag
        case captureDate, iso, focalLength, aperture

        public var title: String {
            switch self {
            case .rating: "Rating"
            case .flag: "Flag"
            case .label: "Colour label"
            case .edited: "Edited"
            case .keyword: "Keyword"
            case .camera: "Camera"
            case .lens: "Lens"
            case .fileName: "File name"
            case .fileType: "File type"
            case .finderTag: "Finder tag"
            case .captureDate: "Capture date"
            case .iso: "ISO"
            case .focalLength: "Focal length"
            case .aperture: "Aperture"
            }
        }

        /// The comparisons that make sense for the field, the first the default.
        public var operators: [Operator] {
            switch self {
            case .rating, .iso, .focalLength, .aperture: [.atLeast, .atMost, .is, .isNot]
            case .flag, .edited: [.is, .isNot]
            case .label: [.is, .isNot]
            case .keyword: [.is, .isNot, .contains, .doesNotContain]
            case .camera, .lens, .fileName, .finderTag:
                [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith]
            case .fileType: [.is, .isNot]
            case .captureDate: [.inLastDays, .is, .before, .after]
            }
        }

        public enum ValueKind: Sendable { case number, text, flag, yesNo, date, days }

        public var valueKind: ValueKind {
            switch self {
            case .rating, .iso, .focalLength, .aperture: .number
            case .flag: .flag
            case .edited: .yesNo
            case .label, .keyword, .camera, .lens, .fileName, .fileType, .finderTag: .text
            case .captureDate: .date
            }
        }

        /// A value to start a new line with, so it means something at once.
        public var defaultValue: String {
            switch self {
            case .rating: "3"
            case .flag: "1"
            case .edited: "true"
            case .iso: "1600"
            case .focalLength: "50"
            case .aperture: "2.8"
            case .captureDate: "30"
            default: ""
            }
        }

        func dependsOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
            switch self {
            case .rating: old.rating != new.rating
            case .flag: old.flag != new.flag
            case .label: old.label != new.label
            case .finderTag: old.finderTags != new.finderTags
            case .fileName, .fileType: old.relPath != new.relPath
            case .captureDate: old.captureTime != new.captureTime
            case .camera: old.camera != new.camera
            case .lens: old.lens != new.lens
            case .iso: old.iso != new.iso
            case .focalLength: old.focal != new.focal
            case .aperture: old.aperture != new.aperture
            case .edited, .keyword: false
            }
        }
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case `is`, isNot, contains, doesNotContain, startsWith, endsWith, atLeast, atMost
        case inLastDays, before, after

        public var title: String {
            switch self {
            case .is: "is"
            case .isNot: "is not"
            case .contains: "contains"
            case .doesNotContain: "doesn’t contain"
            case .startsWith: "starts with"
            case .endsWith: "ends with"
            case .atLeast: "is at least"
            case .atMost: "is at most"
            case .inLastDays: "is in the last"
            case .before: "is before"
            case .after: "is after"
            }
        }

        /// What the date field's value means under this operator.
        public var takesDays: Bool { self == .inLastDays }
    }

    public var field: Field
    public var op: Operator
    public var value: String

    public init(_ field: Field, _ op: Operator, _ value: String) {
        self.field = field
        self.op = op
        self.value = value
    }

    /// A new line for `field` with its first operator and default value.
    public init(field: Field) {
        self.init(field, field.operators[0], field.defaultValue)
    }

    enum CodingKeys: String, CodingKey { case field, op, value }

    public func matches(_ record: ImageRecord, isEdited: Bool, keywords: Set<String>, now: Date = Date()) -> Bool {
        switch field {
        case .rating: return compare(Double(record.rating))
        case .iso: return compare(record.iso.map(Double.init))
        case .focalLength: return compare(record.focal)
        case .aperture: return compare(record.aperture)
        case .flag:
            let wanted = Set(value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            let hit = wanted.contains(record.flag)
            return op == .isNot ? !hit : hit
        case .edited:
            let hit = isEdited == (value != "false")
            return op == .isNot ? !hit : hit
        case .label:
            let wanted = value.trimmingCharacters(in: .whitespaces)
            let label = record.label ?? ""
            let hit = label.compare(wanted, options: [.caseInsensitive]) == .orderedSame
            return op == .isNot ? !hit : hit
        case .keyword:
            let wanted = KeywordPath.normalized(value) ?? ""
            switch op {
            case .contains, .doesNotContain:
                let hit = !wanted.isEmpty && keywords.contains { KeywordPath.components($0).contains { level in
                    level.range(of: value.trimmingCharacters(in: .whitespaces),
                                options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
                return op == .contains ? hit : !hit
            default:
                let hit = !wanted.isEmpty && keywords.contains { KeywordPath.path($0, isWithin: wanted) }
                return op == .isNot ? !hit : hit
            }
        case .camera: return compareText(record.camera)
        case .lens: return compareText(record.lens)
        case .fileName: return compareText(record.fileName)
        case .fileType:
            let ext = (record.relPath as NSString).pathExtension
            let wanted = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let hit = ext.compare(wanted, options: .caseInsensitive) == .orderedSame
            return op == .isNot ? !hit : hit
        case .finderTag:
            let names = record.tags.map(\.name)
            switch op {
            case .isNot, .doesNotContain: return !names.contains { textMatch($0, as: op == .isNot ? .is : .contains) }
            default: return names.contains { textMatch($0, as: op) }
            }
        case .captureDate:
            return compareDate(record.captureTime, now: now)
        }
    }

    private func compare(_ number: Double?) -> Bool {
        guard let wanted = Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else {
            return false
        }
        guard let number else { return op == .isNot }
        switch op {
        case .atLeast: return number >= wanted - 1e-9
        case .atMost: return number <= wanted + 1e-9
        case .is: return abs(number - wanted) < 1e-6
        case .isNot: return abs(number - wanted) >= 1e-6
        default: return false
        }
    }

    private func compareText(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else {
            return op == .isNot || op == .doesNotContain
        }
        switch op {
        case .isNot: return !textMatch(text, as: .is)
        case .doesNotContain: return !textMatch(text, as: .contains)
        default: return textMatch(text, as: op)
        }
    }

    private func textMatch(_ text: String, as op: Operator) -> Bool {
        let wanted = value.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch op {
        case .is: return text.compare(wanted, options: options) == .orderedSame
        case .contains: return text.range(of: wanted, options: options) != nil
        case .startsWith: return text.range(of: wanted, options: options.union(.anchored)) != nil
        case .endsWith: return text.range(of: wanted, options: options.union([.anchored, .backwards])) != nil
        default: return false
        }
    }

    /// Capture times are seconds since 1970 in the camera's own clock; days
    /// are counted in the Mac's calendar.
    private func compareDate(_ captureTime: Int64?, now: Date) -> Bool {
        guard let captureTime else { return false }
        let date = Date(timeIntervalSince1970: TimeInterval(captureTime))
        let calendar = Calendar.current
        if op == .inLastDays {
            guard let days = Int(value.trimmingCharacters(in: .whitespaces)), days > 0,
                  let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
            else { return false }
            return date >= start
        }
        guard let day = Self.parseDay(value) else { return false }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        switch op {
        case .is: return date >= start && date < end
        case .before: return date < start
        case .after: return date >= end
        default: return false
        }
    }

    /// "2026-05-01" in the Mac's time zone.
    public static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    public static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
