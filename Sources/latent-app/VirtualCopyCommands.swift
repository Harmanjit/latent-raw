import Foundation
import Catalog

/// Photo › Create Virtual Copy (⌘'), Set Copy as Master and Remove Virtual
/// Copy, and File › Duplicate, as the menus, the key and the grid's context
/// menu ask for them. The work is the Library's (Library+VirtualCopies,
/// LibraryFileOperations.duplicate); this picks the images and keeps the
/// editor in step.
@MainActor
struct VirtualCopyCommands {
    let library: Library
    let model: EditorModel
    /// The grid is showing: commands take the selection. Elsewhere they
    /// take the image on screen, as ratings do.
    let inGrid: Bool
    /// Opens a record in the editor, for a copy made from the image shown.
    let open: @MainActor (ImageRecord) -> Void

    func perform(_ command: KeyCommand) {
        switch command {
        case .createVirtualCopy: createVirtualCopy()
        case .setCopyAsMaster: setCopyAsMaster()
        case .removeVirtualCopy: removeVirtualCopies()
        case .duplicatePhoto: duplicate()
        default: break
        }
    }

    /// One new copy per target, selected; outside the grid the copy of the
    /// image shown opens in its place, as Lightroom does. The editor saves
    /// first, so the copy starts from the edit as it is on screen.
    private func createVirtualCopy() {
        let targets = library.batchTargets(onlyPrimary: !inGrid)
        guard !targets.isEmpty else { return }
        model.flushPendingSave()
        let library = library, inGrid = inGrid, open = open
        library.perform(targets.count == 1 ? "Creating a virtual copy" : "Creating virtual copies") {
            let ids = try await library.createVirtualCopies(of: targets)
            Announcement.post(ids.count == 1 ? "Virtual copy created" : "\(ids.count) virtual copies created")
            if !inGrid, let first = ids.first, let record = library.images.first(where: { $0.id == first }) {
                open(record)
            }
        }
    }

    /// The copy's settings and its master's change places.
    private func setCopyAsMaster() {
        guard let copy = library.selectedImage, copy.isVirtualCopy else { return }
        model.flushPendingSave()
        let library = library
        library.perform("Set Copy as Master") {
            try await library.setCopyAsMaster(copy)
            Announcement.post("\(copy.sourceFileName) now has the copy’s settings")
        }
    }

    /// The copies among the targets leave the catalog; masters stay. Undo
    /// puts them back. The editor closes a copy it shows first (wired in
    /// ContentView through `Library.willRemoveImages`).
    private func removeVirtualCopies() {
        let copies = library.batchTargets(onlyPrimary: !inGrid).filter(\.isVirtualCopy)
        guard !copies.isEmpty else { return }
        let library = library, inGrid = inGrid, open = open
        library.perform(copies.count == 1 ? "Removing a virtual copy" : "Removing virtual copies") {
            try await library.removeVirtualCopies(copies)
            Announcement.post(copies.count == 1 ? "Virtual copy removed" : "\(copies.count) virtual copies removed")
            // Loupe and Develop show the master in the copy's place.
            if !inGrid, let master = library.selectedImage { open(master) }
        }
    }

    /// A true copy of each selected file beside it ("DSC_0107 2.NEF").
    private func duplicate() {
        let selected = library.selectedImages
        let records = selected.isEmpty ? (library.selectedImage.map { [$0] } ?? []) : selected
        guard !records.isEmpty else { return }
        let library = library
        Task {
            let report = await library.fileOperations.duplicate(records)
            if !report.failures.isEmpty {
                library.lastError = LibraryFileCommands.failureSummary(report, mode: .copy)
            }
            let done = report.completed.count
            Announcement.post(done == 1 ? "Duplicated 1 image" : "Duplicated \(done) images")
        }
    }
}
