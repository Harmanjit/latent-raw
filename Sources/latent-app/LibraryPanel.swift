import SwiftUI
import Catalog
import PixelEngine

/// The left-hand panel: which folder is open and how the scan is going.
/// Collections, presets and the navigator arrive here in later phases.
struct LibraryPanel: View {
    @ObservedObject var library: Library
    @ObservedObject var exportQueue: ExportQueue
    let onOpenFolder: () -> Void
    let onRate: (Int) -> Void
    let onFlag: (ImageFlag) -> Void
    let onExport: () -> Void
    let presets: [Preset]
    let onApplyPreset: (Preset) -> Void
    let onPaste: () -> Void

    @State private var keywordText = ""

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

            if let selected = library.selectedImage {
                selectionSection(selected)
            }

            exportSection

            Spacer()
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
        .onChange(of: library.selectedKeywords, initial: true) { _, keywords in
            keywordText = keywords.joined(separator: ", ")
        }
    }

    /// Export the selection, and how the current batch is going.
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Selection")
            let n = library.selectedImageIDs.count
            HStack {
                Menu("Apply preset") {
                    ForEach(presets) { preset in
                        Button(preset.name) { onApplyPreset(preset) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Paste settings", action: onPaste)
                    .help("Paste the copied settings onto every selected image (⌘⇧V)")
            }
            .controlSize(.small)
            .disabled(n == 0)
            Button(n <= 1 ? "Export…" : "Export \(n) images…", action: onExport)
                .controlSize(.small)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(n == 0 || exportQueue.isRunning)
            if exportQueue.isRunning {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(exportQueue.done) of \(exportQueue.total)").font(.caption2)
                        Spacer()
                        Button("Cancel") { exportQueue.cancel() }.controlSize(.mini)
                    }
                    ProgressView(value: Double(exportQueue.done), total: Double(max(exportQueue.total, 1)))
                        .controlSize(.small)
                    Text(exportQueue.currentName).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else if !exportQueue.summary.isEmpty {
                Text(exportQueue.summary).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(exportQueue.failures) { f in
                    Text("✗ \(f.name): \(f.reason)").font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Rating, flag and keywords for the selected image. Keys do the same
    /// (0-5, P/X/U); this is the visible, clickable version.
    private func selectionSection(_ image: ImageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Selected")
            Text(image.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        onRate(star == image.rating ? 0 : star)
                    } label: {
                        Text(star <= image.rating ? "★" : "☆")
                            .foregroundStyle(star <= image.rating ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Picker("Flag", selection: Binding(
                    get: { ImageFlag(rawValue: image.flag) ?? .none },
                    set: { onFlag($0) })) {
                    Text("–").tag(ImageFlag.none)
                    Text("✓").tag(ImageFlag.picked)
                    Text("✗").tag(ImageFlag.rejected)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 80)
            }

            TextField("Keywords, comma separated", text: $keywordText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    let keywords = keywordText.split(separator: ",").map(String.init)
                    Task { try? await library.setKeywords(keywords) }
                }

            if image.userRotation != 0 {
                Text("rotated \(image.userRotation * 90)°")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
