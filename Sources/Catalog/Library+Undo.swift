import Foundation
import os

/// Undo and redo for what the Library changes: ratings, flags, rotation,
/// keywords, and settings pasted or presets applied to stored edits.
///
/// Actions are filed on `undoManager` (the Library's own) with their
/// catalog as the target. Image ids belong to a catalog, so a catalog that is replaced
/// takes its actions with it (`dropUndo(for:)`), and an undo never runs on
/// another catalog's ids.
///
/// The changes are asynchronous, and NSUndoManager puts an action on the
/// redo stack only while it is undoing. So, as in minivu's browser, an undo
/// or redo files its opposite at once, while the manager is still undoing,
/// and a fresh action files its undo only once it has finished, for the
/// images it changed (see `undoRegistration`).
extension Library {
    /// What an undo or redo sets, image by image. Values are what each
    /// image had, except rotation, which turns back by as many quarter
    /// turns: rotations add up as they are written, and two in flight may
    /// finish in either order.
    enum UndoableChange: Sendable {
        case rating([Int64: Int])
        case flag([Int64: Int])
        case rotation([Int64], quarterTurns: Int)
        case keywords([Int64: [String]])
        case edits([Int64: StoredEdit?])

        var ids: [Int64] {
            switch self {
            case .rating(let values), .flag(let values): Array(values.keys)
            case .rotation(let ids, _): ids
            case .keywords(let values): Array(values.keys)
            case .edits(let values): Array(values.keys)
            }
        }
    }

    /// What an undo or redo put back that the app may be showing outside
    /// the grid: an editor holding one of the images has to catch up.
    public enum RestoredAspect: Sendable {
        case rotation, edits
    }

    /// "Rating", or "Rating (12 Images)" when the action changed several.
    static func undoActionName(_ action: String, count: Int) -> String {
        count > 1 ? "\(action) (\(count) Images)" : action
    }

    // MARK: Registration

    /// Files `inverse` under `actionName` for `catalog` at the right moment:
    /// at once when this runs as an undo or redo (so it lands on the other
    /// stack), or when the returned function is called with true, for a
    /// fresh action that has just succeeded.
    public func undoRegistration(_ actionName: String, in catalog: Catalog,
                                 _ inverse: @escaping @MainActor @Sendable (Library, Catalog) -> Void) -> (Bool) -> Void {
        let register: (Bool) -> Void = { [weak self] succeeded in
            guard succeeded, let self else { return }
            self.fileUndo(actionName, in: catalog, inverse)
        }
        guard let manager = undoManager, manager.isUndoing || manager.isRedoing else { return register }
        register(true)
        return { _ in }
    }

    private func fileUndo(_ actionName: String, in catalog: Catalog,
                          _ inverse: @escaping @MainActor @Sendable (Library, Catalog) -> Void) {
        // A replaced catalog has had its actions dropped and gains no more.
        guard let manager = undoManager, catalog === self.catalog else { return }
        // A fresh action finishes after its key press's event has gone, so
        // it gets a group of its own, closed here. With grouping by event
        // on, opening a group outside an event first opens an event group
        // that nothing closes until the next event, and the next action
        // would join this one; so it is off for the moment. While undoing,
        // the manager's group is open and the opposite goes into it.
        let ownGroup = manager.groupingLevel == 0
        let groupsByEvent = manager.groupsByEvent
        if ownGroup {
            manager.groupsByEvent = false
            manager.beginUndoGrouping()
        }
        manager.registerUndo(withTarget: catalog) { [weak self] catalog in
            MainActor.assumeIsolated {
                guard let self else { return }
                inverse(self, catalog)
            }
        }
        manager.setActionName(actionName)
        if ownGroup {
            manager.endUndoGrouping()
            manager.groupsByEvent = groupsByEvent
        }
    }

    /// Forgets the undo of a catalog being replaced: its ids mean other
    /// photos in the next one.
    func dropUndo(for catalog: Catalog) {
        undoManager?.removeAllActions(withTarget: catalog)
    }

