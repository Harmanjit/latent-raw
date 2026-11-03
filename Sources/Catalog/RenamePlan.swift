import Foundation

/// Rename with a filename template: one photo or a whole selection named
/// from tokens, as Lightroom's Rename Photos and its Filename Template
/// Editor do.
///
/// The template language is the export's (`ExportNaming`), so a template
/// that names exported files names renamed ones the same way, plus two
/// tokens that only make sense here: `{text}`, the custom text typed beside
/// the template, and `{title}`, the photo's title. The extension is always
/// the file's own (`FileOperations.renamedFileName`), so a raw stays a raw.
///
/// The plan is worked out before anything moves, so the sheet can show
/// every new name and every problem first: two photos given one name, a
/// name another file already has, a name nothing could be called. Photos
/// whose names don't change are left alone. A photo may take the name
/// another photo in the batch is giving up (renaming 2→3 while 3→4), so
/// the renames run in an order that frees each name before it is taken; a
/// ring of them (two photos swapping names) can't be ordered and is
/// refused.
public enum RenameTemplate {
    public static let textToken = "{text}"
    public static let titleToken = "{title}"
    /// The usual Lightroom choice: custom text and a sequence number.
    public static let defaultTemplate = "{text}-{seq}"

    public static let tokens: [(token: String, meaning: String)] = [
        ("{name}", "original name"), ("{text}", "custom text"), ("{seq}", "sequence number"),
        ("{date}", "capture date"), ("{date:yyyyMMdd}", "capture date, own format"),
        ("{time}", "capture time"), ("{title}", "title"), ("{camera}", "camera"),
        ("{rating}", "stars"), ("{folder}", "subfolder"),
    ]

    /// Private-use characters standing in for the two tokens while the
    /// export's namer works: it leaves them alone, and nothing typed into a
    /// template contains them.
    static let textMark = "\u{E000}"
    static let titleMark = "\u{E001}"

    /// The template with `{text}` and `{title}` (any letter case) swapped
    /// for their marks.
    static func marked(_ template: String) -> String {
        var out = template
        for (token, mark) in [(textToken, textMark), (titleToken, titleMark)] {
            while let range = out.range(of: token, options: .caseInsensitive) {
                out.replaceSubrange(range, with: mark)
            }
        }
        return out
    }

    /// Tokens the template doesn't know, as typed ("{nmae}").
    public static func unknownTokens(in template: String) -> [String] {
        ExportNaming.unknownTokens(in: marked(template))
    }

    /// The new file name for `record`, extension kept, or the reason there
    /// can't be one.
    public static func fileName(template: String, customText: String, record: ImageRecord,
                                context: ExportNaming.Context,
                                timeZone: TimeZone = .current) -> Result<String, FileOperations.NameProblem> {
        fileName(namer: ExportNaming.Namer(template: marked(template), timeZone: timeZone),
                 customText: customText, record: record, context: context)
    }

    static func fileName(namer: ExportNaming.Namer, customText: String, record: ImageRecord,
                         context: ExportNaming.Context) -> Result<String, FileOperations.NameProblem> {
        var stem = namer.stem(for: record, context: context)
        let posix = Locale(identifier: "en_US_POSIX")
        func cased(_ text: String) -> String {
            switch context.letterCase {
            case .unchanged: text
            case .lower: text.lowercased(with: posix)
            case .upper: text.uppercased(with: posix)
            }
        }
        // The namer's own fallback (the original name, for a template that
        // came out empty) never holds a mark, so these only fill tokens.
        stem = stem.replacingOccurrences(of: textMark, with: cased(ExportNaming.sanitized(customText)))
        stem = stem.replacingOccurrences(of: titleMark, with: cased(ExportNaming.sanitized(record.title ?? "")))
        stem = ExportNaming.sanitized(stem)
        if stem.isEmpty { stem = (record.fileName as NSString).deletingPathExtension }
        return FileOperations.renamedFileName(base: stem, original: record.fileName)
    }
}

