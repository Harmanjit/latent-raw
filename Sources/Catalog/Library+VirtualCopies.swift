import Foundation

/// Create Virtual Copy, Set Copy as Master and Remove Virtual Copy for the
/// open Library, with undo (VirtualCopy, Catalog+VirtualCopies).
///
/// Each finishes by refreshing the list, which picks up the new or removed
/// rows, their badges and thumbnails, as a move or a rename does.
extension Library {
    /// What an undo or redo of a virtual-copy action does.
    enum VirtualCopyStep: Sendable {
        /// Put copies back from their archives.
        case recreate
        /// Take copies out (by the ids in their archives).
        case remove
        /// Set Copy as Master again, which undoes itself.
        case swap

        var opposite: VirtualCopyStep {
            switch self {
            case .recreate: .remove
            case .remove: .recreate
            case .swap: .swap
            }
        }
    }

    // MARK: Asking

    /// Makes one virtual copy of each of `records` (a copy of a copy is a
    /// copy of its master), selects the new copies and files the undo.
    /// Returns the new copies' ids. Images that fail are named in the error
    /// thrown at the end; the others are still copied.
    @discardableResult
    public func createVirtualCopies(of records: [ImageRecord]) async throws -> [Int64] {
        guard let catalog, !records.isEmpty else { return [] }
        let ledger = VirtualCopyLedger()
        var failures: [(fileName: String, error: any Error)] = []
        for record in records {
            guard let id = record.id else { continue }
            do {
                ledger.archives.append(try await catalog.createVirtualCopy(of: id))
            } catch {
                failures.append((record.fileName, error))
            }
        }
        let ids = ledger.archives.map(\.id)
        if !ids.isEmpty {
            fileVirtualCopyUndo(Self.undoActionName("Create Virtual Copy", count: ids.count),
                                step: .remove, ledger: ledger, in: catalog)
            if catalog === self.catalog {
                try await refresh()
                setSelection(Set(ids), primary: ids.first)
            }
        }
        try Self.throwFailures(failures, total: records.count)
        return ids
    }

    /// Takes the virtual copies among `records` out of the catalog (masters
    /// and ordinary photos are left alone), selects their masters and files
    /// the undo, which puts the copies back as they were.
    public func removeVirtualCopies(_ records: [ImageRecord]) async throws {
        guard let catalog else { return }
        let copies = records.filter(\.isVirtualCopy)
        guard !copies.isEmpty else { return }
        let ids = copies.compactMap(\.id)
        willRemoveImages?(Set(ids))
        let ledger = VirtualCopyLedger()
        var failures: [(fileName: String, error: any Error)] = []
        for copy in copies {
            guard let id = copy.id else { continue }
            do {
                if let archive = try await catalog.removeVirtualCopy(id: id) { ledger.archives.append(archive) }
            } catch {
                failures.append((copy.fileName, error))
            }
        }
        if !ledger.archives.isEmpty {
            fileVirtualCopyUndo(Self.undoActionName("Remove Virtual Copy", count: ledger.archives.count),
                                step: .recreate, ledger: ledger, in: catalog)
            if catalog === self.catalog {
                try await refresh()
                selectMasters(of: ledger.archives)
            }
        }
        try Self.throwFailures(failures, total: copies.count)
    }

    /// Set Copy as Master on `record`, a virtual copy: its settings and the
    /// master's change places (Catalog.setCopyAsMaster).
    public func setCopyAsMaster(_ record: ImageRecord) async throws {
        guard let catalog, let id = record.id, record.isVirtualCopy else { return }
        let masterID = try await catalog.setCopyAsMaster(copyID: id)
        let ledger = VirtualCopyLedger()
        ledger.copyIDs = [id]
        fileVirtualCopyUndo("Set Copy as Master", step: .swap, ledger: ledger, in: catalog)
        guard catalog === self.catalog else { return }
        try await refresh()
        didRestoreImages?([id, masterID], .edits)
    }

    // MARK: Undo

    private func fileVirtualCopyUndo(_ name: String, step: VirtualCopyStep, ledger: VirtualCopyLedger,
                                     in catalog: Catalog) {
        undoRegistration(name, in: catalog) { library, catalog in
            library.replayVirtualCopies(step, ledger: ledger, named: name, in: catalog)
        }(true)
    }

    /// Runs as an undo or redo: files the opposite at once, which reads what
    /// this one did from `opposite` when it runs, then does `step`. Waits
    /// for undos and redos asked for before it, as the Library's others do.
    func replayVirtualCopies(_ step: VirtualCopyStep, ledger: VirtualCopyLedger, named name: String,
                             in catalog: Catalog) {
        let verb = undoManager?.isRedoing == true ? "Redo" : "Undo"
        let opposite = VirtualCopyLedger()
        let done = undoRegistration(name, in: catalog) { library, catalog in
            library.replayVirtualCopies(step.opposite, ledger: opposite, named: name, in: catalog)
        }
        let previous = undoRestores
        let replaying = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, catalog === self.catalog else { return }
            try await self.apply(step, ledger: ledger, opposite: opposite, in: catalog)
        }
        undoRestores = replaying
        perform("\(verb) \(name)") {
            try await replaying.value
            done(true)
        }
    }

    private func apply(_ step: VirtualCopyStep, ledger: VirtualCopyLedger, opposite: VirtualCopyLedger,
                       in catalog: Catalog) async throws {
        var failure: (any Error)?
        switch step {
        case .remove:
            // As each copy is now, so redoing puts back what was undone.
            willRemoveImages?(Set(ledger.archives.map(\.id)))
            for archive in ledger.archives {
                do {
                    if let now = try await catalog.removeVirtualCopy(id: archive.id) { opposite.archives.append(now) }
                } catch {
                    failure = failure ?? error
                }
            }
            try await refresh()
            selectMasters(of: ledger.archives)
        case .recreate:
            for archive in ledger.archives {
                do {
                    var restored = archive
                    restored.id = try await catalog.restoreVirtualCopy(archive)
                    opposite.archives.append(restored)
                } catch {
                    failure = failure ?? error
                }
            }
            try await refresh()
            let ids = opposite.archives.map(\.id)
            if !ids.isEmpty { setSelection(Set(ids), primary: ids.first) }
        case .swap:
            var changed: Set<Int64> = []
            for id in ledger.copyIDs {
                do {
                    changed.insert(try await catalog.setCopyAsMaster(copyID: id))
                    changed.insert(id)
                    opposite.copyIDs.append(id)
                } catch {
                    failure = failure ?? error
                }
            }
            try await refresh()
            if !changed.isEmpty { didRestoreImages?(changed, .edits) }
        }
        if let failure { throw failure }
    }

    // MARK: Helpers

    /// Selects the masters of copies just taken out, the nearest thing to
    /// what was selected.
    private func selectMasters(of archives: [VirtualCopyArchive]) {
        let present = Set(images.compactMap(\.id))
        let masters = Set(archives.map(\.masterID)).intersection(present)
        guard !masters.isEmpty else { return }
        setSelection(masters, primary: archives.first.map(\.masterID))
    }

    private static func throwFailures(_ failures: [(fileName: String, error: any Error)], total: Int) throws {
        if failures.count == 1, total == 1 { throw failures[0].error }
        if !failures.isEmpty { throw SelectionChangeError(total: total, failures: failures) }
    }
}

/// What a virtual-copy action did, filled in as it finishes and read by the
/// undo or redo that reverses it (as `TransferLedger` is for moves).
@MainActor
final class VirtualCopyLedger {
    var archives: [VirtualCopyArchive] = []
    var copyIDs: [Int64] = []
}
