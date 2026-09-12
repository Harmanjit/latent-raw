import SwiftUI
import Catalog

/// The left-hand panel: which folder is open and how the scan is going.
/// Collections, presets and the navigator arrive here in later phases.
struct LibraryPanel: View {
    @ObservedObject var library: Library
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Folder")
            if let url = library.folderURL {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                Text("\(library.images.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No folder open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Open Folder…", action: onOpenFolder)
                .controlSize(.small)
                .keyboardShortcut("o", modifiers: [.command, .shift])

            if library.isBusy {
                ProgressView().controlSize(.small)
            }

            if library.thumbnailsTotal > 0 && library.thumbnailsDone < library.thumbnailsTotal {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thumbnails \(library.thumbnailsDone) of \(library.thumbnailsTotal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(library.thumbnailsDone),
                                 total: Double(library.thumbnailsTotal))
                        .controlSize(.small)
                }
            }

            if !library.undecidedSubfolders.isEmpty {
                subfolderPrompt
            }

            Spacer()
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
    }

    /// DESIGN.md §5.2: a subfolder with no recorded mode is asked about
    /// rather than silently swallowed or ignored.
    private var subfolderPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Subfolders found")
            ForEach(library.undecidedSubfolders, id: \.self) { name in
                Text(name).font(.caption).lineLimit(1)
            }
            Text("Include them in this catalog, or keep them as separate catalogs of their own?")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Include") { decide(true) }
                Button("Keep separate") { decide(false) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func decide(_ include: Bool) {
        Task { try? await library.decideUndecidedSubfolders(include: include) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
