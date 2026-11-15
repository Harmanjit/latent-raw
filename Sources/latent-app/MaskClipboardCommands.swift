import SwiftUI
import Catalog
import PixelEngine

/// Develop › Masks › Copy Mask, Paste Mask and Paste Mask to Selection,
/// also on a mask row's context menu in Local Adjustments. One
/// `KeyCommand` case, menu-only (no default key).
enum MaskClipboardCommand: Equatable, Sendable, CaseIterable {
    /// The selected mask (or the row right-clicked) onto the mask clipboard.
    case copy
    /// The copied mask added to the open photo as a new mask.
    case paste
    /// The copied mask added to every selected photo's stored edit.
    case pasteToSelection

    var title: String {
        switch self {
        case .copy: "Copy Mask"
        case .paste: "Paste Mask"
        case .pasteToSelection: "Paste Mask to Selection"
        }
    }
}

extension CommandState {
    func isEnabled(_ command: MaskClipboardCommand) -> Bool {
        switch command {
        case .copy: mode == .develop && hasSelectedMask
        // Adds a mask, so as New…: the open photo with room for one more.
        case .paste: mode == .develop && canAddMask && hasCopiedMask
        // Stored edits, as Paste Settings writes them in the grid; Survey's
        // panes are never written.
        case .pasteToSelection: selectionCount > 0 && hasCopiedMask && mode != .survey
        }
    }
}

/// The mask clipboard, shared by the whole app so a mask copied from one
/// photo can be pasted onto any other. In memory only: a mask is not text
/// another app could use, and Copy Settings keeps the system pasteboard.
@MainActor
final class MaskClipboard: ObservableObject {
    static let shared = MaskClipboard()
    @Published var copied: CopiedMask?
}

extension EditorModel {
    /// Copy Mask: the mask at `index` (the selected one when nil) onto the
    /// mask clipboard, less any linked component, which the status names.
    func copyMask(at index: Int? = nil, to clipboard: MaskClipboard = .shared) {
        guard let i = index ?? selectedLocalIndex, parameters.locals.indices.contains(i) else { return }
        let copied = CopiedMask(parameters.locals[i])
        clipboard.copied = copied
        var message = "Copied mask “\(copied.mask.name)”"
        if !copied.skipped.isEmpty {
            message += " · left out " + copied.skipped.map(\.name).joined(separator: ", ")
                + " (it uses another mask of this photo)"
        }
        status = message
    }

    /// Paste Mask: adds the copied mask to this photo as a new mask (never
    /// replacing one), selects it, and has any model-made part generated
    /// from this photo's pixels. One history step, so Undo takes it back.
    /// False when nothing is copied, there is no image or no room.
    @discardableResult
    func pasteMask(from clipboard: MaskClipboard = .shared) -> Bool {
        guard let copied = clipboard.copied else { status = "No mask copied"; return false }
        guard addPastedMask(copied.instance()) else { return false }
        status = copied.pasteMessage(added: 1, full: 0)
        return true
    }

    /// Appends `local` as a new mask and selects it; false (with a status)
    /// when the photo already has as many masks as it may.
    @discardableResult
    func addPastedMask(_ local: LocalAdjustment) -> Bool {
        guard hasImage else { return false }
        guard let locals = CopiedMask.adding(local, to: parameters.locals) else {
            status = "A photo can have at most \(LocalAdjustment.maximumCount) masks"
            return false
        }
        parameters.locals = locals
        selectedLocalIndex = locals.count - 1
        regenerateMissingAIMasks()
        return true
    }
}

/// Runs a `MaskClipboardCommand`. Paste Mask to Selection writes each
/// selected photo's stored edit as Sync Last Change and Paste Settings do
/// (`Library.transformSelectedEdits`): one Library undo, under "Paste Mask
/// to Selection", puts back every photo it changed. Model-made parts are
/// generated on each photo when it is opened, as for any stored edit.
@MainActor
struct MaskClipboardCommands {
    let library: Library
    let model: EditorModel
    let report: @MainActor (String) -> Void
    var clipboard: MaskClipboard = .shared

    func perform(_ command: MaskClipboardCommand) {
        switch command {
        case .copy: model.copyMask(to: clipboard)
        case .paste: model.pasteMask(from: clipboard)
        case .pasteToSelection: pasteToSelection()
        }
    }

    private func pasteToSelection() {
        guard let copied = clipboard.copied else { report("No mask copied"); return }
        guard !library.selectedImageIDs.isEmpty else { report("Select the photos to paste the mask to"); return }
        // One instance for every photo: ids need only be unique within a
        // photo's edit, and the editor's photo then holds the same mask
        // its stored edit was given.
        let local = copied.instance()
        model.flushPendingSave()
        let library = library, model = model, report = report
        Task {
            // The editor's save lands first, so the write below starts from
            // the edit it shows.
            await library.waitForPendingWork()
            library.perform("Pasting a mask") {
                var full = 0
                let outcome = try await library.transformSelectedEdits(
                    schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion,
                    undoName: "Paste Mask to Selection"
                ) { existing in
                    switch try CopiedMask.pasted(local, ontoStored: existing) {
                    case .added(let json): return json
                    case .full: full += 1; return existing
                    }
                }
                report(copied.pasteMessage(added: outcome.changed, full: full, skippedUnreadable: outcome.skipped))
                // The editor may hold one of them: it shows the new mask
                // (and makes its model parts) rather than saving over it.
                if let held = model.catalogImageID, model.hasImage, library.selectedImageIDs.contains(held),
                   !model.parameters.locals.contains(where: { $0.id == local.id }) {
                    let status = model.status
                    model.addPastedMask(local)
                    model.status = status
                }
            }
        }
    }
}
