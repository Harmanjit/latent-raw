import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Catalog

// MARK: - Keyword dictionary

/// The app-wide keyword dictionary (`KeywordDictionary`), loaded once and
/// saved after each change. Every keyword the Keyword List sees in a
/// folder, and every keyword added or created, is recorded here.
@MainActor
final class KeywordDictionaryStore: ObservableObject {
    static let shared = KeywordDictionaryStore()

    @Published private(set) var dictionary: KeywordDictionary
    /// The Keyword List also lists dictionary keywords no photo of the
    /// folder carries, with a count of zero. Off by default.
    @Published var showsDictionaryKeywords: Bool {
        didSet { UserDefaults.standard.set(showsDictionaryKeywords, forKey: Self.showKey) }
    }
    /// The last save's failure, shown once by the Keyword List.
    @Published var lastError: String?

    private let url: URL
    private static let showKey = "latent.keywordList.showsDictionary"

    init(url: URL = KeywordDictionary.defaultURL) {
        self.url = url
        dictionary = KeywordDictionary.load(from: url)
        showsDictionaryKeywords = UserDefaults.standard.bool(forKey: Self.showKey)
    }

    func record(_ paths: some Sequence<String>) {
        var next = dictionary
        guard next.insert(paths) else { return }
        commit(next)
    }

    func rename(_ old: String, to new: String) {
        var next = dictionary
        guard next.rename(old, to: new) else { return }
        commit(next)
    }

    func remove(_ path: String) {
        var next = dictionary
        guard next.remove(path) else { return }
        commit(next)
    }

    /// Paths for autocompletion: every dictionary keyword and level.
    var completionPaths: Set<String> { dictionary.allPaths }

    private func commit(_ next: KeywordDictionary) {
        dictionary = next
        do {
            try next.save(to: url)
        } catch {
            lastError = "The keyword dictionary couldn't be saved: \(error.localizedDescription)"
        }
    }

    // MARK: Text files

    func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Latent Keywords.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(dictionary.text.utf8).write(to: url, options: .atomic)
        } catch {
            lastError = "The keyword list couldn't be saved: \(error.localizedDescription)"
        }
    }

    /// Adds the paths of a keyword list to the dictionary. Returns how many.
    @discardableResult
    func importList() -> Int {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return 0 }
        do {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let paths = KeywordDictionary.paths(fromText: text)
            record(paths)
            showsDictionaryKeywords = true
            Announcement.post("Imported \(paths.count == 1 ? "1 keyword" : "\(paths.count) keywords")")
            return paths.count
        } catch {
            lastError = "The keyword list couldn't be read: \(error.localizedDescription)"
            return 0
        }
    }
}

// MARK: - Recent keywords

/// The last keywords added to photos, newest first, kept in the preferences
/// for the keywording field's "Recent" chips.
@MainActor
enum RecentKeywords {
    static let key = "latent.recentKeywords"
    nonisolated static let limit = 12

    static var list: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ paths: [String]) {
        let added = paths.compactMap(KeywordPath.normalized)
        guard !added.isEmpty else { return }
        let next = recording(added, in: list)
        UserDefaults.standard.set(next, forKey: key)
    }

    /// `list` with `added` moved to the front, in the order given, at most `limit` long.
    nonisolated static func recording(_ added: [String], in list: [String], limit: Int = RecentKeywords.limit) -> [String] {
        var result: [String] = []
        for path in added + list where !result.contains(path) { result.append(path) }
        return Array(result.prefix(limit))
    }
}

/// Adding keywords from the keywording field, a chip or a drop: the change
/// itself (one undo step), and the dictionary and Recent keywords updated.
@MainActor
enum KeywordAdding {
    static func add(_ paths: [String], library: Library) {
        let clean = paths.compactMap(KeywordPath.normalized)
        guard !clean.isEmpty else { return }
        record(clean)
        library.perform("Adding keywords") { try await library.addKeywords(clean) }
    }

    static func add(_ path: String, toImageIDs ids: Set<Int64>, library: Library) {
        guard let clean = KeywordPath.normalized(path), !ids.isEmpty else { return }
        record([clean])
        library.perform("Adding a keyword") { try await library.addKeywords([clean], toImageIDs: ids) }
    }

