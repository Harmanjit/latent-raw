import Foundation
import Combine

/// Keeps the open folder's grid in step with the disk: files copied in,
/// deleted or renamed in Finder (or by a camera's software, or a
/// watched-folder import) show up without reopening the folder.
///
/// A `FolderWatcher` follows whichever folder the Library has open. Each
/// burst of changes is waited out (`debounce`: a card's worth of files
/// copied in is one refresh, not hundreds), then the folder is reconciled
/// through `Library.refresh`, the same scan opening it runs, so renames are
/// recognised by their content and sidecars are kept. While Latent is
/// moving or renaming files itself, the refresh waits for that to finish
/// (which refreshes too), and a change seen during a refresh earns one
/// more pass afterwards, never a pile of them.
@MainActor
public final class LibraryFolderWatch: ObservableObject {
    /// The folder being watched, nil when watching is off or nothing is open.
    @Published public private(set) var watchedFolder: URL?
    /// Off stops the watcher; the Refresh command still works.
    public var isEnabled: Bool {
        didSet { if isEnabled != oldValue { watch(library?.folderURL) } }
    }
    /// How long the folder must be quiet before it is scanned.
    public var debounce: Duration
    /// Scans this watch has started, for tests.
    public private(set) var refreshCount = 0

    private weak var library: Library?
    private var watcher: FolderWatcher?
    private var subscription: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var isRefreshing = false
    private var needsAnotherPass = false

    public init(library: Library, isEnabled: Bool = true, debounce: Duration = .milliseconds(800)) {
        self.library = library
        self.isEnabled = isEnabled
        self.debounce = debounce
        // `$folderURL` publishes as the folder changes, on the main thread.
        subscription = library.$folderURL.removeDuplicates().sink { [weak self] folder in
            MainActor.assumeIsolated { self?.watch(folder) }
        }
    }

    /// Watches `folder`, or nothing.
    private func watch(_ folder: URL?) {
        pending?.cancel()
        pending = nil
        watcher?.stop()
        watcher = nil
        guard isEnabled, let folder else {
            watchedFolder = nil
            return
        }
        watcher = FolderWatcher(root: folder) { [weak self] in
            Task { @MainActor in self?.changesSeen() }
        }
        watchedFolder = watcher == nil ? nil : folder
    }

    /// Starts (or restarts) the quiet period before a scan.
    func changesSeen() {
        guard watcher != nil else { return }
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        pending = nil
        guard let library, library.folderURL != nil else { return }
        if isRefreshing {
            needsAnotherPass = true
            return
        }
        // Latent's own move or rename refreshes when it is done; scanning
        // half way through would only be thrown away.
        if library.fileOperations.isBusy {
            changesSeen()
            return
        }
        isRefreshing = true
        refreshCount += 1
        library.perform("Refreshing the folder") { [weak self] in
            defer { self?.refreshFinished() }
            try await library.refresh()
        }
    }

    private func refreshFinished() {
        isRefreshing = false
        if needsAnotherPass {
            needsAnotherPass = false
            changesSeen()
        }
    }
}
