import Foundation
import AppKit
import Catalog
import PixelEngine

/// Settings › Folders › Auto Import: raw files that land in a watched
/// folder (a tethering app's, a card reader's drop folder) are moved or
/// copied into a destination folder, optionally with a develop preset, and
/// appear in the grid when the destination is the open folder or inside it.
///
/// The watched folder is followed with a `FolderWatcher`; each round looks
/// at the folder twice, a couple of seconds apart, and takes only the files
/// that didn't change in between, so a photo still being written is left
/// for the next round (`AutoImport.settled`). The transfer itself is
/// `ImageTransfer`'s: nothing is overwritten, a taken name gets a number.
///
/// An import isn't on the Library's undo list: it is the file system's
/// doing, not a command, and undoing it would put the files back where the
/// watcher would import them again. A photo brought in by mistake can be
/// moved with Move to Folder (which can be undone) or in Finder.
@MainActor
final class AutoImportController: ObservableObject {
    static let shared = AutoImportController()

    static let sourceKey = "latent.autoImportSource"
    static let destinationKey = "latent.autoImportDestination"

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "latent.autoImport.enabled"); update() }
    }
    @Published var mode: TransferMode {
        didSet { defaults.set(mode.rawValue, forKey: "latent.autoImport.mode") }
    }
    /// The develop preset each imported photo gets, by name; nil for none.
    @Published var presetName: String? {
        didSet { defaults.set(presetName, forKey: "latent.autoImport.preset") }
    }
    @Published private(set) var source: URL?
    @Published private(set) var destination: URL?
    /// What the watch is doing or last did, for Settings.
    @Published private(set) var status = "Off."
    @Published private(set) var isImporting = false

    private let defaults: UserDefaults
    /// How long a file must stay unchanged before it is taken.
    let settle: Duration
    /// Where presets come from; replaceable for tests.
    var presets: () -> [Preset] = { PresetStore.load() }
    private weak var library: Library?
    private var watcher: FolderWatcher?
    private var round: Task<Void, Never>?
    private var needsAnotherRound = false
    private var ledger: AutoImportLedger
    private var started = false

    init(defaults: UserDefaults = .standard, settle: Duration = .seconds(2)) {
        self.defaults = defaults
        self.settle = settle
        isEnabled = defaults.bool(forKey: "latent.autoImport.enabled")
        mode = TransferMode(rawValue: defaults.string(forKey: "latent.autoImport.mode") ?? "") ?? .move
        presetName = defaults.string(forKey: "latent.autoImport.preset")
        ledger = defaults.data(forKey: "latent.autoImport.ledger")
            .flatMap { try? JSONDecoder().decode(AutoImportLedger.self, from: $0) } ?? AutoImportLedger()
    }

    /// Once per launch: the two folders' bookmarks are resolved off the
    /// main thread (a share that stopped answering would hold launch), and
    /// the watch starts if it is on.
    func start(library: Library) {
        self.library = library
        guard !started else { return }
        started = true
        Task {
            async let source = BookmarkStore.resolveInBackground(key: Self.sourceKey)
            async let destination = BookmarkStore.resolveInBackground(key: Self.destinationKey)
            let (s, d) = await (source, destination)
            if self.source == nil { self.source = s }
            if self.destination == nil { self.destination = d }
            update()
        }
    }

    /// A folder chosen in Settings. Its bookmark carries the open panel's
    /// permission to later launches.
    func setSource(_ url: URL?) {
        if let url { BookmarkStore.save(url, key: Self.sourceKey) } else { BookmarkStore.clear(key: Self.sourceKey) }
        _ = url?.startAccessingSecurityScopedResource()
        source = url
        update()
    }

    func setDestination(_ url: URL?) {
        if let url { BookmarkStore.save(url, key: Self.destinationKey) } else { BookmarkStore.clear(key: Self.destinationKey) }
        _ = url?.startAccessingSecurityScopedResource()
        destination = url
        update()
    }

    /// Tests: both folders without bookmarks, and the Library to tell.
    func setFoldersForTesting(source: URL, destination: URL, library: Library?) {
        self.library = library
        self.source = source
        self.destination = destination
        update()
    }

    /// Why the watch can't run as set, or nil.
    var problem: String? {
        guard let source else { return "Choose the folder to watch." }
        guard let destination else { return "Choose where imported photos go." }
        return AutoImport.problem(source: source, destination: destination)
    }

    /// Starts or stops the watcher to match the settings, and imports
    /// whatever is already waiting.
    func update() {
        watcher?.stop()
        watcher = nil
        guard isEnabled else {
            status = "Off."
            return
        }
        if let problem {
            status = problem
            return
        }
        guard let source else { return }
        watcher = FolderWatcher(root: source) { [weak self] in
            Task { @MainActor in self?.importWaiting() }
        }
        status = watcher == nil ? "“\(source.lastPathComponent)” can’t be watched." : "Watching “\(source.lastPathComponent)”."
        importWaiting()
    }

    /// Runs a round now, or once more after the one running.
    func importWaiting() {
        guard isEnabled, problem == nil else { return }
        if round != nil {
            needsAnotherRound = true
            return
        }
        round = Task { [weak self] in
            await self?.runRounds()
            self?.round = nil
        }
    }

    /// Waits for the round under way, for tests.
    func waitForRound() async {
        while let round { await round.value }
    }

    private func runRounds() async {
        repeat {
            needsAnotherRound = false
            guard isEnabled, problem == nil, let source, let destination else { return }
            let before = await Task.detached(priority: .utility) { AutoImport.look(in: source) }.value
            let fresh = before.filter { !isLedgered($0.key, $0.value) }
            guard !fresh.isEmpty else { return }
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            let after = await Task.detached(priority: .utility) { AutoImport.look(in: source) }.value
            let ready = AutoImport.settled(before: before, after: after).filter { !isLedgered($0, after[$0]!) }
            if !ready.isEmpty { await importFiles(ready, signatures: after, to: destination) }
            // Files still being written get another look.
            if after.contains(where: { !ready.contains($0.key) && !isLedgered($0.key, $0.value) }) {
                needsAnotherRound = true
            }
        } while needsAnotherRound
    }

    private func isLedgered(_ url: URL, _ signature: AutoImportSignature) -> Bool {
        mode == .copy && ledger.contains(AutoImportLedger.key(name: url.lastPathComponent, signature: signature))
    }

    private func importFiles(_ files: [URL], signatures: [URL: AutoImportSignature], to destination: URL) async {
        isImporting = true
        defer { isImporting = false }
        var note = ""
        let edit = makeEdit(note: &note)
        let mode = mode
        let report = await AutoImport.run(files, to: destination, mode: mode, edit: edit,
                                          openCatalog: library?.catalog)
        if mode == .copy {
            let failed = Set(report.failures.map { $0.url.standardizedFileURL })
            for file in files where !failed.contains(file.standardizedFileURL) {
                if let signature = signatures[file] {
                    ledger.insert(AutoImportLedger.key(name: file.lastPathComponent, signature: signature))
                }
            }
            defaults.set(try? JSONEncoder().encode(ledger), forKey: "latent.autoImport.ledger")
        }
        status = report.summary + note + "."
        Announcement.post(report.summary)
        if !report.failures.isEmpty || !report.presetsNotApplied.isEmpty || !note.isEmpty {
            library?.lastError = status
        }
        // The open folder shows them now, whether or not it is watched.
        if let library, let open = library.folderURL, !report.imported.isEmpty,
           FolderAccess.chain(from: open.resolvingSymlinksInPath(), to: destination.resolvingSymlinksInPath()) != nil
            || FolderAccess.chain(from: open, to: destination) != nil {
            library.refreshFromDisk("Showing imported photos")
        }
    }

    /// The chosen preset as an edit for a new photo: the preset over the
    /// defaults, exactly as applying it to an unedited photo would give.
    private func makeEdit(note: inout String) -> AutoImportEdit? {
        guard let presetName else { return nil }
        guard let preset = presets().first(where: { $0.name == presetName }) else {
            note = " · the preset “\(presetName)” no longer exists, so none was applied"
            return nil
        }
        let stack = EditStack().merged(with: preset.stack, groups: preset.groups)
        guard stack != EditStack(), let json = try? stack.encodeJSON() else { return nil }
        return AutoImportEdit(json: json, schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion)
    }
}

/// The app's folder watching: the open folder's watch (Settings › Folders
/// › Watch the open folder) and the watched-folder import, both started
/// with the main window.
@MainActor
final class FolderWatching: ObservableObject {
    static let shared = FolderWatching()

    @Published var watchOpenFolder: Bool {
        didSet {
            UserDefaults.standard.set(watchOpenFolder, forKey: "latent.watchOpenFolder")
            openFolderWatch?.isEnabled = watchOpenFolder
        }
    }
    private(set) var openFolderWatch: LibraryFolderWatch?

    private init() {
        watchOpenFolder = UserDefaults.standard.object(forKey: "latent.watchOpenFolder") as? Bool ?? true
    }

    func start(library: Library) {
        if openFolderWatch == nil {
            openFolderWatch = LibraryFolderWatch(library: library, isEnabled: watchOpenFolder)
        }
        AutoImportController.shared.start(library: library)
    }
}
