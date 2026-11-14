import SwiftUI
import AppKit
import Catalog

/// Settings › Folders › Restore Catalog Backup…: puts one of the open
/// folder's catalog backups (`CatalogBackup`) in place of its database.
///
/// The open catalog is closed first, after the editor has saved and every
/// catalog write has finished; the current database is renamed to
/// `catalog-replaced-<date>.sqlite` (kept, never deleted), the backup is
/// copied in, and the folder opens again. Refused while an export, a move
/// or copy, a merge or another job that writes to the catalog is running.
@MainActor
final class CatalogRestore: ObservableObject {
    static let shared = CatalogRestore()

    private weak var model: EditorModel?
    private weak var library: Library?
    private weak var exportQueue: ExportQueue?
    @Published private(set) var isRestoring = false
    /// What the last restore did, for the Settings tab.
    @Published private(set) var status = ""

    /// ContentView attaches its window's objects when it appears.
    func attach(model: EditorModel, library: Library, exportQueue: ExportQueue) {
        self.model = model
        self.library = library
        self.exportQueue = exportQueue
    }

    /// The open folder, if any.
    var folder: URL? { library?.folderURL }

    /// The open folder's backups, newest first.
    var slots: [CatalogBackup.Slot] {
        guard let folder else { return [] }
        return CatalogBackup.slots(in: folder.appendingPathComponent(Catalog.containerName, isDirectory: true))
    }

    static func title(for slot: CatalogBackup.Slot) -> String {
        slot.date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Why a restore can't start now, or nil when it can.
    var blocker: String? {
        guard let library, library.catalog != nil else { return "No folder is open." }
        if isRestoring { return "A restore is already under way." }
        if exportQueue?.isGPUBusy == true || model?.isExporting == true {
            return "An export, Photo Merge, dust removal or face search is running. Try again when it finishes."
        }
        if library.fileOperations.isBusy { return "Photos are being moved or copied. Try again when that finishes." }
        if OutputJobs.shared.isRunning { return "A print or contact sheet is being made. Try again when it finishes." }
        return nil
    }

    /// Asks, then restores `slot` into the open folder.
    func confirmAndRestore(_ slot: CatalogBackup.Slot) {
        if let blocker {
            let alert = NSAlert()
            alert.messageText = "The catalog can’t be restored now"
            alert.informativeText = blocker
            alert.runModal()
            return
        }
        guard let folder else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore the catalog of “\(folder.lastPathComponent)” from \(Self.title(for: slot))?"
        alert.informativeText = "The folder closes and opens again with the backup’s collections, stacks, subfolder "
            + "choices and other catalog settings. Edits, ratings and keywords saved in sidecars since then are read "
            + "back from the sidecars. The current catalog is kept beside it as catalog-replaced-<date>.sqlite."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await restore(slot, in: folder) }
    }

    private func restore(_ slot: CatalogBackup.Slot, in folder: URL) async {
        guard let library, let catalog = library.catalog else { return }
        isRestoring = true
        defer { isRestoring = false }
        // The editor saves and closes, and every write it or anything else
        // started finishes, before the database closes under them.
        model?.flushPendingSave()
        library.willReplaceCatalog?()
        await library.waitForPendingWork()
        let container = folder.appendingPathComponent(Catalog.containerName, isDirectory: true)
        do {
            try await catalog.closeDatabase()
            let replaced = try await Task.detached(priority: .userInitiated) {
                try CatalogBackup.restore(slot, container: container)
            }.value
            try await library.open(folder: folder)
            status = "Restored the backup from \(Self.title(for: slot))."
                + (replaced.map { " The previous catalog is \($0.lastPathComponent)." } ?? "")
        } catch {
            status = "The backup couldn’t be restored: \(error.localizedDescription)"
            // Whatever happened, the folder opens again on what is there.
            try? await library.open(folder: folder)
        }
    }
}

/// The Restore Catalog Backup… menu and what it says, in Settings › Folders.
struct CatalogBackupSection: View {
    @ObservedObject private var restore = CatalogRestore.shared

    var body: some View {
        Section("Catalog backups") {
            let slots = restore.slots
            LabeledContent("Open folder") {
                Text(restore.folder?.lastPathComponent ?? "None")
                    .foregroundStyle(restore.folder == nil ? .secondary : .primary)
            }
            Menu("Restore Catalog Backup…") {
                ForEach(slots) { slot in
                    Button(CatalogRestore.title(for: slot)) { restore.confirmAndRestore(slot) }
                }
            }
            .disabled(slots.isEmpty || restore.isRestoring)
            .help("Replace the open folder’s catalog with one of its backups. The current catalog is kept.")
            .accessibilityLabel("Restore Catalog Backup, \(slots.count) backup\(slots.count == 1 ? "" : "s")")
            Text(slots.isEmpty
                 ? "No backups yet. Latent backs up a folder’s catalog once a day when it opens, and before an update changes the catalog’s format, keeping the last five in _latent/backups."
                 : "Latent backs up a folder’s catalog once a day when it opens, and before an update changes the catalog’s format, keeping the last five in _latent/backups.")
                .font(.caption).foregroundStyle(.secondary)
            if !restore.status.isEmpty {
                Text(restore.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
