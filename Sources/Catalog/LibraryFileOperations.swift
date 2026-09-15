import Foundation
import Combine
import os

/// Move to Folder, Copy to Folder and Rename for the open Library, with
/// progress, cancelling and undo.
///
/// Operations run one after another in the order they were asked for (an
/// undo waits for the move it undoes), each off the main thread through
/// `ImageTransfer`, and each counts as the Library's pending work, so
/// quitting waits for it (`Library.perform`). The Library's list is
/// refreshed when one finishes.
///
/// Undo and redo are registered on `Library.undoManager`. Each registers
/// its opposite at once, as UndoManager requires, and that opposite reads
/// what was actually done when it runs, which is always after the
/// operation it reverses has finished.
@MainActor
public final class LibraryFileOperations: ObservableObject {
    /// The operation under way, for a progress readout.
    public struct Activity: Equatable, Sendable {
        /// "Moving", "Copying", "Renaming", "Undoing Move"…
        public var title: String
        public var done: Int
        public var total: Int
        fileprivate var generation: Int
    }

    @Published public private(set) var activity: Activity?
    /// Operations asked for and not yet finished, the running one included.
    @Published public private(set) var pendingCount = 0

    public var isBusy: Bool { pendingCount > 0 }

    /// Puts files in the Trash, for undoing a copy. The app sets it to
    /// NSWorkspace's recycle; tests to a folder of their own.
    public var recycle: @Sendable ([URL]) async throws -> Void = { urls in
        for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    /// Called before images of the open catalog are moved or renamed, with
    /// their ids, so the app can save and close them in the editor.
    public var willMoveImages: (@MainActor (Set<Int64>) -> Void)?

    private weak var library: Library?
    private var chain: Task<Void, Never>?
    private var cancellations: [TransferCancellation] = []
    private var generation = 0

    init(library: Library) {
        self.library = library
    }

    static let logger = Logger(subsystem: "com.latent.app", category: "catalog")

    // MARK: - Asking

    /// Moves or copies `records` of the open catalog into `folder`. Names
    /// already taken there get a number. Returns what happened; failures
    /// are in the report, not thrown.
    @discardableResult
    public func transfer(_ records: [ImageRecord], to folder: URL, mode: TransferMode) async -> TransferReport {
        guard let library else { return TransferReport() }
        let requests = records.compactMap { library.fileURL(for: $0) }.map { TransferRequest(source: $0, folder: folder) }
        let report = await execute(.transfer(requests, mode), title: mode == .move ? "Moving" : "Copying")
        registerUndo(report.completed, actionName: Self.actionName(mode == .move ? "Move" : "Copy", report.completed))
        return report
    }

    /// Renames `record`'s file (sidecar, thumbnail and row with it) to
    /// `name`, which must be free in its folder. Throws a readable error,
    /// the name's problem among them, when it isn't renamed.
    public func rename(_ record: ImageRecord, to name: String) async throws {
        guard let library, let url = library.fileURL(for: record) else { return }
        if let problem = FileOperations.problem(withName: name) { throw problem }
        let request = TransferRequest(source: url, folder: url.deletingLastPathComponent(), name: name)
        let report = await execute(.transfer([request], .move), title: "Renaming")
        if let failure = report.failures.first { throw FileOperationError(message: failure.reason) }
        registerUndo(report.completed, actionName: "Rename")
    }

    /// The open catalog's subfolders on the way to `folder` that it hasn't
    /// been told whether to include (DESIGN.md §5.2 `ask`), outermost first.
    /// Images put there with a sidecar would otherwise make the folder a
    /// catalog of its own without the question ever being asked, so the app
    /// asks before transferring (`decide`).
    public func undecidedSubfolders(toward folder: URL) async -> [String] {
        guard let catalog = library?.catalog else { return [] }
        let root = catalog.rootPath
        guard let chain = FolderAccess.chain(from: root, to: folder)
                ?? FolderAccess.chain(from: root.resolvingSymlinksInPath(), to: folder.resolvingSymlinksInPath())
        else { return [] }
        let relPath = chain.dropFirst().map(\.lastPathComponent).joined(separator: "/")
        guard !relPath.isEmpty else { return [] }
        do {
            return try await catalog.undecidedSubfolders(onTheWayTo: relPath)
        } catch {
            Self.logger.error("Reading subfolder modes failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// Records the answer about `undecided` (from `undecidedSubfolders`):
    /// every one included, or the outermost a catalog of its own.
    public func decide(_ undecided: [String], include: Bool) async throws {
        guard let catalog = library?.catalog else { return }
        if include {
            for relPath in undecided { try await catalog.setSubfolderMode(.included, forRelPath: relPath) }
        } else if let outermost = undecided.first {
            try await catalog.setSubfolderMode(.independent, forRelPath: outermost)
        }
    }

    /// Stops every operation asked for after the image it is on.
    public func cancel() {
        for cancellation in cancellations { cancellation.cancel() }
    }

    /// A failure to show as it is.
    public struct FileOperationError: Error, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// "Move 3 Images", "Copy “A.NEF”".
    static func actionName(_ verb: String, _ completed: [CompletedTransfer]) -> String {
        completed.count == 1 ? "\(verb) “\(completed[0].source.lastPathComponent)”" : "\(verb) \(completed.count) Images"
    }

    // MARK: - Running

    private enum Job {
        case transfer([TransferRequest], TransferMode)
        /// Undoes (or redoes) what a finished job did, read when it runs.
        case revert(TransferLedger)
    }

    /// Runs `job` after every job asked for before it, as the Library's
    /// pending work. `ledger`, when given, is filled with what it did before
    /// the next job starts.
    private func execute(_ job: Job, title: String, ledger: TransferLedger? = nil) async -> TransferReport {
        await enqueue(job, title: title, ledger: ledger).value
    }

    /// `execute`, queued at once (so it counts as busy and pending from this
    /// moment) and awaited by whoever wants the report.
    private func enqueue(_ job: Job, title: String, ledger: TransferLedger? = nil) -> Task<TransferReport, Never> {
        let previous = chain
        let cancellation = TransferCancellation()
        cancellations.append(cancellation)
        pendingCount += 1
        let task = Task { @MainActor [weak self] () -> TransferReport in
            await previous?.value
            guard let self else { return TransferReport() }
            defer {
                self.pendingCount -= 1
                self.cancellations.removeAll { $0 === cancellation }
            }
            let report = await self.run(job, title: title, cancellation: cancellation)
            ledger?.completed = report.completed
            return report
        }
        chain = Task { _ = await task.value }
        // Counted as the Library's work, so quitting waits for it.
        library?.perform(title) { _ = await task.value }
        return task
    }

    private func run(_ job: Job, title: String, cancellation: TransferCancellation) async -> TransferReport {
        guard let library else { return TransferReport() }
        let catalog = library.catalog
        generation += 1
        let current = generation
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.activity?.generation == current else { return }
                self.activity?.done = done
                self.activity?.total = total
            }
        }

        var report = TransferReport()
        switch job {
        case .transfer(let requests, let mode):
            guard !requests.isEmpty else { return report }
            announceMoves(requests.map(\.source), mode: mode)
            activity = Activity(title: title, done: 0, total: requests.count, generation: current)
            report = await ImageTransfer.run(requests, mode: mode, openCatalog: catalog,
                                             cancellation: cancellation, progress: progress)
        case .revert(let ledger):
            let items = Array(ledger.completed.reversed())
            guard !items.isEmpty else { return report }
            activity = Activity(title: title, done: 0, total: items.count, generation: current)
            var moves: [TransferRequest] = [], copies: [TransferRequest] = [], trashes: [CompletedTransfer] = []
            for item in items {
                switch item.kind {
                case .move:
                    moves.append(TransferRequest(source: item.destination, folder: item.source.deletingLastPathComponent(),
                                                 name: item.source.lastPathComponent,
                                                 preservedName: item.preservedNameChanged ? .exactly(item.previousPreservedName) : .keep))
                case .copy:
                    trashes.append(item)
                case .trash:
                    copies.append(TransferRequest(source: item.source, folder: item.destination.deletingLastPathComponent(),
                                                  name: item.destination.lastPathComponent,
                                                  preservedName: item.preservedNameChanged ? .exactly(item.newPreservedName) : .keep))
                }
            }
            if !moves.isEmpty {
                announceMoves(moves.map(\.source), mode: .move)
                report.merge(await ImageTransfer.run(moves, mode: .move, openCatalog: catalog,
                                                     cancellation: cancellation, progress: progress))
            }
            if !copies.isEmpty {
                report.merge(await ImageTransfer.run(copies, mode: .copy, openCatalog: catalog,
                                                     cancellation: cancellation, progress: progress))
            }
            if !trashes.isEmpty {
                report.merge(await ImageTransfer.trash(trashes, openCatalog: catalog, recycle: recycle,
                                                       cancellation: cancellation, progress: progress))
            }
        }
        if activity?.generation == current { activity = nil }

        // The grid shows the open catalog as it is now: moved images gone,
        // renamed ones renamed, copies and returning images there.
        if let catalog, catalog === library.catalog, !(report.completed.isEmpty && report.failures.isEmpty) {
            do {
                try await library.refresh()
                selectArrivals(report.completed, in: catalog)
            } catch {
                library.lastError = "Refreshing after \(title.lowercased()) failed: \(error)"
            }
        }
        return report
    }

    /// Lets the app close what it has open of images about to move.
    private func announceMoves(_ urls: [URL], mode: TransferMode) {
        guard mode == .move, let willMoveImages, let library, let root = library.folderURL else { return }
        let paths = Set(urls.lazy.filter { FolderAccess.chain(from: root, to: $0) != nil }.map(\.standardizedFileURL.path))
        guard !paths.isEmpty else { return }
        let ids = Set(library.images.lazy.compactMap { record -> Int64? in
            guard let url = library.fileURL(for: record), paths.contains(url.standardizedFileURL.path) else { return nil }
            return record.id
        })
        if !ids.isEmpty { willMoveImages(ids) }
    }

    /// Selects images that came into the open folder from outside it, as an
    /// undone move brings them back.
    private func selectArrivals(_ completed: [CompletedTransfer], in catalog: Catalog) {
        guard let library, let root = library.folderURL else { return }
        let arrived = Set(completed.lazy.filter { $0.kind == .move }.compactMap { item -> String? in
            guard FolderAccess.chain(from: root, to: item.source) == nil,
                  let chain = FolderAccess.chain(from: root, to: item.destination) else { return nil }
            return chain.dropFirst().map(\.lastPathComponent).joined(separator: "/")
        })
        guard !arrived.isEmpty else { return }
        let ids = library.images.filter { arrived.contains($0.relPath) }.compactMap(\.id)
        guard !ids.isEmpty else { return }
        library.setSelection(Set(ids), primary: ids.first)
    }

    // MARK: - Undo

    /// After an operation the user asked for: its undo.
    private func registerUndo(_ completed: [CompletedTransfer], actionName: String) {
        guard let undoManager = library?.undoManager, !completed.isEmpty else { return }
        let ledger = TransferLedger(completed)
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated { operations.revert(ledger, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        undoManager.setActionUserInfoValue(true, forKey: .changesFiles)
    }

    /// Undoes (or redoes) `ledger`, registering the opposite straight away:
    /// UndoManager files a registration made during undo as the redo, and
    /// one made later as a new undo.
    private func revert(_ ledger: TransferLedger, actionName: String) {
        let opposite = TransferLedger()
        if let undoManager = library?.undoManager {
            undoManager.registerUndo(withTarget: self) { operations in
                MainActor.assumeIsolated { operations.revert(opposite, actionName: actionName) }
            }
            undoManager.setActionName(actionName)
            undoManager.setActionUserInfoValue(true, forKey: .changesFiles)
        }
        let title = (library?.undoManager?.isRedoing == true ? "Redoing " : "Undoing ") + actionName
        let task = enqueue(.revert(ledger), title: title, ledger: opposite)
        Task { [weak self] in
            let report = await task.value
            if !report.failures.isEmpty {
                self?.library?.lastError = "\(title) failed for \(report.failures.count) of \(report.failures.count + report.completed.count): \(report.failureDescription)"
            }
        }
    }
}

extension UndoManager.UserInfoKey {
    /// True on the undo and redo of a move, copy or rename: running them
    /// changes files, so the app refuses them while an export reads them.
    public static let changesFiles = UndoManager.UserInfoKey(rawValue: "latent.changesFiles")
}

/// What one operation did, filled in when it finishes and read by the undo
/// or redo that reverses it.
@MainActor
final class TransferLedger {
    var completed: [CompletedTransfer]
    init(_ completed: [CompletedTransfer] = []) { self.completed = completed }
}

extension TransferReport {
    mutating func merge(_ other: TransferReport) {
        completed += other.completed
        skipped += other.skipped
        failures += other.failures
        wasCancelled = wasCancelled || other.wasCancelled
    }
}
