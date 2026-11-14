import Foundation

/// File naming for exports: a template with tokens, expanded per image.
///
/// Tokens (the keyword in any letter case):
///   {name}          original file name without extension
///   {seq}           position in the batch: `start`, then `step` more per image,
///                   zero-padded to `padding`
///   {date}          capture date, yyyy-MM-dd (file date if unknown)
///   {date:yyyyMMdd} capture date in a format of your own (a Unicode date pattern)
///   {time}          capture time, HHmmss; {time:HH.mm} takes a format too
///   {camera}        camera model with spaces removed
///   {rating}        stars as a digit
///   {folder}        the image's subfolder inside the catalog, or the catalog name
///   {lens} {maker} {model} {iso} {shutter} {aperture} {focal} {bias}
///   {width} {height} {label} {stars} {title} {caption} {creator}
///   {copyright} {headline} {city} {country} {keywords} {ext} {version}
///   {original}      see `Field`
///
/// Modifiers (not for a date or time given its own format, whose colon is
/// the format's):
///   {token|text}    `text` when the token comes out empty
///   {token:upper}, {token:lower}, {token:title}   letter case
///   {token:1-8}     characters 1 to 8
///   {token/old/new} every `old` replaced by `new`
/// They combine in that written order, {title:upper/ /_|untitled}: the
/// replacement first, then the characters, then the case, then the fallback.
///
/// Dates are formatted in en_US_POSIX with the Gregorian calendar, so a
/// template names files the same on every Mac whatever the user's region
/// (a Buddhist-calendar year or Arabic-Indic digits would otherwise turn up
/// in file names). A token the template doesn't know ("{nmae}") stays in the
/// name as typed and is reported by `unknownTokens(in:)`, so the sheet can
/// show it and refuse to export rather than write names nobody asked for.
///
/// The result is made safe for a file name: path separators and control
/// characters become underscores, the length is capped, and an empty result
/// falls back to the original name so a bad template can never produce a
/// nameless file.
public enum ExportNaming {
    public static let defaultTemplate = "{name}"
    public static let tokens: [(token: String, meaning: String)] = [
        ("{name}", "original name"), ("{seq}", "sequence number"), ("{date}", "capture date"),
        ("{date:yyyyMMdd}", "capture date, own format"), ("{time}", "capture time"),
        ("{camera}", "camera"), ("{rating}", "stars"), ("{folder}", "subfolder"),
    ] + fieldTokens

    /// The tokens that read one value of the photo (`Field`), for the
    /// Insert menus here, in Rename with Template and the watermark.
    public static let fieldTokens: [(token: String, meaning: String)] = Field.allCases.map {
        ("{\($0.rawValue)}", $0.meaning)
    }

    /// One value of the photo, by its token's keyword.
    public enum Field: String, CaseIterable, Sendable {
        case lens, maker, model, iso, shutter, aperture, focal, bias, width, height
        case label, stars, title, caption, creator, copyright, headline, city, country
        case keywords, ext, version, original

        public var meaning: String {
            switch self {
            case .lens: "lens"
            case .maker: "camera maker"
            case .model: "camera model"
            case .iso: "ISO"
            case .shutter: "shutter speed"
            case .aperture: "aperture"
            case .focal: "focal length"
            case .bias: "exposure bias"
            case .width: "width"
            case .height: "height"
            case .label: "colour label"
            case .stars: "stars as ★"
            case .title: "title"
            case .caption: "caption"
            case .creator: "creator"
            case .copyright: "copyright"
            case .headline: "headline"
            case .city: "city"
            case .country: "country"
            case .keywords: "keywords"
            case .ext: "original extension"
            case .version: "virtual copy number"
            case .original: "original file name"
            }
        }

