import Foundation

/// File naming for exports: a template with tokens, expanded per image.
///
/// Tokens (case-insensitive):
///   {name}     original file name without extension
///   {seq}      position in the batch, from `start`, zero-padded to `padding`
///   {date}     capture date, yyyy-MM-dd (file date if unknown)
///   {time}     capture time, HHmmss
///   {camera}   camera model with spaces removed
///   {rating}   stars as a digit
///   {folder}   the image's subfolder inside the catalog, or the catalog name
///
/// The result is made safe for a file name: path separators and control
/// characters become underscores, and an empty result falls back to the
/// original name so a bad template can never produce a nameless file.
public enum ExportNaming {
    public static let defaultTemplate = "{name}"
    public static let tokens: [(token: String, meaning: String)] = [
        ("{name}", "original name"), ("{seq}", "sequence number"), ("{date}", "capture date"),
        ("{time}", "capture time"), ("{camera}", "camera"), ("{rating}", "stars"), ("{folder}", "subfolder"),
    ]

    public struct Context: Sendable {
        public var index: Int          // 0-based position in the batch
        public var start: Int
        public var padding: Int
        public var catalogName: String
        public init(index: Int, start: Int = 1, padding: Int = 3, catalogName: String = "") {
            self.index = index; self.start = start; self.padding = padding; self.catalogName = catalogName
        }
    }

    public static func fileName(template: String, record: ImageRecord, context: Context,
                                timeZone: TimeZone = .current) -> String {
        let base = (record.fileName as NSString).deletingPathExtension
        let date = Date(timeIntervalSince1970: TimeInterval(record.captureTime ?? record.mtime / 1000))
        let df = DateFormatter(); df.timeZone = timeZone
        func fmt(_ f: String) -> String { df.dateFormat = f; return df.string(from: date) }
        let seq = String(format: "%0\(max(1, context.padding))d", context.start + context.index)
        let folder = (record.relPath as NSString).deletingLastPathComponent
        let values: [String: String] = [
            "name": base,
            "seq": seq,
            "date": fmt("yyyy-MM-dd"),
            "time": fmt("HHmmss"),
            "camera": (record.camera ?? "").replacingOccurrences(of: " ", with: ""),
            "rating": String(record.rating),
            "folder": folder.isEmpty ? context.catalogName : folder.replacingOccurrences(of: "/", with: "_"),
        ]
        var out = template.isEmpty ? defaultTemplate : template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{\(key)}", with: value, options: .caseInsensitive)
        }
        let cleaned = sanitized(out)
        return cleaned.isEmpty ? sanitized(base) : cleaned
    }

    /// Strips what a file name can't hold.
    public static func sanitized(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var out = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
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

    /// The URL to write, given what's already in the folder. `.addNumber`
    /// appends -1, -2, … before the extension until the name is free;
    /// `.skip` returns nil when the file exists; `.replace` returns it as is.
    public static func resolve(_ url: URL, collision: Collision,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        guard exists(url) else { return url }
        switch collision {
        case .replace: return url
        case .skip: return nil
        case .addNumber:
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            let dir = url.deletingLastPathComponent()
            for n in 1...9999 {
                let candidate = dir.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(ext)
                if !exists(candidate) { return candidate }
            }
            return nil
        }
    }
}
