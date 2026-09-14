import Foundation

/// Where every file of an export goes and what happens there, decided for
/// the whole batch before anything is written, so the sheet's preview and
/// warnings and the queue that writes the files agree.
public struct ExportBatchPlan: Sendable {
    public enum Action: Hashable, Sendable {
        /// A new file.
        case write
        /// A file of that name is already there and the policy is Replace.
        case replace
        /// Nothing is written: the name is taken and the policy is Skip.
        case skip
        /// Nothing can be written, for `reason`.
        case fail(reason: String)
    }

    public struct Output: Hashable, Sendable {
        /// Index into the planned records.
        public var index: Int
        public var url: URL
        public var action: Action
        /// The name the template gave, before any number was added.
        public var templateName: String
        /// Numbered because an earlier image of this export has the same name.
        public var sharesName: Bool
        /// The name (after any numbering within the batch) was already taken
        /// in the destination when planned.
        public var existed: Bool

        /// The path below the destination folder, for showing.
        public func relativePath(to destination: URL) -> String {
            let root = destination.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
            return String(path.dropFirst(root.count + 1))
        }
    }

    public internal(set) var outputs: [Output]
    public let destination: URL
    /// Tokens the template doesn't know; the sheet refuses to export while
    /// there are any.
    public let unknownTokens: [String]
    public let collision: ExportNaming.Collision

    /// Name keys of every planned output, so a late renumbering can't pick
    /// a name another output of the batch was promised.
    var claimed: Set<String>
    let caseSensitive: Bool

    /// Images numbered because another image of the export has their name.
    public var sharedNameCount: Int { outputs.lazy.filter(\.sharesName).count }
    /// Images whose name is already taken in the destination; the policy
    /// says what happens to each (numbered, replaced or skipped).
    public var existingCount: Int { outputs.lazy.filter(\.existed).count }
    public var failures: [Output] { outputs.filter { if case .fail = $0.action { true } else { false } } }
    public func count(_ action: Action) -> Int { outputs.lazy.filter { $0.action == action }.count }

    /// Looks at the disk again just before output `i` is written, for items
    /// that appeared or went since planning (another app, or the Finder),
    /// and settles the output by the same rules. Returns the settled output.
    public mutating func recheck(_ i: Int, probe: ExportBatchPlanner.Probe = .system) -> Output {
        var output = outputs[i]
        let folder = output.url.deletingLastPathComponent()
        let item = probe.item(output.url)
        switch (output.action, item) {
        case (.write, .some), (.replace, .some(.folder)):
            switch collision {
            case .skip where item == .file: output.action = .skip
            case .replace where item == .file: output.action = .replace
            case .replace, .skip:
                output.action = .fail(reason: "a folder named “\(output.url.lastPathComponent)” is in the way")
            case .addNumber:
                let folderPath = folder.standardizedFileURL.path
                claimed.remove(ExportBatchPlanner.key(folderPath, output.url.lastPathComponent, caseSensitive))
                let caseSensitive = caseSensitive, claimed = claimed
                var next = 1
                let name = ExportBatchPlanner.firstFree(output.templateName, from: &next) { candidate in
                    claimed.contains(ExportBatchPlanner.key(folderPath, candidate, caseSensitive))
                        || probe.item(folder.appendingPathComponent(candidate)) != nil
                }
                guard let name else {
                    self.claimed.insert(ExportBatchPlanner.key(folderPath, output.url.lastPathComponent, caseSensitive))
                    output.action = .fail(reason: "no free name like “\(output.templateName)”")
                    break
                }
                output.url = folder.appendingPathComponent(name)
                self.claimed.insert(ExportBatchPlanner.key(folderPath, name, caseSensitive))
            }
        case (.replace, .none):
            output.action = .write
        default:
            break
        }
        outputs[i] = output
        return output
    }
}

public enum ExportBatchPlanner {
    public struct Options: Hashable, Sendable {
        public var template: String
        public var start: Int
        public var step: Int
        public var padding: Int
        public var letterCase: ExportNaming.LetterCase
        /// Without the dot, in the case it's written in.
        public var fileExtension: String
        public var collision: ExportNaming.Collision
        public var dateSubfolders: Bool
        public var catalogName: String
        public var timeZone: TimeZone

        public init(template: String, start: Int = 1, step: Int = 1, padding: Int = 3,
                    letterCase: ExportNaming.LetterCase = .unchanged, fileExtension: String,
                    collision: ExportNaming.Collision = .addNumber, dateSubfolders: Bool = false,
                    catalogName: String = "", timeZone: TimeZone = .current) {
            self.template = template; self.start = start; self.step = step; self.padding = padding
            self.letterCase = letterCase; self.fileExtension = fileExtension; self.collision = collision
            self.dateSubfolders = dateSubfolders; self.catalogName = catalogName; self.timeZone = timeZone
        }
    }

    /// How the planner asks the file system about names, replaceable in tests.
    public struct Probe: Sendable {
        public enum Item: Sendable { case file, folder }
        /// What is at a path, if anything. A symbolic link counts as what it
        /// points at, and a broken one as a file, because it still holds the name.
        public var item: @Sendable (URL) -> Item?
        /// Whether "IMG.JPG" and "img.jpg" are different names in this folder.
        public var isCaseSensitive: @Sendable (URL) -> Bool

        public init(item: @escaping @Sendable (URL) -> Item?, isCaseSensitive: @escaping @Sendable (URL) -> Bool) {
            self.item = item; self.isCaseSensitive = isCaseSensitive
        }

