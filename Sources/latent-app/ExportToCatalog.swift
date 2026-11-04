import SwiftUI
import Catalog

/// Where an export added to the catalog goes in its original's stack:
/// nowhere, just above it, or just below it (Lightroom's Add to Stack).
enum ExportStackPlacement: String, Codable, CaseIterable {
    case off, above, below

    var title: String {
        switch self {
        case .off: "Don't stack"
        case .above: "Above original"
        case .below: "Below original"
        }
    }

    var placement: Library.ExportedFile.Placement {
        switch self {
        case .off: .unstacked
        case .above: .above
        case .below: .below
        }
    }
}

extension ExportPreset {
    /// The file an export just wrote, for Add to This Catalog; nil when the
    /// option is off. Copies of the original file stay out: they are the
    /// same photo again, which a catalog would only show twice.
    func exportedFile(_ url: URL, from record: ImageRecord) -> Library.ExportedFile? {
        guard addToCatalog, fileKind != .original, let id = record.id else { return nil }
        return Library.ExportedFile(url: url, sourceID: id, placement: stackWithOriginal.placement)
    }
}

/// Add to This Catalog: once an export finishes, the files it wrote inside
/// the open folder are indexed at once (not when the folder watcher next
/// notices them), stacked with their originals if asked, and selected.
@MainActor
enum ExportToCatalog {
    static func add(_ files: [Library.ExportedFile], to library: Library) {
        library.perform("Adding exported files to the catalog") {
            let report = try await library.addExportedFiles(files)
            if report.outside > 0 {
                let what = report.outside == 1 ? "1 exported file isn’t" : "\(report.outside) exported files aren’t"
                library.lastError = "\(what) in the open folder (or in a subfolder it includes), so it wasn’t "
                    + "added to the catalog."
            }
            if report.added > 0 {
                Announcement.post(report.added == 1 ? "Added 1 exported file to the catalog"
                                  : "Added \(report.added) exported files to the catalog")
            }
        }
    }
}

/// The export sheet's Add to This Catalog switch and its stacking choice.
struct ExportCatalogSection: View {
    @Binding var preset: ExportPreset

    var body: some View {
        HStack {
            Toggle("Add to this catalog", isOn: $preset.addToCatalog)
                .disabled(preset.fileKind == .original)
                .help("Indexes the exported files as soon as they are written, when they land in the open folder "
                      + "or a subfolder it includes, and selects them.")
            Picker("Stack", selection: $preset.stackWithOriginal) {
                ForEach(ExportStackPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 220)
            .disabled(!preset.addToCatalog || preset.fileKind == .original)
            .accessibilityLabel("Add to stack with original")
            .help("Stacks each exported file with the photo it came from, just above or below it.")
            Spacer()
        }
    }
}
