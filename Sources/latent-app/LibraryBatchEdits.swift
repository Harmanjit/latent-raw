import AppKit
import Catalog
import ImageIO
import PixelEngine
import UniformTypeIdentifiers

// MARK: - Commands

/// Edit and Photo menu commands that act on the edits of the selection or
/// the open photo as a batch: Reset Edits, Sync Last Change to Selection,
/// Paste Settings (Overwrite), Copy Settings… and Paste Settings…, Load
/// Settings from File…, and New Blank Copy. One `KeyCommand` case, so the
/// tables they pass through each gain one line (as `ViewCommand` does).
enum HistoryCommand: Equatable, CaseIterable {
    /// Photo › Reset Edits: the default edit on every target.
    case resetEdits
    /// Edit › Sync Last Change to Selection: the groups the lead photo's
    /// last history step changed, from its edit to the rest of the selection.
    case syncLastChange
    /// Edit › Paste Settings (Overwrite): the targets start from their
    /// defaults, then take the clipboard's groups.
    case pasteOverwrite
    /// Edit › Copy Settings… and Paste Settings…: a checklist of groups first.
    case copySelective, pasteSelective
    /// File › Load Settings from File…: a Latent sidecar or an image that
    /// carries Latent's edit.
    case loadSettingsFromFile
    /// Photo › New Blank Copy, and the Versions panel's button: a virtual
    /// copy with the default edit.
    case newBlankCopy

    var title: String {
        switch self {
        case .resetEdits: "Reset Edits"
        case .syncLastChange: "Sync Last Change to Selection"
        case .pasteOverwrite: "Paste Settings (Overwrite)"
        case .copySelective: "Copy Settings…"
        case .pasteSelective: "Paste Settings…"
        case .loadSettingsFromFile: "Load Settings from File…"
        case .newBlankCopy: "New Blank Copy"
        }
    }
}

extension CommandState {
    func isEnabled(_ command: HistoryCommand) -> Bool {
        switch command {
        // As Paste Settings: the open photo, or the selection.
        case .resetEdits, .pasteOverwrite, .pasteSelective, .loadSettingsFromFile: hasImage || selectionCount > 0
        case .copySelective: hasImage || hasSelection
        // A lead to sync from and at least one photo to sync to.
        case .syncLastChange: selectionCount >= 2 && mode != .survey
        // As Create Virtual Copy.
        case .newBlankCopy: hasSelection && mode != .survey && !fileOperationRunning
        }
    }
}

/// Runs a `HistoryCommand`. ContentView supplies the paths it owns: where
/// settings go (`applyToSelectionOrEditor`, which files one Library undo
/// or one history step), how outcomes are reported, the selective sheet and
/// opening a photo.
@MainActor
struct HistoryCommands {
    let library: Library
    let model: EditorModel
    let mode: AppMode
    /// `stack`'s `groups` onto the selection or the open photo; `overwrite`
    /// starts each from its defaults first.
    let apply: @MainActor (_ stack: EditStack, _ groups: Set<EditGroup>, _ overwrite: Bool,
                           _ what: String, _ undoName: String) -> Void
    let report: @MainActor (String) -> Void
    let present: @MainActor (SelectiveSettingsRequest) -> Void
    let open: @MainActor (ImageRecord) -> Void

    func perform(_ command: HistoryCommand) {
        switch command {
        case .resetEdits:
            // No groups from an empty stack over the defaults: the defaults.
            apply(EditStack(), [], true, "Reset", "Reset Edits")
        case .pasteOverwrite:
            guard let stack = EditorModel.clipboardStack() else { report("Nothing to paste"); return }
            apply(stack, model.pasteGroups, true, "Pasted (overwriting)", "Paste Settings (Overwrite)")
        case .copySelective:
            present(SelectiveSettingsRequest(purpose: .copy) { groups in copy(groups) })
        case .pasteSelective:
            guard let stack = EditorModel.clipboardStack() else { report("Nothing to paste"); return }
            present(SelectiveSettingsRequest(purpose: .paste, available: stack.presentGroups) { groups in
                apply(stack, groups, false, "Pasted", "Paste Settings")
            })
        case .loadSettingsFromFile:
            chooseSettingsFile()
        case .syncLastChange:
            syncLastChange()
        case .newBlankCopy:
            newBlankCopy()
        }
    }