        public static let system = Probe(
            item: { url in
                var info = stat()
                guard lstat(url.path, &info) == 0 else { return nil }
                if (info.st_mode & S_IFMT) == S_IFLNK, stat(url.path, &info) != 0 { return .file }
                return (info.st_mode & S_IFMT) == S_IFDIR ? .folder : .file
            },
            isCaseSensitive: { folder in
                (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                    .volumeSupportsCaseSensitiveNames ?? false
            })

        /// Names only: nothing is on disk. For a preview before a
        /// destination is chosen.
        public static let nothingOnDisk = Probe(item: { _ in nil }, isCaseSensitive: { _ in false })
    }

    /// The outputs of exporting `records` (in batch order: `{seq}` follows
    /// it) into `destination`. Reads the file system (one `lstat` per output,
    /// more for numbered ones) but changes nothing.
    ///
    /// Name clashes are settled here, all of them:
    /// - Two outputs of the batch never share a name: a later one is
    ///   numbered ("photo-1.jpg") whatever the policy, so Replace can't make
    ///   an export overwrite its own work and Skip can't drop an image
    ///   because an earlier one took its name. Names are compared the way
    ///   the volume compares them: Unicode normalisation ignored, and letter
    ///   case too on a case-insensitive volume.
    /// - A name already taken in the destination follows the policy: Add a
    ///   number picks the first free "-n", Replace replaces a file (never a
    ///   folder), Skip skips. The numbering of batch duplicates ignores the
    ///   disk under Replace and Skip, so exporting the same images again
    ///   gives the same names and replaces or skips them, not a new set.
    public static func plan(_ records: [ImageRecord], into destination: URL, options: Options,
                            probe: Probe = .system) -> ExportBatchPlan {
        let namer = ExportNaming.Namer(template: options.template, timeZone: options.timeZone)
        let caseSensitive = probe.isCaseSensitive(destination)
        var claimed: Set<String> = []
        // Where numbering of each name last stopped, one table for names
        // taken within the batch and one for names taken on disk too, so a
        // day of images all named "{date}" is numbered in one pass rather
        // than counting up from 1 for every image. Claimed names only grow
        // and the disk is read once, so every number below is still taken.
        var nextInBatch: [String: Int] = [:]
        var nextOnDisk: [String: Int] = [:]
        var folderItems: [String: Probe.Item?] = [:]
        var outputs: [ExportBatchPlan.Output] = []
        outputs.reserveCapacity(records.count)
        let ext = options.fileExtension

        for (index, record) in records.enumerated() {
            let context = ExportNaming.Context(index: index, start: options.start, padding: options.padding,
                                               catalogName: options.catalogName, step: options.step,
                                               letterCase: options.letterCase)
            let stem = namer.stem(for: record, context: context)
            let name = ext.isEmpty ? stem : stem + "." + ext
            var folder = destination
            if options.dateSubfolders {
                let sub = ExportNaming.dateFolderName(for: record, timeZone: options.timeZone)
                folder = destination.appendingPathComponent(sub, isDirectory: true)
                let known = folderItems[sub] ?? {
                    let item = probe.item(folder)
                    folderItems[sub] = item
                    return item
                }()
                if known == .file {
                    outputs.append(.init(index: index, url: folder.appendingPathComponent(name),
                                         action: .fail(reason: "a file named “\(sub)” is in the way of its folder"),
                                         templateName: name, sharesName: false, existed: false))
                    continue
                }
            }
            let folderPath = folder.standardizedFileURL.path
            let nameKey = key(folderPath, name, caseSensitive)
            func taken(_ candidate: String) -> Bool { claimed.contains(key(folderPath, candidate, caseSensitive)) }

            var chosen: String? = name
            let sharesName = claimed.contains(nameKey)
            if sharesName { chosen = firstFree(name, from: &nextInBatch[nameKey, default: 1], isTaken: taken) }
            var action = ExportBatchPlan.Action.write
            var existed = false
            if let candidate = chosen, let item = probe.item(folder.appendingPathComponent(candidate)) {
                existed = true
                switch options.collision {
                case .addNumber:
                    chosen = firstFree(name, from: &nextOnDisk[nameKey, default: 1]) {
                        taken($0) || probe.item(folder.appendingPathComponent($0)) != nil
                    }
                case .replace:
                    action = item == .folder ? .fail(reason: "a folder named “\(candidate)” is in the way") : .replace
                case .skip:
                    action = .skip
                }
            }
            guard let final = chosen else {
                outputs.append(.init(index: index, url: folder.appendingPathComponent(name),
                                     action: .fail(reason: "no free name like “\(name)”"),
                                     templateName: name, sharesName: sharesName, existed: existed))
                continue
            }
            // A skipped or failed output still holds its name, so a later
            // image with the same name is numbered rather than skipped for it.
            claimed.insert(key(folderPath, final, caseSensitive))
            outputs.append(.init(index: index, url: folder.appendingPathComponent(final), action: action,
                                 templateName: name, sharesName: sharesName, existed: existed))
        }
        return ExportBatchPlan(outputs: outputs, destination: destination, unknownTokens: namer.unknownTokens, collision: options.collision,
                               claimed: claimed, caseSensitive: caseSensitive)
    }

    /// Names as the file system compares them, within their folder (a
    /// standardized path).
    static func key(_ folderPath: String, _ name: String, _ caseSensitive: Bool) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        let compared = caseSensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: nil)
        return folderPath + "\u{0}" + compared
    }

    /// `name`, else "name-n" for the first n from `next` on that isn't taken
    /// (`next` is left after it); nil after 99,999 (a folder that full is a
    /// mistake, not a batch).
    static func firstFree(_ name: String, from next: inout Int, isTaken: (String) -> Bool) -> String? {
        if !isTaken(name) { return name }
        while next <= 99_999 {
            let candidate = ExportNaming.numbered(name, next)
            next += 1
            if !isTaken(candidate) { return candidate }
        }
        return nil
    }
}
