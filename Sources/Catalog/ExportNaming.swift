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
    ]

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
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let keyword = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        // A format is only for dates, and an empty one ("{date:}") is a typo.
        guard parts.count == 1 || (keyword == "date" || keyword == "time") && !parts[1].isEmpty else { return nil }
        let format = parts.count > 1 ? String(parts[1]) : nil
        switch keyword {
        case "name": return .name
        case "seq": return .seq
        case "date": return .date(format: format ?? "yyyy-MM-dd")
        case "time": return .time(format: format ?? "HHmmss")
        case "camera": return .camera
        case "rating": return .rating
        case "folder": return .folder
        default: return nil
        }
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

        /// The file name without its extension.
        public func stem(for record: ImageRecord, context: Context) -> String {
            let base = (record.fileName as NSString).deletingPathExtension
            let date = ExportNaming.captureDate(of: record)
            var out = ""
            for token in tokens {
                switch token {
                case .literal(let text): out += text
                case .name: out += base
                case .seq: out += Self.sequence(context)
                case .date(let format), .time(let format): out += formatted(date, format)
                case .camera: out += (record.camera ?? "").replacingOccurrences(of: " ", with: "")
                case .rating: out += String(record.rating)
                case .folder:
                    let folder = (record.relPath as NSString).deletingLastPathComponent
                    out += folder.isEmpty ? context.catalogName : folder.replacingOccurrences(of: "/", with: "_")
                }
            }
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
        public var title: String {
            switch self {
            case .addNumber: "Add a number"
            case .replace: "Replace"
            case .skip: "Skip"
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
