import Foundation
import Catalog

/// File › Import Ratings and Keywords from Other Apps' Sidecars…: the
/// selected photos, or every photo shown when none is selected, fill the
/// stars, reject flag, label, keywords and descriptive fields they have
/// empty from darktable's or Lightroom's sidecars beside them. Those files
/// are only read. One undo step.
@MainActor
enum ForeignSidecarImportCommand {
    static func run(library: Library) {
        let records = library.selectedImageIDs.isEmpty ? library.visibleImages : library.batchTargets(onlyPrimary: false)
        guard !records.isEmpty else { return }
        library.perform("Importing from other apps’ sidecars") {
            let changed = try await library.importForeignSidecars(for: records)
            Announcement.post(message(changed: changed, of: records.count))
        }
    }

    static func message(changed: Int, of total: Int) -> String {
        switch changed {
        case 0: "No other app’s sidecar had anything to add to the \(total == 1 ? "photo" : "\(total) photos")"
        case 1: "Filled in 1 photo from another app’s sidecar"
        default: "Filled in \(changed) photos from other apps’ sidecars"
        }
    }
}
