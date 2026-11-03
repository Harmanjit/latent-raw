import Foundation

extension TransferMode: Codable {}

/// A develop setting to give each imported photo, as an edit stack's JSON
/// (the catalog doesn't know the stack's contents; the app makes it from
/// a preset).
public struct AutoImportEdit: Sendable, Equatable {
    public var json: String
    public var schemaVersion: Int
    public var processVersion: String

    public init(json: String, schemaVersion: Int, processVersion: String) {
        self.json = json
        self.schemaVersion = schemaVersion
        self.processVersion = processVersion
    }
}

/// What one round of a watched-folder import did.
public struct AutoImportReport: Sendable {
    /// Where each imported photo is now.
    public var imported: [URL] = []
    public var failures: [TransferReport.Failure] = []
    /// Photos that arrived without the preset, and why.
    public var presetsNotApplied: [TransferReport.Failure] = []

    public init() {}

    public var summary: String {
        let n = imported.count
        var text = "Imported \(n) photo\(n == 1 ? "" : "s") from the watched folder"
        if !failures.isEmpty {
            text += " · \(failures.count) couldn’t be imported: " + failures.map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: "; ")
        }
        if !presetsNotApplied.isEmpty {
            text += " · the preset wasn’t applied to " + presetsNotApplied.map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: "; ")
        }
        return text
    }
}

/// How a file looked at one moment: a file still being written changes
/// one of these between two looks.
public struct AutoImportSignature: Equatable, Sendable {
    public var size: Int64
    public var modified: Date
    /// The status-change time, which moves with every write even when a
    /// copy keeps the original's modification date (Finder's does).
    public var changed: Date

    public init(size: Int64, modified: Date, changed: Date) {
        self.size = size
        self.modified = modified
        self.changed = changed
    }
}

/// Remembers what a Copy-mode import has already copied, since copying
/// leaves the originals where they are and they would otherwise be copied
/// again on every round. Keyed by name, size and modification time, so a
/// different photo that reuses a name is still imported. Bounded, oldest
/// forgotten first.
public struct AutoImportLedger: Codable, Equatable, Sendable {
    public private(set) var keys: [String] = []
    public static let capacity = 20_000

    public init() {}

    public static func key(name: String, signature: AutoImportSignature) -> String {
        "\(name)|\(signature.size)|\(Int64((signature.modified.timeIntervalSince1970 * 1000).rounded()))"
    }

    public func contains(_ key: String) -> Bool { keys.contains(key) }

    public mutating func insert(_ key: String) {
        guard !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > Self.capacity { keys.removeFirst(keys.count - Self.capacity) }
    }
}

/// Lightroom's Auto Import: raw files that appear in a watched folder are
/// moved (or copied) into a destination folder, optionally with a develop
/// preset, and the catalog that indexes the destination picks them up on
/// its next scan, at once when it is the open folder.
///
/// Only the watched folder's own files are imported, not its subfolders,
/// and only those reconcile would index. The transfer is `ImageTransfer`'s,
/// so a name already taken gets a number, nothing is ever overwritten, and
/// a sidecar the file brings along from a catalog of its own comes with it.
public enum AutoImport {
    /// Why `source` can't feed `destination`, or nil when it can. Watching a
    /// folder that is, contains or sits inside the destination would import
    /// photos into themselves, round after round.
    public static func problem(source: URL, destination: URL) -> String? {
        let a = FolderAccess.components(source.standardizedFileURL.resolvingSymlinksInPath())
        let b = FolderAccess.components(destination.standardizedFileURL.resolvingSymlinksInPath())
        if a == b { return "The watched folder and the destination are the same folder." }
        if b.starts(with: a) { return "The destination is inside the watched folder." }
        if a.starts(with: b) { return "The watched folder is inside the destination." }
        if a.contains(Catalog.containerName) || a.contains(Catalog.legacyContainerName) {
            return "The watched folder is inside a catalog’s \(Catalog.containerName) folder."
        }
        return nil
    }

