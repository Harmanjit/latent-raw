import SwiftUI
import Catalog

/// Develop's Versions section: the photo's master and its virtual copies,
/// darktable's duplicate manager. Each shows small with its name; a click
/// opens it, and a copy can be given a name of its own (kept in the
/// catalog). New Blank Copy makes a copy with the default edit.
struct VersionsPanel: View {
    @ObservedObject var library: Library
    let onOpen: (ImageRecord) -> Void
    let onNewCopy: () -> Void
    let onNewBlankCopy: () -> Void
    @State private var names: [Int64: String] = [:]
    @State private var thumbnails: [Int64: CGImage] = [:]

    var body: some View {
        if let lead = library.selectedImage {
            let versions = library.versions(of: lead)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(versions, id: \.relPath) { record in
                    row(record, isCurrent: record.id == lead.id)
                }
                HStack {
                    Button("New Virtual Copy", action: onNewCopy)
                        .help("Another version of this photo with the same edit (⌘')")
                    Button("New Blank Copy", action: onNewBlankCopy)
                        .help("Another version of this photo, starting from the default edit")
                }
                .controlSize(.small)
            }
            .task(id: versions.compactMap(\.id)) { await load(versions) }
        } else {
            Text("No photo selected").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ record: ImageRecord, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let id = record.id, let image = thumbnails[id] {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: record)).font(.caption).fontWeight(isCurrent ? .semibold : .regular)
                if record.isVirtualCopy, let id = record.id {
                    TextField("Version name", text: nameBinding(id: id, record: record))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .controlSize(.small)
                        .accessibilityLabel("Name of \(Self.title(for: record))")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if !isCurrent { onOpen(record) } }
        .help(Self.tooltip(for: record, name: record.id.flatMap { names[$0] }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.tooltip(for: record, name: record.id.flatMap { names[$0] }))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if !isCurrent { onOpen(record) } }
    }

    /// "Master" or "Copy 2".
    static func title(for record: ImageRecord) -> String {
        record.virtualCopyNumber.map { "Copy \($0)" } ?? "Master"
    }

    /// The row's tooltip: the version, its name if it has one, the file.
    static func tooltip(for record: ImageRecord, name: String?) -> String {
        var text = title(for: record)
        if let name, !name.isEmpty { text += " “\(name)”" }
        return text + " · " + record.fileName
    }

    private func nameBinding(id: Int64, record: ImageRecord) -> Binding<String> {
        Binding(get: { names[id] ?? "" }, set: { text in
            names[id] = text
            let library = library
            library.perform("Naming the version") { try await library.setVersionName(text, for: record) }
        })
    }

    private func load(_ versions: [ImageRecord]) async {
        do {
            names = try await library.versionNames(for: versions)
        } catch {
            names = [:]
        }
        for record in versions {
            guard let id = record.id, thumbnails[id] == nil else { continue }
            if let image = await library.loadThumbnail(for: record) { thumbnails[id] = image }
        }
    }
}