/// Every photo of a rename, its new name and what stands in its way.
public struct RenamePlan: Sendable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var record: ImageRecord
        /// The new file name, or the old one when there is a problem.
        public var newName: String
        /// Why this photo can't be renamed; nil when it can.
        public var problem: String?
        public var id: String { record.relPath }

        /// Renaming leaves the name as it is: nothing to do.
        public var isUnchanged: Bool { problem == nil && newName == record.fileName }
        public var willRename: Bool { problem == nil && !isUnchanged }

        public var newRelPath: String {
            let folder = (record.relPath as NSString).deletingLastPathComponent
            return folder.isEmpty ? newName : folder + "/" + newName
        }
    }

    /// In the order the photos were given (the grid's), for the sheet.
    public var items: [Item]
    /// Indexes into `items` of the photos to rename, in the order to rename
    /// them, so each name is free by the time it is taken.
    public var order: [Int]

    public var renameCount: Int { order.count }
    public var problemCount: Int { items.filter { $0.problem != nil }.count }

    /// The photos to rename, in order.
    public var renames: [Item] { order.map { items[$0] } }

    /// Plans renaming `records`, in this order for the sequence numbers.
    /// `isTaken` says whether a relative path is already held by a file or
    /// a catalogued photo; the photos being renamed are allowed for.
    public static func make(_ records: [ImageRecord], template: String, customText: String,
                            start: Int = 1, padding: Int = 3, catalogName: String = "",
                            letterCase: ExportNaming.LetterCase = .unchanged,
                            timeZone: TimeZone = .current,
                            isTaken: (String) -> Bool) -> RenamePlan {
        let namer = ExportNaming.Namer(template: RenameTemplate.marked(template), timeZone: timeZone)
        var items: [Item] = records.enumerated().map { index, record in
            let context = ExportNaming.Context(index: index, start: start, padding: padding,
                                               catalogName: catalogName, letterCase: letterCase)
            switch RenameTemplate.fileName(namer: namer, customText: customText, record: record, context: context) {
            case .success(let name): return Item(record: record, newName: name, problem: nil)
            case .failure(let problem): return Item(record: record, newName: record.fileName, problem: problem.description)
            }
        }
        // Names compare as the disk does: APFS and HFS+ volumes are
        // normally case-insensitive, so "a.NEF" and "A.NEF" are one name.
        func key(_ relPath: String) -> String { relPath.lowercased() }

        // Two photos given one name.
        var claimed: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where item.willRename || item.isUnchanged {
            claimed[key(item.newRelPath), default: []].append(index)
        }
        for (_, indexes) in claimed where indexes.count > 1 {
            for index in indexes where items[index].willRename {
                items[index].problem = "another photo would get the same name; add {seq} to the template"
                items[index].newName = items[index].record.fileName
            }
        }

        // A name held by something else. One held by a photo of the batch
        // that is giving it up is free once that photo has moved on.
        let current = Dictionary(items.enumerated().map { (key($0.element.record.relPath), $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
        var waitsFor: [Int: Int] = [:]
        for (index, item) in items.enumerated() where item.willRename {
            let wanted = key(item.newRelPath)
            if wanted == key(item.record.relPath) { continue }   // its own name, in another case
            if let holder = current[wanted] {
                waitsFor[index] = holder
            } else if isTaken(item.newRelPath) {
                items[index].problem = "“\(item.newName)” is already taken"
                items[index].newName = item.record.fileName
            }
        }

        // A photo waiting for one that isn't leaving its name (unchanged,
        // or stopped by a problem) can't go either, and so on down the
        // line; a ring of photos waiting on each other can't start.
        var changed = true
        while changed {
            changed = false
            for (index, holder) in waitsFor where items[index].willRename && !items[holder].willRename {
                items[index].problem = "“\(items[index].newName)” is already taken"
                items[index].newName = items[index].record.fileName
                changed = true
            }
        }
        var order: [Int] = []
        var placed = Set<Int>()
        func place(_ index: Int, _ path: Set<Int>) -> Bool {
            if placed.contains(index) { return true }
            if path.contains(index) { return false }
            if let holder = waitsFor[index], items[holder].willRename, !place(holder, path.union([index])) {
                return false
            }
            placed.insert(index)
            order.append(index)
            return true
        }
        for index in items.indices where items[index].willRename {
            if !place(index, []) {
                items[index].problem = "would swap names with another photo; rename one of them first"
                items[index].newName = items[index].record.fileName
            }
        }
        // A photo refused for a ring may have been waited on by one placed
        // already; take those out again until nothing changes.
        changed = true
        while changed {
            changed = false
            for index in order where items[index].willRename {
                if let holder = waitsFor[index], !items[holder].willRename {
                    items[index].problem = "“\(items[index].newName)” is already taken"
                    items[index].newName = items[index].record.fileName
                    changed = true
                }
            }
        }
        order.removeAll { !items[$0].willRename }
        return RenamePlan(items: items, order: order)
    }
}