    /// Files the undo of a fresh action that changed `count` images.
    func fileFreshUndo(_ action: String, count: Int, in catalog: Catalog?,
                       undo: UndoableChange, redo: UndoableChange) {
        guard let catalog, count > 0 else { return }
        let name = Self.undoActionName(action, count: count)
        undoRegistration(name, in: catalog) { library, catalog in
            library.restore(undo, opposite: redo, named: name, in: catalog)
        }(true)
    }

    // MARK: Undoing and redoing

    /// Runs as an undo or redo: files the opposite at once, then makes the
    /// change. Restores run one after another, in the order they were
    /// asked for, so undoing twice quickly ends at the older value on every
    /// image. One whose catalog has been replaced by the time it starts is
    /// dropped; one under way finishes in its own catalog.
    func restore(_ change: UndoableChange, opposite: UndoableChange, named actionName: String, in catalog: Catalog) {
        let verb = undoManager?.isRedoing == true ? "Redo" : "Undo"
        let done = undoRegistration(actionName, in: catalog) { library, catalog in
            library.restore(opposite, opposite: change, named: actionName, in: catalog)
        }
        let previous = undoRestores
        let restoring = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, catalog === self.catalog else { return }
            try await self.apply(change, in: catalog)
        }
        undoRestores = restoring
        perform("\(verb) \(actionName)") {
            try await restoring.value
            done(true)
        }
    }

    /// Sets each image's value, row and sidecar, through `change` so the
    /// grid, filters and badges follow. Images no longer in the list (the
    /// file has gone) are skipped.
    private func apply(_ undoable: UndoableChange, in catalog: Catalog) async throws {
        let wanted = Set(undoable.ids)
        let records = images.filter { $0.id.map(wanted.contains) ?? false }
        var failure: (any Error)?
        do {
            switch undoable {
            case .rating(let values):
                try await change(records) { catalog, id, _ in
                    if let value = values[id] { try await catalog.setRating(value, forImageID: id) }
                }
            case .flag(let values):
                try await change(records) { catalog, id, _ in
                    if let value = values[id] { try await catalog.setFlag(ImageFlag(rawValue: value) ?? .none, forImageID: id) }
                }
            case .rotation(_, let quarterTurns):
                try await change(records) { catalog, id, _ in
                    try await catalog.rotate(by: quarterTurns, forImageID: id)
                }
            case .keywords(let values):
                try await change(records) { catalog, id, _ in
                    try await catalog.setKeywords(values[id] ?? [], forImageID: id)
                }
            case .edits(let values):
                try await change(records) { catalog, id, _ in
                    if let edit = values[id] { try await catalog.setStoredEdit(edit, forImageID: id) }
                }
            }
        } catch {
            failure = error
        }
        // What the rows alone don't show, for the images that are still
        // the open catalog's.
        if catalog === self.catalog {
            let ids = Set(records.compactMap(\.id))
            switch undoable {
            case .rating, .flag:
                break
            case .rotation:
                didRestoreImages?(ids, .rotation)
            case .keywords(let values):
                for id in ids {
                    let names = Set((values[id] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                        .subtracting([""])
                    keywordIndex[id] = names.isEmpty ? nil : names
                }
            case .edits(let values):
                for id in ids {
                    if values[id] ?? nil == nil { editedImageIDs.remove(id) } else { editedImageIDs.insert(id) }
                }
                startThumbnailGeneration()
                didRestoreImages?(ids, .edits)
            }
        }
        if let failure { throw failure }
    }
}

/// Collects what each image had before a change, from the change's
/// per-image closures, which may run off the main actor.
final class UndoLedger<Value: Sendable>: Sendable {
    private let values = OSAllocatedUnfairLock<[Int64: Value]>(initialState: [:])

    func record(_ id: Int64, _ value: Value) {
        values.withLock { $0[id] = value }
    }

    var recorded: [Int64: Value] { values.withLock { $0 } }
}
