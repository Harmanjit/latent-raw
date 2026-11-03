import Foundation
import PixelEngine

extension EditorModel {
    // MARK: - Saving

    /// Persists ~1s after the last change (DESIGN.md §5.3: nothing is
    /// written while a slider is being dragged). Also runs for a file
    /// opened without a catalog id: the settle is what records the undo
    /// step, and only the writes are skipped for such a file.
    func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    /// Saves now if anything is pending. Called before switching images
    /// so an edit made a moment before pressing → isn't lost.
    func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        if let id = catalogImageID {
            if storedEditIsReadOnly {
                status = Self.newerEditNotSaved
            } else if EditStack.isDefault(parameters, relativeTo: defaultParameters) {
                onEditSettled?(id, nil)
            } else {
                let stack = stackWithProvenance()
                do {
                    onEditSettled?(id, try stack.encodeJSON())
                } catch {
                    reportFailure("Encoding the edit", error)
                }
            }
        }
        recordHistoryStep()
    }

    static let newerEditNotSaved = "Not saved: this photo was edited with a newer version of Latent"

    /// The edit as it is stored: the parameters plus which lens profile
    /// and Lensfun database version produced the corrections (DESIGN.md
    /// §5.6), so every save path records it, not just the debounced one.
    func stackWithProvenance() -> EditStack {
        var stack = EditStack(parameters: parameters)
        if let lens = session?.lensCorrection(for: parameters) {
            stack.setLensProvenance(profile: lens.profileName, databaseVersion: lens.databaseVersion)
        }
        return stack
    }

    /// A stack from storage or the clipboard, with any geometry from before
    /// the active-area change moved onto the open image's sensor plane.
    func onThisImage(_ stack: EditStack) -> EditStack {
        session.map { $0.stackForThisImage(stack) } ?? stack
    }

    // MARK: - History (undo / redo) and snapshots

    var canUndo: Bool { hasImage && history.canUndo }
    var canRedo: Bool { hasImage && history.canRedo }

    /// Loads stored history/snapshots after an image opens. The current
    /// edit becomes the cursor position (appended if it isn't the last
    /// stored step, e.g. the sidecar was edited elsewhere).
    func loadHistory(steps: [(stackJSON: String, createdAt: Int64)],
                     snapshots stored: [(name: String, stackJSON: String)]) {
        // Stored steps are converted like the current edit was when the
        // image opened, so undo never steps back into the old geometry.
        // A step or snapshot from a newer build can't be read here: the
        // image's stored state becomes read-only. Any other row this version
        // can't read is kept aside and written back with the rest, so saving
        // the next step does not delete it.
        var foundNewer = false
        func read(_ json: String) -> EditStack? {
            do {
                return onThisImage(try EditStack.decode(json: json))
            } catch EditStack.DecodeError.newerSchema {
                foundNewer = true
                return nil
            } catch {
                return nil
            }
        }
        var unreadSteps: [(stackJSON: String, createdAt: Int64)] = []
        var entries: [EditHistory.Step] = steps.compactMap { step in
            guard let stack = read(step.stackJSON) else {
                unreadSteps.append(step)
                return nil
            }
            return EditHistory.Step(stack: stack, label: "", date: Date(timeIntervalSince1970: Double(step.createdAt) / 1000))
        }
        // Labels are derived, not stored.
        for i in entries.indices {
            entries[i].label = i == 0 ? "Original"
                : EditHistory.describeChange(from: entries[i - 1].stack, to: entries[i].stack)
        }
        let current = EditStack(parameters: parameters)
        if entries.isEmpty { entries = [EditHistory.Step(stack: EditStack(parameters: defaultParameters), label: "Original")] }
        var h = EditHistory(steps: entries, cursor: entries.count - 1)
        h.record(current)
        history = h
        var unreadSnapshots: [(name: String, stackJSON: String)] = []
        snapshots = stored.compactMap { s in
            guard let stack = read(s.stackJSON) else {
                unreadSnapshots.append(s)
                return nil
            }
            return EditSnapshot(name: s.name, stack: stack)
        }
        if foundNewer, let id = catalogImageID, newerEditImageID != id {
            pendingSave?.cancel(); pendingSave = nil
            newerEditImageID = id
            status = "Some of this photo's history was made with a newer version of Latent; changes here won't be saved"
        }
        undecodableHistorySteps = unreadSteps
        undecodableSnapshots = unreadSnapshots
        storedHistoryLoaded = true
        if !foundNewer, !unreadSteps.isEmpty || !unreadSnapshots.isEmpty {
            status = "Some stored history or snapshots could not be read; they are kept as they are"
        }
    }

    /// The stored history of catalog image `id`, read after asking for it
    /// to open. Loaded now if that image is the open one; parked if its
    /// open is waiting for the GPU, so the history is not lost and its
    /// steps and snapshots are still written for the session; dropped if
    /// another image has been asked for since.
    func loadHistory(steps: [(stackJSON: String, createdAt: Int64)],
                     snapshots stored: [(name: String, stackJSON: String)],
                     forImage id: Int64?) {
        if openWhenGPUReady != nil {
            if deferredOpenCatalogImageID == id { deferredHistory = (steps, stored) }
        } else if catalogImageID == id {
            loadHistory(steps: steps, snapshots: stored)
        }
    }

    /// After a deferred open: the history that arrived while it waited.
    func loadDeferredHistory() {
        let parked = deferredHistory
        let id = deferredOpenCatalogImageID
        deferredHistory = nil
        deferredOpenCatalogImageID = nil
        guard let parked, catalogImageID == id else { return }
        loadHistory(steps: parked.steps, snapshots: parked.snapshots)
    }

    /// Called when an edit settles: records a step and persists.
    private func recordHistoryStep() {
        guard !restoringState else { return }
        if history.record(EditStack(parameters: parameters)) { persistHistory() }
    }

    private func persistHistory() {
        guard let id = catalogImageID, !storedEditIsReadOnly else { return }
        // The stored list was never read (it is still loading, or reading
        // it failed): writing ours would replace it with a shorter one.
        guard storedHistoryLoaded else { return }
        var steps = history.steps.compactMap { step -> (stackJSON: String, createdAt: Int64)? in
            guard let json = try? step.stack.encodeJSON() else { return nil }
            return (json, Int64(step.date.timeIntervalSince1970 * 1000))
        }
        if !undecodableHistorySteps.isEmpty {
            steps = (undecodableHistorySteps + steps).sorted { $0.createdAt < $1.createdAt }
        }
        onHistoryChanged?(id, steps)
    }

    private func restore(_ stack: EditStack) {
        restoringState = true
        var next = stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        let before = parameters
        let selectedBefore = selectedLocal?.id
        parameters = next
        restoringState = false
        toolStateDidFollowRestore(selectedBefore: selectedBefore)
        // The session's model-made mask pixels follow the stored shapes.
        syncModelMasks(from: before)
        // The stored edit must follow the cursor, so save without waiting.
        pendingSave?.cancel(); pendingSave = nil
        if storedEditIsReadOnly {
            status = Self.newerEditNotSaved
        } else if let id = catalogImageID {
            let isDefault = EditStack.isDefault(parameters, relativeTo: defaultParameters)
            do {
                onEditSettled?(id, isDefault ? nil : try stackWithProvenance().encodeJSON())
            } catch {
                reportFailure("Encoding the edit", error)
            }
        }
        persistHistory()
    }

    // History belongs to the open image; with none open there is nothing
    // it could be restored onto.
    // An edit still waiting in the save debounce is not a step yet: it is
    // recorded first, so Undo takes back that edit alone and Redo can
    // bring it back.
    func undo() {
        guard hasImage else { return }
        flushPendingSave()
        if let stack = history.undo() { restore(stack) }
    }
    func redo() {
        guard hasImage else { return }
        flushPendingSave()
        if let stack = history.redo() { restore(stack) }
    }
    /// `index` is the row the History panel drew, in the list as it was
    /// before the flush. Recording the pending change can drop the oldest
    /// step (at the cap) or the undone ones, so the row is found again by
    /// its id; a click on a row the flush removed does nothing.
    func jumpToHistory(index: Int) {
        guard hasImage, history.steps.indices.contains(index) else { return }
        let clicked = history.steps[index].id
        flushPendingSave()
        guard let now = history.steps.firstIndex(where: { $0.id == clicked }) else { return }
        if let stack = history.jump(to: now) { restore(stack) }
    }

    /// After Undo, Redo, a jump or a snapshot. The crop the straighten
    /// slider started from is gone, and when another local now sits at
    /// the selected index, an armed mask tool would reshape that one.
    private func toolStateDidFollowRestore(selectedBefore: UUID?) {
        straightenBase = nil
        if selectedLocal?.id != selectedBefore {
            maskTool = .none
            isDraggingMask = false
        }
    }

    func saveSnapshot(named name: String) {
        guard hasImage, !name.isEmpty else { return }
        snapshots.removeAll { $0.name == name }
        undecodableSnapshots.removeAll { $0.name == name }
        snapshots.append(EditSnapshot(name: name, stack: EditStack(parameters: parameters)))
        snapshots.sort { $0.name.lowercased() < $1.name.lowercased() }
        persistSnapshots()
        status = catalogImageID == nil || storedHistoryLoaded ? "Saved snapshot “\(name)”"
            : "Snapshot “\(name)” is kept for this session only: the stored snapshots could not be read"
    }

    func restoreSnapshot(_ snapshot: EditSnapshot) {
        guard hasImage else { return }
        // A pending edit becomes its own step, not lost under the snapshot.
        flushPendingSave()
        restoringState = true
        var next = snapshot.stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        let before = parameters
        let selectedBefore = selectedLocal?.id
        parameters = next
        restoringState = false
        toolStateDidFollowRestore(selectedBefore: selectedBefore)
        syncModelMasks(from: before)
        recordHistoryStep()   // restoring a snapshot is itself a history step
        scheduleSave()
    }

    func deleteSnapshot(_ snapshot: EditSnapshot) {
        snapshots.removeAll { $0.name == snapshot.name }
        undecodableSnapshots.removeAll { $0.name == snapshot.name }
        persistSnapshots()
    }

    private func persistSnapshots() {
        guard let id = catalogImageID, !storedEditIsReadOnly else { return }
        // As for history: the stored list must be read before it is replaced.
        guard storedHistoryLoaded else { return }
        var rows = snapshots.compactMap { s in
            (try? s.stack.encodeJSON()).map { (name: s.name, stackJSON: $0) }
        }
        // Unreadable ones stay, unless one of the same name replaced it
        // or was deleted under that name.
        rows += undecodableSnapshots.filter { old in !rows.contains { $0.name == old.name } }
        onSnapshotsChanged?(id, rows)
    }
}
