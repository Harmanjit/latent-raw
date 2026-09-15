import SwiftUI
import AppKit
import Catalog

/// Move to Folder, Copy to Folder, dropping on the sidebar and Rename, as
/// the menus, the grid's context menu and the sidebar ask for them. The
/// work itself is `Library.fileOperations`.
@MainActor
struct LibraryFileCommands {
    let library: Library

    /// What a file command acts on: the grid selection, or the lead alone.
    var targets: [ImageRecord] {
        let selected = library.selectedImages
        return selected.isEmpty ? (library.selectedImage.map { [$0] } ?? []) : selected
    }

    /// Moves or copies the selection into `folder`, or into one chosen in
    /// an open panel (which is also what lets the sandbox write there).
    func transferSelection(_ mode: TransferMode, to folder: URL?) {
        let records = targets
        guard !records.isEmpty,
              let destination = folder ?? TransferDestinationPanel.choose(mode: mode, count: records.count) else { return }
        transfer(records, to: destination, mode: mode)
    }

    /// Images dragged from the grid onto a sidebar folder.
    func dropImages(_ urls: [URL], on folder: URL, mode: TransferMode) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        let records = library.images.filter { record in
            library.fileURL(for: record).map { paths.contains($0.standardizedFileURL.path) } ?? false
        }
        guard !records.isEmpty else { return }
        transfer(records, to: folder, mode: mode)
    }

    /// Whether every URL is an image of the open catalog, so a drag is the
    /// grid's rather than folders from Finder.
    func areLibraryImages(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, library.folderURL != nil else { return false }
        let paths = Set(library.images.lazy.compactMap { library.fileURL(for: $0)?.standardizedFileURL.path })
        return urls.allSatisfy { paths.contains($0.standardizedFileURL.path) }
    }

    private func transfer(_ records: [ImageRecord], to folder: URL, mode: TransferMode) {
        RecentDestinations.shared.add(folder)
        let library = library
        Task {
            let report = await library.fileOperations.transfer(records, to: folder, mode: mode)
            if !report.failures.isEmpty {
                library.lastError = Self.failureSummary(report, mode: mode)
            }
            Announcement.post(Self.summary(report, mode: mode, folder: folder))
        }
    }

    /// "Moved 3 images to “Picks”", with what was skipped or stopped.
    static func summary(_ report: TransferReport, mode: TransferMode, folder: URL) -> String {
        let done = report.completed.count
        let verb = mode == .move ? "Moved" : "Copied"
        var text = "\(verb) \(done == 1 ? "1 image" : "\(done) images") to “\(folder.lastPathComponent)”"
        if !report.skipped.isEmpty { text += ", \(report.skipped.count) already there" }
        if !report.failures.isEmpty { text += ", \(report.failures.count) failed" }
        if report.wasCancelled { text += ", stopped before the rest" }
        return text
    }

    static func failureSummary(_ report: TransferReport, mode: TransferMode) -> String {
        let total = report.completed.count + report.skipped.count + report.failures.count
        let verb = mode == .move ? "Moving" : "Copying"
        return "\(verb) failed for \(report.failures.count) of \(total): \(report.failureDescription)"
    }
}