        /// The value for `record`, as text; empty when the photo has none.
        /// Numbers are written the way file names can hold them: 1/250 s
        /// is "1-250", ƒ/2.8 is "f2.8", 50 mm is "50mm", +0.7 EV is "+0.7".
        public func value(of record: ImageRecord, keywords: [String]) -> String {
            switch self {
            case .lens: return record.lens ?? ""
            case .maker:
                return (record.camera ?? "").split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            case .model:
                let parts = (record.camera ?? "").split(separator: " ", maxSplits: 1)
                return parts.count > 1 ? String(parts[1]) : ""
            case .iso: return record.iso.map { $0 > 0 ? String($0) : "" } ?? ""
            case .shutter:
                guard let s = record.shutter, s > 0 else { return "" }
                return s < 1 ? "1-\(Int((1 / s).rounded()))" : Self.number(s) + "s"
            case .aperture:
                guard let f = record.aperture, f > 0 else { return "" }
                return "f" + Self.number(f)
            case .focal:
                guard let mm = record.focal, mm > 0 else { return "" }
                return Self.number(mm) + "mm"
            case .bias:
                guard let ev = record.exposureBias else { return "" }
                let text = Self.number(abs(ev))
                return text == "0" ? "0" : (ev < 0 ? "-" : "+") + text
            case .width: return record.width.map(String.init) ?? ""
            case .height: return record.height.map(String.init) ?? ""
            case .label: return record.label ?? ""
            case .stars: return String(repeating: "★", count: min(max(record.rating, 0), 5))
            case .title: return record.title ?? ""
            case .caption: return record.caption ?? ""
            case .creator: return record.creator ?? ""
            case .copyright: return record.copyright ?? ""
            case .headline: return record.headline ?? ""
            case .city: return record.city ?? ""
            case .country: return record.country ?? ""
            case .keywords:
                // The last level of each, "Places|France|Paris" as "Paris".
                var seen = Set<String>()
                return keywords.map { KeywordPath.components($0).last ?? $0 }
                    .filter { seen.insert($0).inserted }.sorted().joined(separator: "_")
            case .ext: return (record.fileRelPath as NSString).pathExtension
            case .version: return String(VirtualCopy.parse(record.relPath)?.key.number ?? 0)
            case .original:
                let name = record.preservedName ?? (record.fileRelPath as NSString).lastPathComponent
                return (name as NSString).deletingPathExtension
            }
        }