    static func record(_ paths: [String]) {
        RecentKeywords.record(paths)
        KeywordDictionaryStore.shared.record(paths)
    }
}

// MARK: - Focus

/// Photo › Add Keywords… asks the keywording field to take the focus.
@MainActor
final class KeywordEntryFocus: ObservableObject {
    static let shared = KeywordEntryFocus()
    /// Bumped by each request; the field focuses when it changes.
    @Published private(set) var request = 0

    func requestFocus() { request += 1 }
}

// MARK: - Suggestions

/// Two rows of chips under the Add keywords field: the keywords added
/// most recently, and those most often found with the selection's own.
/// Clicking one adds it to the selection.
struct KeywordSuggestionChips: View {
    @ObservedObject var library: Library
    /// The selection's keywords, as the field above worked them out.
    let current: Set<String>
    let photos: Int
    /// Bumped by the field after it adds keywords, so Recent redraws.
    let refresh: Int

    var body: some View {
        let recent = RecentKeywords.list.filter { !current.contains($0) }
        let often = library.keywordsOftenUsed(with: current, limit: 8)
        if photos > 0, !recent.isEmpty || !often.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !recent.isEmpty { chipRow("Recent", recent) }
                if !often.isEmpty { chipRow("Often used with", often) }
            }
            .id(refresh)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keyword suggestions")
        }
    }

    private func chipRow(_ title: String, _ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(paths, id: \.self) { path in
                    Button {
                        KeywordAdding.add([path], library: library)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus").font(.system(size: 7, weight: .bold))
                            Text(KeywordPath.leaf(path)).font(.caption2).lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Add “\(KeywordPath.display(path))” to the selected photos")
                    .accessibilityLabel("Add keyword \(KeywordPath.display(path))")
                }
            }
        }
    }
}

// MARK: - Keyword List drags

/// What a Keyword List row carries when dragged onto another row to move
/// it there: its path, as plain text with a prefix no typed text has.
enum KeywordDrag {
    static let prefix = "latent-keyword:"

    static func provider(for path: String) -> NSItemProvider {
        NSItemProvider(object: (prefix + path) as NSString)
    }

    static func path(fromDropped text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        return KeywordPath.normalized(String(text.dropFirst(prefix.count)))
    }

    /// Where `dragged` goes when dropped on `target` (nil: the top level),
    /// or nil when that is no move at all, or into itself.
    static func destination(moving dragged: String, onto target: String?) -> String? {
        let leaf = KeywordPath.leaf(dragged)
        guard let target else { return KeywordPath.parent(dragged) == nil ? nil : leaf }
        guard !KeywordPath.path(target, isWithin: dragged), KeywordPath.parent(dragged) != target else { return nil }
        return target + String(KeywordPath.separator) + leaf
    }

    /// Handles a drop on a Keyword List row (`target`) or on the list's top
    /// (nil): photos from the grid get the keyword, a keyword row moves.
    @MainActor
    static func accept(_ providers: [NSItemProvider], onto target: String?, library: Library) -> Bool {
        if let target, providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            let collector = DropURLCollector(expected: files.count) { urls in
                let ids = library.collections.imageIDs(forFileURLs: urls)
                KeywordAdding.add(target, toImageIDs: ids, library: library)
            }
            for provider in files {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    Task { @MainActor in collector.add(url) }
                }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString else { return }
            let string = String(text)
            Task { @MainActor in
                guard let dragged = path(fromDropped: string),
                      let destination = destination(moving: dragged, onto: target) else { return }
                KeywordDictionaryStore.shared.rename(dragged, to: destination)
                library.perform("Moving a keyword") { try await library.renameKeyword(dragged, to: destination) }
            }
        }
        return true
    }
}

/// Gathers a drop's URLs, which arrive one by one, and hands them on once all are in.
@MainActor
private final class DropURLCollector {
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void

    init(expected: Int, done: @escaping ([URL]) -> Void) {
        remaining = expected
        self.done = done
    }

    func add(_ url: URL?) {
        if let url { urls.append(url) }
        remaining -= 1
        if remaining == 0 { done(urls) }
    }
}
