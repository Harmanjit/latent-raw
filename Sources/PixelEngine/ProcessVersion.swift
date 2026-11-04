import Foundation

/// Process versions: which generation of Latent's rendering an edit was
/// made with (`EditStack.process`, `EditParameters.processVersion`).
///
/// A rendering change that would make an existing edit look different is
/// introduced as a new version rather than applied to every photo at once:
/// edits keep the version they were made with, and keep rendering as they
/// did, until the user updates them (Develop › Calibration › Process, or
/// the Update Process Version dialog). New edits, and edits reset to their
/// defaults, take the current version.
///
/// There is one version so far. Everything Latent has rendered, the
/// controls the 3 November 2026 merges added included, is version 1: each of
/// those controls is neutral when absent, so it changed nothing about an
/// existing edit (the golden renders did not move). The next change that
/// does is added here as version 2, with `changes` saying what renders
/// differently, and the render stage it touches branches on
/// `EditParameters.process` (`< .version2` keeps the old behaviour).
public struct ProcessVersion: Hashable, Comparable, Sendable, Identifiable {
    /// As stored in the edit: "1.0".
    public let id: String
    /// The number shown: "Version 1".
    public let number: Int
    /// What renders differently from the version before, for the Update
    /// dialog. Empty for the first.
    public let changes: [String]

    public init(id: String, number: Int, changes: [String]) {
        self.id = id
        self.number = number
        self.changes = changes
    }

    public static let version1 = ProcessVersion(id: "1.0", number: 1, changes: [])

    /// Every version this build can render, oldest first.
    public static let all: [ProcessVersion] = [.version1]

    /// What new edits are made with.
    public static var current: ProcessVersion { all[all.count - 1] }

    public var title: String { "Version \(number)" }

    /// A stored version string, if this build knows it.
    public static func known(_ id: String) -> ProcessVersion? {
        all.first { $0.id == id }
    }

    public static func < (a: ProcessVersion, b: ProcessVersion) -> Bool {
        isOlder(a.id, than: b.id)
    }

    /// Orders stored version strings numerically, "major.minor": "1.0" is
    /// older than "2.0", and "2.0" than "10.0". A string that doesn't parse
    /// counts as 0.0, older than any real version.
    public static func isOlder(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        return x.major != y.major ? x.major < y.major : x.minor < y.minor
    }

    private static func parts(_ s: String) -> (major: Int, minor: Int) {
        let pieces = s.split(separator: ".", maxSplits: 1).map { Int($0) }
        guard let major = pieces.first ?? nil else { return (0, 0) }
        return (major, pieces.count > 1 ? (pieces[1] ?? 0) : 0)
    }

    /// True for an edit made with a version older than `current`: one the
    /// Update Process Version dialog offers to bring up to date.
    public static func isOutdated(_ id: String, current: ProcessVersion = .current) -> Bool {
        isOlder(id, than: current.id)
    }

    /// True for an edit made by a newer Latent, with a version this build
    /// doesn't know. It renders as the current version here.
    public static func isNewer(_ id: String, current: ProcessVersion = .current) -> Bool {
        isOlder(current.id, than: id)
    }

    /// What the menu says for a stored version string.
    public static func title(for id: String, current: ProcessVersion = .current) -> String {
        if let v = known(id) { return v == current ? "\(v.title) (Current)" : v.title }
        return isNewer(id, current: current) ? "\(id) (from a newer Latent)" : id
    }

    /// The changes between `id` and `current`, oldest first: what updating
    /// would change.
    public static func changes(from id: String, to current: ProcessVersion = .current,
                               among versions: [ProcessVersion] = all) -> [String] {
        versions.filter { isOlder(id, than: $0.id) && !isOlder(current.id, than: $0.id) }.flatMap(\.changes)
    }
}

extension EditParameters {
    /// The process version as a known version; a string this build doesn't
    /// know renders as the current one.
    public var process: ProcessVersion { ProcessVersion.known(processVersion) ?? .current }
}

extension EditStack {
    /// This stack at `version`, everything else as it was.
    public func updatingProcess(to version: ProcessVersion = .current) -> EditStack {
        var s = self
        s.process = version.id
        return s
    }

    /// A stored edit brought up to `version`, or nil when it already is
    /// (or is newer) and nothing needs writing. Throws as `decode` does.
    public static func updatingProcess(json: String, to version: ProcessVersion = .current) throws -> String? {
        let stack = try decode(json: json)
        guard ProcessVersion.isOutdated(stack.process, current: version) else { return nil }
        return try stack.updatingProcess(to: version).encodeJSON()
    }

    /// The process version a stored edit's JSON records, for the catalog's
    /// `process_version` column; the current one when it can't be read.
    public static func processVersion(ofJSON json: String?) -> String {
        guard let json, let stack = try? decode(json: json) else { return processVersion }
        return stack.process
    }
}
