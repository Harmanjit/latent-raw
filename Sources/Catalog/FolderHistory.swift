import Foundation

/// The folders opened in a window, for Back and Forward, each with the
/// images that were selected when it was left, so going back returns to
/// the photo you were on.
///
/// Plain data: the app records visits and selections and opens what Back
/// and Forward return.
public struct FolderHistory: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var folder: URL
        /// Selected images by catalog-relative path, which, unlike ids,
        /// survive the catalog being closed and opened again.
        public var selection: [String] = []
        public var lead: String?

        public init(folder: URL, selection: [String] = [], lead: String? = nil) {
            self.folder = folder.standardizedFileURL
            self.selection = selection
            self.lead = lead
        }
    }

    public private(set) var entries: [Entry] = []
    /// The entry Back and Forward count from: the folder opened last, or
    /// the one being gone to.
    public private(set) var index = -1
    /// Enough to walk back through a session; the oldest go first.
    public static let limit = 50

    public init() {}

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    public var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    public var backEntry: Entry? { canGoBack ? entries[index - 1] : nil }
    public var forwardEntry: Entry? { canGoForward ? entries[index + 1] : nil }

    /// A folder opened other than by Back or Forward: it becomes the newest
    /// entry and whatever was ahead of the current one is dropped, as in a
    /// browser. Opening the current folder again changes nothing.
    public mutating func visit(_ folder: URL) {
        if let current, FolderAccess.samePath(current.folder, folder) { return }
        if index + 1 < entries.count { entries.removeSubrange((index + 1)...) }
        entries.append(Entry(folder: folder))
        if entries.count > Self.limit {
            let excess = entries.count - Self.limit
            entries.removeFirst(excess)
        }
        index = entries.count - 1
    }

    /// Moves back (-1) or forward (+1) and returns the entry to open, or nil
    /// when there is none that way.
    public mutating func step(_ offset: Int) -> Entry? {
        let target = index + offset
        guard offset != 0, entries.indices.contains(target) else { return nil }
        index = target
        return entries[target]
    }

    /// Records what was selected in `folder` as it is left. Every entry for
    /// that folder takes it: the selection it had last is the one to go back to.
    public mutating func remember(selection: [String], lead: String?, in folder: URL) {
        for i in entries.indices where FolderAccess.samePath(entries[i].folder, folder) {
            entries[i].selection = selection
            entries[i].lead = lead
        }
    }
}
