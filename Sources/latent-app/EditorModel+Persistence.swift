import Foundation
import PixelEngine

extension EditorModel {
    // MARK: - Saving

    /// Persists ~1s after the last change (DESIGN.md §5.3: nothing is
    /// written while a slider is being dragged).
    func scheduleSave() {
        guard catalogImageID != nil else { return }
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
        guard let id = catalogImageID, let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
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
        recordHistoryStep()
    }

    static let newerEditNotSaved = "Not saved: this photo was edited with a newer version of Latent"

    /// The edit as it is stored: the parameters plus which lens profile
    /// and Lensfun database version produced the corrections (DESIGN.md
    /// §5.6), so every save path records it, not just the debounced one.
    func stackWithProvenance() -> EditStack {
        var stack = EditStack(parameters: parameters)
        if let lens = session?.lensCorrection {
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
        // A step or snapshot from a newer build can't be read here, and the
        // next persist would rewrite the stored list without it, so the
        // image's stored state becomes read-only instead.
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
        var entries: [EditHistory.Step] = steps.compactMap { step in
            guard let stack = read(step.stackJSON) else { return nil }
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
        snapshots = stored.compactMap { s in
            read(s.stackJSON).map { EditSnapshot(name: s.name, stack: $0) }
        }
        if foundNewer, let id = catalogImageID, newerEditImageID != id {
            pendingSave?.cancel(); pendingSave = nil
            newerEditImageID = id
            status = "Some of this photo's history was made with a newer version of Latent; changes here won't be saved"
        }
    }

    /// Called when an edit settles: records a step and persists.
    private func recordHistoryStep() {
        guard !restoringState else { return }
        if history.record(EditStack(parameters: parameters)) { persistHistory() }
    }

    private func persistHistory() {
        guard let id = catalogImageID, !storedEditIsReadOnly else { return }
        let steps = history.steps.compactMap { step -> (String, Int64)? in
            guard let json = try? step.stack.encodeJSON() else { return nil }
            return (json, Int64(step.date.timeIntervalSince1970 * 1000))
        }
        onHistoryChanged?(id, steps)
    }

    private func restore(_ stack: EditStack) {
        restoringState = true
        var next = stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        let before = parameters
        parameters = next
        restoringState = false
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
    func undo() { if hasImage, let stack = history.undo() { restore(stack) } }
    func redo() { if hasImage, let stack = history.redo() { restore(stack) } }
    func jumpToHistory(index: Int) { if hasImage, let stack = history.jump(to: index) { restore(stack) } }

    func saveSnapshot(named name: String) {
        guard hasImage, !name.isEmpty else { return }
        snapshots.removeAll { $0.name == name }
        snapshots.append(EditSnapshot(name: name, stack: EditStack(parameters: parameters)))
        snapshots.sort { $0.name.lowercased() < $1.name.lowercased() }
        persistSnapshots()
        status = "Saved snapshot “\(name)”"
    }

    func restoreSnapshot(_ snapshot: EditSnapshot) {
        guard hasImage else { return }
        restoringState = true
        var next = snapshot.stack.parameters(defaults: defaultParameters)
        if next.whiteBalance.isAsShot { next.whiteBalance = defaultParameters.whiteBalance }
        let before = parameters
        parameters = next
        restoringState = false
        syncModelMasks(from: before)
        recordHistoryStep()   // restoring a snapshot is itself a history step
        scheduleSave()
    }

    func deleteSnapshot(_ snapshot: EditSnapshot) {
        snapshots.removeAll { $0.name == snapshot.name }
        persistSnapshots()
    }

    private func persistSnapshots() {
        guard let id = catalogImageID, !storedEditIsReadOnly else { return }
        onSnapshotsChanged?(id, snapshots.compactMap { s in
            (try? s.stack.encodeJSON()).map { (s.name, $0) }
        })
    }
}