    // MARK: Copy Settings…

    /// The chosen groups of the open photo's edit, or in the grid of the
    /// lead photo's stored edit, as Copy Settings decides.
    private func copy(_ groups: Set<EditGroup>) {
        let n = groups.count
        let copied = "Copied \(n) group\(n == 1 ? "" : "s") of settings"
        if mode == .develop || (library.selectedImageIDs.count <= 1 && model.catalogImageID == library.selectedImageID),
           model.hasImage {
            if EditorModel.putOnPasteboard(EditStack(parameters: model.parameters), groups: groups) { report(copied) }
            return
        }
        guard let lead = library.selectedImage else { return }
        let library = library, model = model, report = report
        Task {
            do {
                let stack = try await library.editStack(for: lead).map { try EditStack.decode(json: $0) } ?? EditStack()
                if EditorModel.putOnPasteboard(stack, groups: groups) { report(copied + " from \(lead.fileName)") }
            } catch {
                model.reportFailure("Copying settings from \(lead.fileName)", error)
            }
        }
    }

    // MARK: Load Settings from File…

    private func chooseSettingsFile() {
        let panel = NSOpenPanel()
        panel.title = "Load Settings from File"
        panel.message = "Choose a Latent sidecar (.xmp), or an image that carries Latent’s edit."
        panel.prompt = "Load"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SettingsFile.contentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stack: EditStack
        do {
            stack = try SettingsFile.editStack(at: url)
        } catch {
            report("\(url.lastPathComponent): \(error)")
            return
        }
        let apply = apply
        present(SelectiveSettingsRequest(purpose: .load(url.lastPathComponent), available: stack.presentGroups) { groups in
            apply(stack, groups, false, "Loaded \(url.lastPathComponent)’s", "Load Settings from File")
        })
    }

    // MARK: Sync Last Change to Selection

    /// The lead photo's last step, the groups it changed, from the lead's
    /// edit as it is now to every other selected photo, as one Library undo.
    /// The lead itself is never written. Works in Develop too, where the
    /// filmstrip's selection is the target (Undo there is the editor's, so
    /// the Library's Undo takes the sync back once in the Library).
    private func syncLastChange() {
        guard let lead = library.selectedImage, let leadID = lead.id, library.selectedImageIDs.count >= 2 else {
            report("Select the photo to sync from, then the photos to sync to")
            return
        }
        // The editor's own history when it holds the lead: it has the step
        // just made, which may not be stored yet.
        let editorHoldsLead = model.hasImage && model.catalogImageID == leadID
        let editorSource: (stack: EditStack, groups: Set<EditGroup>)? = editorHoldsLead
            ? (EditStack(parameters: model.parameters), model.history.lastChangedGroups) : nil
        model.flushPendingSave()
        let library = library, model = model, report = report
        Task {
            // The editor's save of the lead lands first, so its stored edit
            // agrees with what is synced and is left alone.
            await library.waitForPendingWork()
            library.perform("Syncing the last change") {
                let source: (stack: EditStack, groups: Set<EditGroup>)
                if let editorSource {
                    source = editorSource
                } else {
                    let current = try await library.editStack(for: lead).map { try EditStack.decode(json: $0) }
                        ?? EditStack()
                    let steps = try await library.history(for: lead).compactMap { try? EditStack.decode(json: $0.stackJSON) }
                    source = (current, Self.lastChangedGroups(steps: steps, current: current))
                }
                guard !source.groups.isEmpty else {
                    report("\(lead.fileName) has no last change to sync")
                    return
                }
                let outcome = try await library.transformSelectedEdits(
                    schemaVersion: EditStack.schemaVersion, processVersion: EditStack.processVersion,
                    undoName: "Sync Last Change"
                ) { existing in
                    try Self.synced(existing, from: source.stack, groups: source.groups)
                }
                let n = outcome.changed
                let names = source.groups.map(\.shortName).sorted().joined(separator: ", ")
                var message = "Synced \(names) to \(n) image\(n == 1 ? "" : "s")"
                if !outcome.skipped.isEmpty {
                    message += " · skipped \(outcome.skipped.count) with unreadable edits: "
                        + outcome.skipped.joined(separator: ", ")
                }
                report(message)
                // The editor may hold another of them (the grid's last photo
                // opened): it shows the change rather than saving over it.
                if let held = model.catalogImageID, held != leadID, library.selectedImageIDs.contains(held), model.hasImage {
                    model.apply(source.stack, groups: source.groups)
                }
            }
        }
    }

