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
        matches(record, context: SmartMatchContext(isEdited: isEdited, keywords: keywords, now: now))
    }

    /// Whether `record` belongs, given everything about it that lives
    /// outside its row (keywords, stacks, edits). Rules whose lines carry
    /// no join of their own combine as `match` says, exactly as before
    /// joins existed; otherwise each line is joined to the result so far,
    /// left to right, by its own join (a line without one takes `match`'s).
    public func matches(_ record: ImageRecord, context: SmartMatchContext) -> Bool {
        guard !criteria.isEmpty else { return false }
        guard hasJoins else {
            switch match {
            case .all: return criteria.allSatisfy { $0.matches(record, context: context) }
            case .any: return criteria.contains { $0.matches(record, context: context) }
            }
        }
        var result = criteria[0].matches(record, context: context)
        for criterion in criteria.dropFirst() {
            switch effectiveJoin(of: criterion) {
            case .and: if result { result = criterion.matches(record, context: context) }
            case .or: if !result { result = criterion.matches(record, context: context) }
            case .except: if result { result = !criterion.matches(record, context: context) }
            }
        }
        return result
    }

    /// Whether any line after the first names its own join.
    public var hasJoins: Bool { criteria.dropFirst().contains { $0.join != nil } }

    /// How a line (after the first) joins the lines above it: its own
    /// join, else the one `match` implies.
    public func effectiveJoin(of criterion: SmartCriterion) -> SmartCriterion.Join {
        criterion.join ?? (match == .all ? .and : .or)
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
    /// Whether the rules read stacks, the photos that have virtual copies,
    /// or what each stored edit changes and when it was saved
    /// (`SmartScopeExtras`).
    public var readsStacks: Bool { criteria.contains { $0.field == .inStack } }
    public var readsVirtualCopyMasters: Bool { criteria.contains { $0.field == .kind } }
    public var readsEditDetails: Bool { criteria.contains { $0.field == .moduleUsed || $0.field == .modifiedDate } }
    /// Whether the rules read the Verify Files results (`SmartScopeExtras`).
    public var readsIntegrity: Bool { criteria.contains { $0.field == .fileIntegrity } }

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
        if let integrity = filter.integrity {
            criteria.append(SmartCriterion(.fileIntegrity, .is, integrity.rawValue))
        }
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

/// What a smart collection reads about a photo beyond its row: whether it
/// has an edit, its keywords, whether it is in a stack or has virtual
/// copies, what its stored edit changes and when that was saved.
public struct SmartMatchContext: Sendable {
    public var isEdited: Bool
    public var keywords: Set<String>
    public var isInStack: Bool
    /// The photo is a master (or ordinary photo) with at least one virtual copy.
    public var hasVirtualCopies: Bool
    /// The edit groups its stored edit changes, by raw value (`EditGroup`
    /// in PixelEngine, which the catalog doesn't link).
    public var editGroups: Set<String>
    /// When its stored edit was last saved, in milliseconds since 1970
    /// (`edits.updated_at`); nil without one.
    public var editedAt: Int64?
    public var now: Date
    /// What Verify Files last said about its file (FileIntegrity.State).
    public var integrity: FileIntegrity.State

    public init(isEdited: Bool = false, keywords: Set<String> = [], isInStack: Bool = false,
                hasVirtualCopies: Bool = false, editGroups: Set<String> = [], editedAt: Int64? = nil,
                now: Date = Date(), integrity: FileIntegrity.State = .unchecked) {
        self.integrity = integrity
        self.isEdited = isEdited
        self.keywords = keywords
        self.isInStack = isInStack
        self.hasVirtualCopies = hasVirtualCopies
        self.editGroups = editGroups
        self.editedAt = editedAt
        self.now = now
    }
}

/// One line of a smart collection: a field, how to compare, and a value
/// kept as text (a number, a date as yyyy-MM-dd, a flag's raw values).
public struct SmartCriterion: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case rating, flag, label, edited, keyword, camera, lens, fileName, fileType, finderTag
        case captureDate, iso, focalLength, aperture
        // Added with per-line joins; old rules never name them.
        case title, caption, creator, copyright, folder, exposureTime, aspectRatio, modifiedDate
        case inStack, virtualCopy, kind, moduleUsed
        /// From the EXIF extras (ExifExtras): compensation in stops,
        /// whether the flash fired, whether the file holds a position.
        case exposureBias, flashFired, hasGPS
        /// What Library › Verify Files last found (FileIntegrity.State):
        /// damaged, ok, or unchecked since the file last changed.
        case fileIntegrity

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
            case .title: "Title"
            case .caption: "Caption"
            case .creator: "Creator"
            case .copyright: "Copyright"
            case .folder: "Folder"
            case .exposureTime: "Exposure time"
            case .aspectRatio: "Aspect ratio"
            case .modifiedDate: "Edit date"
            case .inStack: "In a stack"
            case .virtualCopy: "Virtual copy"
            case .kind: "Kind"
            case .moduleUsed: "Edit changes"
            case .exposureBias: "Exposure bias"
            case .flashFired: "Flash fired"
            case .hasGPS: "Has GPS position"
            case .fileIntegrity: "File integrity"
            }
        }

        /// The comparisons that make sense for the field, the first the default.
        public var operators: [Operator] {
            switch self {
            case .rating, .iso, .focalLength, .aperture, .exposureTime, .exposureBias: [.atLeast, .atMost, .is, .isNot, .between]
            case .flag, .edited, .inStack, .virtualCopy, .kind, .moduleUsed, .flashFired, .hasGPS, .fileIntegrity:
                [.is, .isNot]
            case .label: [.is, .isNot]
            case .keyword: [.is, .isNot, .contains, .doesNotContain, .hasAnyKeyword, .hasNoKeywords]
            case .camera, .lens, .fileName, .finderTag, .title, .caption, .creator, .copyright:
                [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith]
            case .folder: [.startsWith, .is, .isNot, .contains, .doesNotContain, .endsWith]
            case .fileType: [.is, .isNot, .isRaw, .isNotRaw]
            case .captureDate, .modifiedDate: [.inLastDays, .is, .before, .after, .between]
            case .aspectRatio: [.is, .isNot, .atLeast, .atMost, .between]
            }
        }

        public enum ValueKind: Sendable { case number, text, flag, yesNo, date, days, shape, kind, module, integrity }

        public var valueKind: ValueKind {
            switch self {
            case .rating, .iso, .focalLength, .aperture, .exposureTime, .exposureBias: .number
            case .flag: .flag
            case .edited, .inStack, .virtualCopy, .flashFired, .hasGPS: .yesNo
            case .label, .keyword, .camera, .lens, .fileName, .fileType, .finderTag,
                 .title, .caption, .creator, .copyright, .folder: .text
            case .captureDate, .modifiedDate: .date
            case .aspectRatio: .shape
            case .kind: .kind
            case .moduleUsed: .module
            case .fileIntegrity: .integrity
            }
        }

        /// Text fields whose values the sheet offers from the folder's own
        /// photos, so a value can be picked rather than typed.
        public var offersExistingValues: Bool {
            switch self {
            case .camera, .lens, .keyword, .fileType, .finderTag, .title, .caption, .creator, .copyright, .folder: true
            default: false
            }
        }

        /// A value to start a new line with, so it means something at once.
        public var defaultValue: String {
            switch self {
            case .rating: "3"
            case .flag: "1"
            case .edited, .inStack, .virtualCopy: "true"
            case .iso: "1600"
            case .focalLength: "50"
            case .aperture: "2.8"
            case .captureDate, .modifiedDate: "30"
            case .exposureTime: "1/60"
            case .aspectRatio: Shape.landscape.rawValue
            case .kind: Kind.virtualCopy.rawValue
            case .moduleUsed: "tone"
            case .exposureBias: "0"
            case .flashFired, .hasGPS: "true"
            case .fileIntegrity: FileIntegrity.State.damaged.rawValue
            default: ""
            }
        }

        func dependsOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
            switch self {
            case .rating: old.rating != new.rating
            case .flag: old.flag != new.flag
            case .label: old.label != new.label
            case .finderTag: old.finderTags != new.finderTags
            case .fileName, .fileType, .folder, .virtualCopy, .kind: old.relPath != new.relPath
            case .captureDate: old.captureTime != new.captureTime
            case .camera: old.camera != new.camera
            case .lens: old.lens != new.lens
            case .iso: old.iso != new.iso
            case .focalLength: old.focal != new.focal
            case .aperture: old.aperture != new.aperture
            case .title: old.title != new.title
            case .caption: old.caption != new.caption
            case .creator: old.creator != new.creator
            case .copyright: old.copyright != new.copyright
            case .exposureTime: old.shutter != new.shutter
            case .aspectRatio:
                old.width != new.width || old.height != new.height || old.orientation != new.orientation
                    || old.userRotation != new.userRotation
            case .exposureBias: old.exposureBias != new.exposureBias
            case .flashFired: old.flashFired != new.flashFired
            case .hasGPS: old.hasGPS != new.hasGPS
            // A changed file voids its last check.
            case .fileIntegrity: old.size != new.size || old.mtime != new.mtime
            case .edited, .keyword, .modifiedDate, .inStack, .moduleUsed: false
            }
        }
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case `is`, isNot, contains, doesNotContain, startsWith, endsWith, atLeast, atMost
        case inLastDays, before, after
        case between, hasNoKeywords, hasAnyKeyword, isRaw, isNotRaw

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
            case .between: "is between"
            case .hasNoKeywords: "is empty"
            case .hasAnyKeyword: "is not empty"
            case .isRaw: "is raw"
            case .isNotRaw: "is not raw"
            }
        }

        /// What the date field's value means under this operator.
        public var takesDays: Bool { self == .inLastDays }
        /// Whether the line has a value at all.
        public var takesValue: Bool { ![.hasNoKeywords, .hasAnyKeyword, .isRaw, .isNotRaw].contains(self) }
        /// Whether the line has a second value (the end of the range).
        public var takesSecondValue: Bool { self == .between }
    }

    /// How a line joins the lines above it, as in darktable's collections
    /// module: and, or, and not (except).
    public enum Join: String, Codable, CaseIterable, Sendable {
        case and, or, except

        public var title: String {
            switch self {
            case .and: "and"
            case .or: "or"
            case .except: "except"
            }
        }
    }

    /// The Aspect ratio field's named values.
    public enum Shape: String, CaseIterable, Sendable {
        case landscape, portrait, square

        public var title: String { rawValue.capitalized }
    }

    /// The Kind field's values.
    public enum Kind: String, CaseIterable, Sendable {
        case master, virtualCopy, hasVirtualCopies

        public var title: String {
            switch self {
            case .master: "Master"
            case .virtualCopy: "Virtual copy"
            case .hasVirtualCopies: "Has virtual copies"
            }
        }
    }

    public var field: Field
    public var op: Operator
    public var value: String
    /// The end of the range for "is between"; absent otherwise, so lines
    /// saved before it existed encode exactly as they did.
    public var value2: String?
    /// How this line joins those above it; nil takes the rules' all/any.
    /// Never read on the first line.
    public var join: Join?

    public init(_ field: Field, _ op: Operator, _ value: String, value2: String? = nil, join: Join? = nil) {
        self.field = field
        self.op = op
        self.value = value
        self.value2 = value2
        self.join = join
    }

    /// A new line for `field` with its first operator and default value.
    public init(field: Field) {
        self.init(field, field.operators[0], field.defaultValue)
    }

    enum CodingKeys: String, CodingKey { case field, op, value, value2, join }

    public func matches(_ record: ImageRecord, isEdited: Bool, keywords: Set<String>, now: Date = Date()) -> Bool {
        matches(record, context: SmartMatchContext(isEdited: isEdited, keywords: keywords, now: now))
    }

    public func matches(_ record: ImageRecord, context: SmartMatchContext) -> Bool {
        let isEdited = context.isEdited, keywords = context.keywords, now = context.now
        switch field {
        case .rating: return compare(Double(record.rating))
        case .iso: return compare(record.iso.map(Double.init))
        case .focalLength: return compare(record.focal)
        case .aperture: return compare(record.aperture)
        case .exposureTime: return compare(record.shutter, parse: Self.exposureNumber)
        case .exposureBias: return compare(record.exposureBias)
        case .flashFired:
            // Unknown counts as not fired.
            let hit = (record.flashFired ?? false) == (value != "false")
            return op == .isNot ? !hit : hit
        case .hasGPS:
            let hit = record.hasGPS == (value != "false")
            return op == .isNot ? !hit : hit
        case .flag:
            let wanted = Set(value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            let hit = wanted.contains(record.flag)
            return op == .isNot ? !hit : hit
        case .edited:
            return yesNo(isEdited)
        case .inStack:
            return yesNo(context.isInStack)
        case .virtualCopy:
            return yesNo(record.isVirtualCopy)
        case .label:
            let wanted = value.trimmingCharacters(in: .whitespaces)
            let label = record.label ?? ""
            let hit = label.compare(wanted, options: [.caseInsensitive]) == .orderedSame
            return op == .isNot ? !hit : hit
        case .keyword:
            let wanted = KeywordPath.normalized(value) ?? ""
            switch op {
            case .hasNoKeywords: return keywords.isEmpty
            case .hasAnyKeyword: return !keywords.isEmpty
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
        case .title: return compareText(record.title)
        case .caption: return compareText(record.caption)
        case .creator: return compareText(record.creator)
        case .copyright: return compareText(record.copyright)
        case .folder: return compareText(Self.folder(of: record))
        case .fileType:
            if op == .isRaw || op == .isNotRaw {
                let raw = Self.isRaw(record)
                return op == .isRaw ? raw : !raw
            }
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
        case .modifiedDate:
            return compareDate(context.editedAt.map { $0 / 1000 }, now: now)
        case .aspectRatio:
            return compareAspect(LibrarySortKey.aspectRatio(of: record))
        case .kind:
            let hit: Bool
            switch Kind(rawValue: value) {
            case .master: hit = !record.isVirtualCopy
            case .virtualCopy: hit = record.isVirtualCopy
            case .hasVirtualCopies: hit = context.hasVirtualCopies
            case nil: return false
            }
            return op == .isNot ? !hit : hit
        case .moduleUsed:
            let wanted = value.trimmingCharacters(in: .whitespaces)
            guard !wanted.isEmpty else { return false }
            let hit = context.editGroups.contains(wanted)
            return op == .isNot ? !hit : hit
        case .fileIntegrity:
            guard let wanted = FileIntegrity.State(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased())
            else { return false }
            let hit = context.integrity == wanted
            return op == .isNot ? !hit : hit
        }
    }

    /// The distinct values `field` takes among `images` (and their
    /// keywords), sorted as Finder sorts names; empty for a field that
    /// doesn't offer them. What `SELECT DISTINCT` over the catalog gives,
    /// worked out from the rows the Library already holds.
    public static func existingValues(for field: Field, in images: [ImageRecord],
                                      keywords: [Int64: Set<String>] = [:]) -> [String] {
        var values = Set<String>()
        switch field {
        case .camera: values = Set(images.compactMap(\.camera))
        case .lens: values = Set(images.compactMap(\.lens))
        case .title: values = Set(images.compactMap(\.title))
        case .caption: values = Set(images.compactMap(\.caption))
        case .creator: values = Set(images.compactMap(\.creator))
        case .copyright: values = Set(images.compactMap(\.copyright))
        case .folder: values = Set(images.map(folder(of:)))
        case .fileType:
            values = Set(images.map { ($0.fileRelPath as NSString).pathExtension.uppercased() })
        case .finderTag:
            for record in images where record.finderTags != nil { values.formUnion(record.tags.map(\.name)) }
        case .keyword:
            for paths in keywords.values { values.formUnion(paths) }
        default:
            return []
        }
        return Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The folder a photo is in, relative to the catalog ("" at the top).
    public static func folder(of record: ImageRecord) -> String {
        (record.fileRelPath as NSString).deletingLastPathComponent
    }

    /// A camera raw (DNG included), as the File Type sort groups files.
    public static func isRaw(_ record: ImageRecord) -> Bool {
        let type = LibrarySortKey.fileType(of: record)
        return type == "Raw" || type == "DNG"
    }

    private func yesNo(_ fact: Bool) -> Bool {
        let hit = fact == (value != "false")
        return op == .isNot ? !hit : hit
    }

    /// A number as typed: "2.8", or "2,8" with a decimal comma.
    static func plainNumber(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// An exposure time as typed: seconds ("2", "0.5", "2s") or a fraction ("1/250").
    static func exposureNumber(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("s") || trimmed.hasSuffix("\"") { trimmed.removeLast() }
        let parts = trimmed.split(separator: "/")
        if parts.count == 2, let n = plainNumber(String(parts[0])), let d = plainNumber(String(parts[1])), d > 0 {
            return n / d
        }
        return plainNumber(trimmed)
    }

    /// An aspect ratio as typed: "1.5", "3:2" or "16/9".
    static func aspectNumber(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "x" })
        if parts.count == 2, let w = plainNumber(String(parts[0])), let h = plainNumber(String(parts[1])), h > 0 {
            return w / h
        }
        return plainNumber(text)
    }

    private func compare(_ number: Double?, parse: (String) -> Double? = SmartCriterion.plainNumber,
                         tolerance: Double = 1e-6) -> Bool {
        if op == .between {
            guard let a = parse(value), let b = parse(value2 ?? ""), let number else { return false }
            return number >= min(a, b) - 1e-9 && number <= max(a, b) + 1e-9
        }
        guard let wanted = parse(value) else {
            return false
        }
        guard let number else { return op == .isNot }
        switch op {
        case .atLeast: return number >= wanted - 1e-9
        case .atMost: return number <= wanted + 1e-9
        case .is: return abs(number - wanted) < tolerance
        case .isNot: return abs(number - wanted) >= tolerance
        default: return false
        }
    }

    /// Landscape, portrait and square by name (within 1% of square counts
    /// as square), or a width-over-height number.
    private func compareAspect(_ ratio: Double?) -> Bool {
        if (op == .is || op == .isNot), let shape = Shape(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased()) {
            guard let ratio else { return op == .isNot }
            let hit: Bool
            switch shape {
            case .square: hit = abs(ratio - 1) <= 0.01
            case .landscape: hit = ratio > 1.01
            case .portrait: hit = ratio < 0.99
            }
            return op == .isNot ? !hit : hit
        }
        return compare(ratio, parse: Self.aspectNumber, tolerance: 0.005)
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

    /// Capture times are seconds since 1970 in the camera's own clock (edit
    /// dates, seconds since 1970 too); days are counted in the Mac's calendar.
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
        if op == .between {
            // Both days included, whichever way round they were entered.
            guard let first = Self.parseDay(value), let second = Self.parseDay(value2 ?? ""),
                  let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(first, second)))
            else { return false }
            return date >= calendar.startOfDay(for: min(first, second)) && date < end
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