        /// One decimal at most, none when it is zero, in POSIX digits.
        static func number(_ value: Double) -> String {
            let tenths = (value * 10).rounded() / 10
            return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tenths)
        }
    }

    /// File names hold at most 255 bytes of UTF-8. The stem stops short of
    /// that so a collision number ("-12") and the extension still fit.
    public static let maxStemBytes = 240

    public enum LetterCase: String, CaseIterable, Codable, Sendable {
        case unchanged, lower, upper
        public var title: String {
            switch self {
            case .unchanged: "Unchanged"
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            }
        }
    }

    public struct Context: Sendable {
        public var index: Int          // 0-based position in the batch
        public var start: Int
        public var padding: Int
        public var catalogName: String
        public var step: Int
        public var letterCase: LetterCase
        /// The photo's keywords, for {keywords}; empty when the caller
        /// didn't look them up.
        public var keywords: [String] = []
        public init(index: Int, start: Int = 1, padding: Int = 3, catalogName: String = "",
                    step: Int = 1, letterCase: LetterCase = .unchanged) {
            self.index = index; self.start = start; self.padding = padding; self.catalogName = catalogName
            self.step = step; self.letterCase = letterCase
        }
    }

    public static func fileName(template: String, record: ImageRecord, context: Context,
                                timeZone: TimeZone = .current) -> String {
        Namer(template: template, timeZone: timeZone).stem(for: record, context: context)
    }

    /// `template` filled in for `record` as text, not a file name: what a
    /// watermark or the image caption shows. An empty template stays empty.
    public static func text(template: String, record: ImageRecord, context: Context,
                            timeZone: TimeZone = .current) -> String {
        guard !template.isEmpty else { return "" }
        return Namer(template: template, timeZone: timeZone).text(for: record, context: context)
    }

    /// Tokens in `template` that aren't tokens, as typed ("{nmae}").
    public static func unknownTokens(in template: String) -> [String] {
        parse(template).unknown
    }

    /// The subfolder for "sort into subfolders by capture date".
    public static func dateFolderName(for record: ImageRecord, timeZone: TimeZone = .current) -> String {
        posixFormatter("yyyy-MM-dd", timeZone: timeZone).string(from: captureDate(of: record))
    }

    static func captureDate(of record: ImageRecord) -> Date {
        Date(timeIntervalSince1970: TimeInterval(record.captureTime ?? record.mtime / 1000))
    }

    static func posixFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = timeZone
        df.dateFormat = format
        return df
    }

    // MARK: - Template parsing

    enum Token: Equatable {
        case literal(String)
        case name, seq, camera, rating, folder
        case date(format: String)
        case time(format: String)
        case field(Field)
        /// A token with modifiers (`Modifiers`).
        indirect case modified(Token, Modifiers)
    }

    /// What `{token:upper/old/new|fallback}` asks for beyond the value.
    struct Modifiers: Equatable {
        enum Case: Equatable { case upper, lower, title }
        var letterCase: Case?
        /// 1-based, inclusive.
        var characters: ClosedRange<Int>?
        var replace: String?
        var replacement = ""
        var fallback: String?

        func apply(_ value: String) -> String {
            var out = value
            if let replace { out = out.replacingOccurrences(of: replace, with: replacement) }
            if let characters {
                let chars = Array(out)
                let lower = min(max(characters.lowerBound - 1, 0), chars.count)
                let upper = min(max(characters.upperBound, lower), chars.count)
                out = String(chars[lower..<upper])
            }
            let posix = Locale(identifier: "en_US_POSIX")
            switch letterCase {
            case .upper: out = out.uppercased(with: posix)
            case .lower: out = out.lowercased(with: posix)
            case .title: out = out.capitalized(with: posix)
            case nil: break
            }
            if out.isEmpty, let fallback { out = fallback }
            return out
        }
    }

    /// The template's pieces, and the tokens it doesn't know, which stay in
    /// the name as literal text. A brace without its partner is text.
    static func parse(_ template: String) -> (tokens: [Token], unknown: [String]) {
        var tokens: [Token] = []
        var unknown: [String] = []
        var literal = ""
        var rest = Substring(template)
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)) }
            literal = ""
        }
        while let open = rest.firstIndex(of: "{") {
            literal += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            // "{{name}": the outer brace is text and the token starts at the inner one.
            if let inner = rest[afterOpen..<close].lastIndex(of: "{") {
                literal += rest[open..<inner]
                rest = rest[inner...]
                continue
            }
            let body = rest[afterOpen..<close]
            if let token = token(for: body) {
                flush()
                tokens.append(token)
            } else {
                unknown.append("{\(body)}")
                literal += "{\(body)}"
            }
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        flush()
        return (tokens, unknown)
    }

    private static func token(for body: Substring) -> Token? {
        let stop = body.firstIndex { $0 == ":" || $0 == "|" || $0 == "/" } ?? body.endIndex
        let keyword = body[..<stop].trimmingCharacters(in: .whitespaces).lowercased()
        var rest = body[stop...]
        // A date or time's colon starts its format, all the rest of the
        // braces, as it always has; an empty one ("{date:}") is a typo.
        if keyword == "date" || keyword == "time", rest.first == ":" {
            let format = String(rest.dropFirst())
            guard !format.isEmpty else { return nil }
            return keyword == "date" ? .date(format: format) : .time(format: format)
        }
        let base: Token
        switch keyword {
        case "name": base = .name
        case "seq": base = .seq
        case "date": base = .date(format: "yyyy-MM-dd")
        case "time": base = .time(format: "HHmmss")
        case "camera": base = .camera
        case "rating": base = .rating
        case "folder": base = .folder
        default:
            guard let field = Field(rawValue: keyword) else { return nil }
            base = .field(field)
        }
        guard !rest.isEmpty else { return base }
        var modifiers = Modifiers()
        if let bar = rest.firstIndex(of: "|") {
            modifiers.fallback = String(rest[rest.index(after: bar)...])
            rest = rest[..<bar]
        }
        if rest.first == ":" {
            let end = rest.firstIndex(of: "/") ?? rest.endIndex
            let word = rest[rest.index(after: rest.startIndex)..<end].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[end...]
            switch word {
            case "upper": modifiers.letterCase = .upper
            case "lower": modifiers.letterCase = .lower
            case "title": modifiers.letterCase = .title
            default:
                let bounds = word.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                guard bounds.count == 2, let first = bounds[0], let last = bounds[1], first >= 1, last >= first
                else { return nil }
                modifiers.characters = first...last
            }
        }
        if rest.first == "/" {
            let parts = rest.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            modifiers.replace = String(parts[0])
            modifiers.replacement = String(parts[1])
            rest = rest[rest.endIndex...]
        }
        guard rest.isEmpty else { return nil }
        return .modified(base, modifiers)
    }

    /// Makes names from one template. Parses it and builds its date
    /// formatters once, so naming a few thousand images costs string work
    /// only. Not Sendable (the formatters): make one per job.
    public struct Namer {
        private let tokens: [Token]
        public let unknownTokens: [String]
        private let timeZone: TimeZone
        private let formatters = Formatters()

        /// A class box, so naming (a non-mutating call) can keep a formatter
        /// the first time a format is used.
        private final class Formatters {
            var byFormat: [String: DateFormatter] = [:]
        }

        public init(template: String, timeZone: TimeZone = .current) {
            (tokens, unknownTokens) = ExportNaming.parse(template.isEmpty ? ExportNaming.defaultTemplate : template)
            self.timeZone = timeZone
        }

        /// The template filled in for `record`, as typed: no letter case,
        /// no cleaning for a file name. A watermark's text and the image
        /// caption use this; file names use `stem`.
        public func text(for record: ImageRecord, context: Context) -> String {
            tokens.map { value(of: $0, record: record, context: context) }.joined()
        }

        private func value(of token: Token, record: ImageRecord, context: Context) -> String {
            switch token {
            case .literal(let text): return text
            case .name: return (record.fileName as NSString).deletingPathExtension
            case .seq: return Self.sequence(context)
            case .date(let format), .time(let format): return formatted(ExportNaming.captureDate(of: record), format)
            case .camera: return (record.camera ?? "").replacingOccurrences(of: " ", with: "")
            case .rating: return String(record.rating)
            case .folder:
                let folder = (record.relPath as NSString).deletingLastPathComponent
                return folder.isEmpty ? context.catalogName : folder.replacingOccurrences(of: "/", with: "_")
            case .field(let field): return field.value(of: record, keywords: context.keywords)
            case .modified(let inner, let modifiers):
                return modifiers.apply(value(of: inner, record: record, context: context))
            }
        }

        /// The file name without its extension.
        public func stem(for record: ImageRecord, context: Context) -> String {
            let base = (record.fileName as NSString).deletingPathExtension
            var out = text(for: record, context: context)
            let posix = Locale(identifier: "en_US_POSIX")
            switch context.letterCase {
            case .unchanged: break
            case .lower: out = out.lowercased(with: posix)
            case .upper: out = out.uppercased(with: posix)
            }
            let cleaned = sanitized(out)
            return cleaned.isEmpty ? sanitized(base) : cleaned
        }

        /// `start + index × step`, zero-padded. A negative number keeps its
        /// sign in front of the zeros, and an overflow gives 0 rather than a trap.
        static func sequence(_ context: Context) -> String {
            let (product, overflow1) = context.index.multipliedReportingOverflow(by: context.step)
            let (value, overflow2) = context.start.addingReportingOverflow(product)
            let number = overflow1 || overflow2 ? 0 : value
            let digits = min(max(context.padding, 1), 20)
            let magnitude = String(number.magnitude)
            let padded = String(repeating: "0", count: max(0, digits - magnitude.count)) + magnitude
            return number < 0 ? "-" + padded : padded
        }

        private func formatted(_ date: Date, _ format: String) -> String {
            if let formatter = formatters.byFormat[format] { return formatter.string(from: date) }
            let formatter = ExportNaming.posixFormatter(format, timeZone: timeZone)
            formatters.byFormat[format] = formatter
            return formatter.string(from: date)
        }
    }

    /// Strips what a file name can't hold, and shortens it to `maxBytes` of
    /// UTF-8 by whole characters.
    public static func sanitized(_ s: String, maxBytes: Int = maxStemBytes) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var out = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.utf8.count > maxBytes {
            while out.utf8.count > maxBytes { out.removeLast() }
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public enum Collision: String, CaseIterable, Codable, Sendable {
        case addNumber, replace, skip
        /// Replace an existing file only when the photo's edit (its
        /// sidecar) or the photo itself changed after the file was
        /// written; skip it otherwise (ExportBatchPlanner).
        case replaceIfChanged
        public var title: String {
            switch self {
            case .addNumber: "Add a number"
            case .replace: "Replace"
            case .skip: "Skip"
            case .replaceIfChanged: "Overwrite if edit changed"
            }
        }
    }

    /// "photo.jpg" numbered `n`: "photo-1.jpg", "photo-2.jpg"…
    public static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
    }
}