    /// The groups the last stored step changed: the step into the stored
    /// edit when the history holds it (an undone step may follow), else the
    /// last step.
    nonisolated static func lastChangedGroups(steps: [EditStack], current: EditStack) -> Set<EditGroup> {
        guard steps.count >= 2 else { return [] }
        let index = steps.lastIndex(of: current) ?? steps.count - 1
        guard index >= 1 else { return [] }
        return EditHistory.changedGroups(from: steps[index - 1], to: steps[index])
    }

    /// One target's stored edit with `groups` from `source`; the same
    /// string when nothing changes (the lead, or a photo already in step),
    /// so it is not written.
    nonisolated static func synced(_ existing: String?, from source: EditStack, groups: Set<EditGroup>) throws -> String? {
        let current = try existing.map { try EditStack.decode(json: $0) } ?? EditStack()
        let merged = current.merged(with: source, groups: groups)
        if merged == current { return existing }
        return merged == EditStack() ? nil : try merged.encodeJSON()
    }

    // MARK: New Blank Copy

    /// A virtual copy with the default edit of each target; outside the
    /// grid it opens in the photo's place, as Create Virtual Copy's does.
    private func newBlankCopy() {
        let inGrid = mode == .library
        let targets = library.batchTargets(onlyPrimary: !inGrid)
        guard !targets.isEmpty else { return }
        model.flushPendingSave()
        let library = library, open = open
        library.perform(targets.count == 1 ? "Creating a blank copy" : "Creating blank copies") {
            let ids = try await library.createVirtualCopies(of: targets, blank: true)
            Announcement.post(ids.count == 1 ? "Blank copy created" : "\(ids.count) blank copies created")
            if !inGrid, let first = ids.first, let record = library.images.first(where: { $0.id == first }) {
                open(record)
            }
        }
    }

    // MARK: Grid

    /// The grid's context menu items, after Paste Settings.
    static func addGridItems(to menu: NSMenu, actions: GridActions) {
        for command in [HistoryCommand.pasteOverwrite, .syncLastChange, .resetEdits] {
            let key = KeyCommand.history(command)
            menu.addItem(ClosureMenuItem(command.title, enabled: actions.canRun(key)) { actions.command(key) })
        }
    }
}

extension EditGroup {
    /// The group's name without what its display name lists, for messages.
    var shortName: String {
        displayName.components(separatedBy: " (").first ?? displayName
    }
}

// MARK: - Settings files

/// Reads a Latent edit from a file for Load Settings from File…: a sidecar
/// Latent wrote (its `latent:EditStack`), or an image whose XMP carries the
/// same element.
enum SettingsFile {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case noSettings
        case unreadable

        var description: String {
            switch self {
            case .noSettings: "the file carries no Latent settings"
            case .unreadable: "the file could not be read"
            }
        }
    }

    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "xmp") ?? .xml, .xml, .image]
    }

    static func editStack(at url: URL) throws -> EditStack {
        let json: String
        if url.pathExtension.lowercased() == "xmp" {
            json = try XMPSidecar.read(from: url).editStackJSON
        } else {
            guard let xml = imageXMP(at: url) else { throw Failure.noSettings }
            json = editStackJSON(inXMP: xml) ?? ""
        }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noSettings }
        return try EditStack.decode(json: trimmed)
    }

    /// The image's XMP packet as ImageIO serialises it, if it has one.
    static func imageXMP(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The `EditStack` property anywhere in an XMP packet, written as an
    /// element (as Latent's sidecars write it) or an attribute (as ImageIO
    /// may serialise a simple property). External entities are never loaded.
    static func editStackJSON(inXMP xml: String) -> String? {
        guard xml.utf8.count <= XMPSidecar.maximumSidecarBytes,
              let document = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        if let element = (try? document.nodes(forXPath: "//*[local-name()='EditStack']"))?.first,
           let text = element.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let attribute = (try? document.nodes(forXPath: "//@*[local-name()='EditStack']"))?.first,
           let text = attribute.stringValue, !text.isEmpty {
            return text
        }
        return nil
    }
}