/// The open panel for Move to Folder… and Copy to Folder….
@MainActor
enum TransferDestinationPanel {
    static func choose(mode: TransferMode, count: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = mode == .move ? "Move" : "Copy"
        let what = count == 1 ? "the selected image" : "the \(count) selected images"
        panel.message = "Choose where to \(mode == .move ? "move" : "copy") \(what). Ratings, keywords and edits go with them."
        panel.directoryURL = RecentDestinations.shared.availableFolders.first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// The last five folders images were moved or copied to, for the context
/// menu. Security-scoped bookmarks, like the sidebar's favourites: under the
/// sandbox a remembered path could name a folder chosen last week but not
/// write into it. Adapted from minivu.
@MainActor
final class RecentDestinations {
    static let shared = RecentDestinations()
    static let limit = 5

    private let defaults: UserDefaults
    private let key: String
    private(set) var folders: [URL] = []
    private var bookmarks: [Data] = []

    init(defaults: UserDefaults = .standard, key: String = "latent.recentTransferDestinations") {
        self.defaults = defaults
        self.key = key
        for data in defaults.array(forKey: key) as? [Data] ?? [] {
            // Never mount a volume or ask anything to find a folder that has gone.
            guard let resolved = BookmarkStore.resolveQuietly(data) else { continue }
            _ = resolved.url.startAccessingSecurityScopedResource()
            folders.append(resolved.url)
            bookmarks.append(resolved.stale ? (BookmarkStore.bookmark(for: resolved.url) ?? data) : data)
        }
    }

    /// The folders that are still there, newest first.
    var availableFolders: [URL] {
        folders.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Puts `folder` first, dropping the oldest past the limit.
    func add(_ folder: URL) {
        if let index = folders.firstIndex(where: { FolderAccess.samePath($0, folder) }) {
            // The URL already held moves up: it is the one whose access was
            // started, and so the one to stop when it drops off.
            let held = folders.remove(at: index)
            let data = bookmarks.remove(at: index)
            folders.insert(held, at: 0)
            bookmarks.insert(data, at: 0)
        } else {
            guard let data = BookmarkStore.bookmark(for: folder) else { return }
            _ = folder.startAccessingSecurityScopedResource()
            folders.insert(folder, at: 0)
            bookmarks.insert(data, at: 0)
        }
        while folders.count > Self.limit {
            folders.removeLast().stopAccessingSecurityScopedResource()
            bookmarks.removeLast()
        }
        defaults.set(bookmarks, forKey: key)
    }
}

/// Renames one image: the name without its extension, which stays.
struct RenameSheet: View {
    let record: ImageRecord
    /// Renames and returns nil, or returns why it couldn't.
    let onRename: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var base: String
    @State private var failure: String?
    @State private var isRenaming = false
    @FocusState private var fieldFocused: Bool

    init(record: ImageRecord, onRename: @escaping (String) async -> String?) {
        self.record = record
        self.onRename = onRename
        _base = State(initialValue: (record.fileName as NSString).deletingPathExtension)
    }

    private var fileExtension: String { (record.fileName as NSString).pathExtension }

    private var proposed: Result<String, FileOperations.NameProblem> {
        FileOperations.renamedFileName(base: base, original: record.fileName)
    }

    private var canRename: Bool {
        guard !isRenaming, case .success(let name) = proposed else { return false }
        return name != record.fileName
    }

    /// A problem with the name as typed, or the rename's own failure.
    private var problem: String? {
        if let failure { return failure }
        if case .failure(let problem) = proposed, problem != .empty { return problem.description }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(record.fileName)”")
                .font(.headline)
            HStack(spacing: 4) {
                TextField("Name", text: $base)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(rename)
                    .accessibilityLabel("New name")
                    .accessibilityHint(fileExtension.isEmpty ? "" : "The extension .\(fileExtension) is kept")
                if !fileExtension.isEmpty {
                    Text("." + fileExtension)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 340)
            Group {
                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Problem: \(problem)")
                } else {
                    Text("Its sidecar and thumbnail are renamed with it, and the name it had is kept in the sidecar.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if isRenaming {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Renaming")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
        .onChange(of: base) { failure = nil }
    }

    private func rename() {
        guard canRename, case .success(let name) = proposed else { return }
        isRenaming = true
        Task {
            let failed = await onRename(name)
            isRenaming = false
            if let failed {
                failure = failed
                Announcement.post(failed, priority: .high)
            } else {
                dismiss()
            }
        }
    }
}

/// The status bar's readout while images are moved, copied or renamed,
/// with a button that stops after the image under way.
struct FileOperationStatus: View {
    @ObservedObject var operations: LibraryFileOperations

    var body: some View {
        if let activity = operations.activity {
            HStack(spacing: 6) {
                ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .accessibilityLabel(activity.title)
                    .accessibilityValue("\(activity.done) of \(activity.total)")
                Text("\(activity.title) \(min(activity.done + 1, activity.total)) of \(activity.total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Button {
                    operations.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Stop after the image under way")
                .accessibilityLabel("Stop \(activity.title.lowercased())")
            }
        }
    }
}
