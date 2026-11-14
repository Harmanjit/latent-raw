import Foundation
import Catalog
import PixelEngine

/// How a preset is put on photos, as darktable's styles offer it.
enum PresetApplyMode: Equatable, Sendable {
    /// Over each photo's edit: Apply Preset as it has always been.
    case append
    /// From each photo's default edit, so nothing of the old edit remains
    /// but what the preset sets (Option in an Apply Preset menu).
    case overwrite
    /// On a new virtual copy of each photo, leaving the originals alone.
    case virtualCopy
}

/// Applies a preset with a mode other than plain Append (which stays
/// ContentView's `applyPresetToSelection`): to the open photo in Develop,
/// to the selection elsewhere, each through the Library's undoable batch
/// paths, as Apply Preset does.
@MainActor
struct PresetApplier {
    let library: Library
    let model: EditorModel
    let mode: AppMode
    /// Opens a record in the editor, for a copy made from the photo shown.
    let open: @MainActor (ImageRecord) -> Void
    /// Plain Append, the existing path.
    let append: @MainActor (Preset) -> Void

    func apply(_ preset: Preset, mode applyMode: PresetApplyMode) {
        switch applyMode {
        case .append: append(preset)
        case .overwrite: overwrite(preset)
        case .virtualCopy: applyAsVirtualCopy(preset)
        }
    }

    /// The stack Overwrite gives a photo: its default edit with the preset
    /// applied at the panel's Amount.
    static func overwritten(with preset: EditStack, groups: Set<EditGroup>, amount: Float,
                            defaults: EditParameters = EditParameters()) -> EditStack {
        EditStack().applying(preset, groups: groups, amount: amount, defaults: defaults)
    }

    private var target: ContentView.SettingsTarget {
        ContentView.SettingsTarget.choose(mode: mode, editorHasImage: model.hasImage)
    }

    private func overwrite(_ preset: Preset) {
        let amount = PresetAmountSession.amount
        let target = target
        let model = model
        let editorStack: @MainActor () -> EditStack = {
            Self.overwritten(with: model.onThisImage(preset.stack), groups: preset.groups, amount: amount,
                             defaults: model.defaultParameters)
        }
        if target == .editor {
            model.apply(editorStack(), groups: Set(EditGroup.allCases))
            model.status = "Applied preset “\(preset.name)” (Overwrite)"
            return
        }
        model.flushPendingSave()
        let library = library
        let what = "Applied “\(preset.name)” (Overwrite) —"
        library.perform(what) {
            let outcome = try await library.transformSelectedEdits(
                onlyPrimary: target == .primary,
                schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion,
                undoName: "Apply Preset (Overwrite)"
            ) { existing in
                // An unreadable edit is skipped, as Apply Preset skips it.
                if let existing { _ = try EditStack.decode(json: existing) }
                let next = Self.overwritten(with: preset.stack, groups: preset.groups, amount: amount)
                return next == EditStack() ? nil : try next.encodeJSON()
            }
            // The editor holding one of them shows the new edit, rather
            // than saving its old one over it later.
            if let open = model.catalogImageID,
               target == .primary ? library.selectedImageID == open : library.selectedImageIDs.contains(open) {
                model.apply(editorStack(), groups: Set(EditGroup.allCases))
            }
            Self.announce(what, outcome)
        }
    }

    /// One new virtual copy of each target, then the preset on the copies:
    /// a single undo takes both back.
    private func applyAsVirtualCopy(_ preset: Preset) {
        let inGrid = mode == .library
        // Develop may hold a file opened on its own, which has no catalog
        // entry to copy: only the photo shown, when it is the selection's.
        if mode == .develop, model.hasImage, model.catalogImageID == nil || model.catalogImageID != library.selectedImageID {
            model.status = "A virtual copy needs a photo from the open folder"
            return
        }
        let targets = library.batchTargets(onlyPrimary: !inGrid).filter { $0.id != nil }
        guard !targets.isEmpty else { return }
        model.flushPendingSave()
        let library = library, open = open
        let amount = PresetAmountSession.amount
        let what = "Applied “\(preset.name)” as new virtual copies —"
        library.perform(what) {
            let manager = library.undoManager
            let ownGroup = manager.map { $0.groupingLevel == 0 } ?? false
            let groupsByEvent = manager?.groupsByEvent ?? true
            if ownGroup {
                manager?.groupsByEvent = false
                manager?.beginUndoGrouping()
            }
            defer {
                if ownGroup {
                    manager?.setActionName(targets.count == 1 ? "Apply Preset as Virtual Copy"
                                           : "Apply Preset as Virtual Copies")
                    manager?.endUndoGrouping()
                    manager?.groupsByEvent = groupsByEvent
                }
            }
            // The new copies end up selected, so the batch takes them.
            let ids = try await library.createVirtualCopies(of: targets)
            guard !ids.isEmpty else { return }
            let outcome = try await library.transformSelectedEdits(
                onlyPrimary: false,
                schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion,
                undoName: "Apply Preset"
            ) { existing in
                let current = try existing.map { try EditStack.decode(json: $0) } ?? EditStack()
                let merged = current.applying(preset.stack, groups: preset.groups, amount: amount)
                return merged == EditStack() ? nil : try merged.encodeJSON()
            }
            Self.announce(what, outcome)
            if !inGrid, let first = ids.first, let record = library.images.first(where: { $0.id == first }) {
                open(record)
            }
        }
    }

    private static func announce(_ what: String, _ outcome: Library.TransformOutcome) {
        let n = outcome.changed
        var message = "\(what) settings to \(n) image\(n == 1 ? "" : "s")"
        if !outcome.skipped.isEmpty {
            message += " · skipped \(outcome.skipped.count) with unreadable edits: " + outcome.skipped.joined(separator: ", ")
        }
        Announcement.post(message)
    }
}