    /// Every raw file directly in `source`, as it looks now. Hidden files,
    /// links, subfolders and files whose contents are only in iCloud (which
    /// reading would download) are left out.
    public static func look(in source: URL) -> [URL: AutoImportSignature] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentModificationDateKey, .attributeModificationDateKey,
                                         .ubiquitousItemDownloadingStatusKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var found: [URL: AutoImportSignature] = [:]
        for entry in entries where Catalog.indexedExtensions.contains(entry.pathExtension.lowercased()) {
            guard let values = try? entry.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, !Catalog.isDataless(entry, values) else { continue }
            found[entry.standardizedFileURL] = AutoImportSignature(
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast,
                changed: values.attributeModificationDate ?? values.contentModificationDate ?? .distantPast)
        }
        return found
    }

    /// The files of `after` that look exactly as they did in `before`, a
    /// few seconds earlier: no longer being written. Ordered by name, so
    /// a burst arrives in shooting order.
    public static func settled(before: [URL: AutoImportSignature], after: [URL: AutoImportSignature]) -> [URL] {
        after.filter { url, signature in signature.size > 0 && before[url] == signature }
            .keys.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Moves or copies `files` into `destination`, then writes `edit` as a
    /// waiting sidecar for each that arrived without one, which the scan
    /// that finds the photo applies to it (`syncSidecars` adopts a sidecar
    /// made for exactly that content). A file's import and its preset fail
    /// separately: a photo whose preset couldn't be written is still
    /// imported, and named in the report.
    public static func run(_ files: [URL], to destination: URL, mode: TransferMode, edit: AutoImportEdit?,
                           openCatalog: Catalog?) async -> AutoImportReport {
        var report = AutoImportReport()
        guard !files.isEmpty else { return report }
        let requests = files.map { TransferRequest(source: $0, folder: destination) }
        let transfer = await ImageTransfer.run(requests, mode: mode, openCatalog: openCatalog)
        report.failures = transfer.failures
        for done in transfer.completed {
            report.imported.append(done.destination)
            guard let edit else { continue }
            do {
                try await writeEdit(edit, for: done.destination, openCatalog: openCatalog)
            } catch {
                report.presetsNotApplied.append(.init(url: done.destination, reason: ImageTransfer.describe(error)))
            }
        }
        return report
    }

    enum PresetProblem: Error, CustomStringConvertible {
        case hasSidecar
        case undecidedSubfolder

        var description: String {
            switch self {
            case .hasSidecar: "it came with settings of its own"
            case .undecidedSubfolder: "the destination is a subfolder its catalog doesn’t include yet"
            }
        }
    }

    /// The preset as the sidecar the destination's catalog will read for
    /// `file`. Never replaces a sidecar: one there came with the photo.
    static func writeEdit(_ edit: AutoImportEdit, for file: URL, openCatalog: Catalog?) async throws {
        let folder = file.deletingLastPathComponent()
        let location = try await ImageTransfer.location(ofFolder: folder, openCatalog: openCatalog)
        // A folder inside another catalog that it doesn't (yet) include
        // would become a catalog of its own if a container were made here.
        if !FolderAccess.hasCatalog(location.root), hasCatalogAbove(location.root) {
            throw PresetProblem.undecidedSubfolder
        }
        let relPath = location.relPath(file.lastPathComponent)
        let sidecar = location.sidecarURL(relPath)
        if FileOperations.itemExists(sidecar) { throw PresetProblem.hasSidecar }
        let hash = ImageRecord.hashData(try FileHash.xxh64(ofFileAt: file))
        let fields = XMPSidecar.Fields(
            sourceHash: FileHash.prefix + ":" + hash.map { String(format: "%02x", $0) }.joined(),
            schemaVersion: edit.schemaVersion, processVersion: edit.processVersion, editStackJSON: edit.json)
        try ImageTransfer.ensureContainer(for: location)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ImageTransfer.writeSidecarExclusively(fields, to: sidecar)
    }

    private static func hasCatalogAbove(_ folder: URL) -> Bool {
        var parent = folder.standardizedFileURL.deletingLastPathComponent()
        while parent.path != "/", !parent.path.isEmpty {
            if FolderAccess.hasCatalog(parent) { return true }
            parent = parent.deletingLastPathComponent()
        }
        return false
    }
}
