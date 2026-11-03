import SwiftUI
import Catalog

/// The search field above the sidebar's folder tree, and what it finds.
/// Typing a name lists every folder inside the favourites whose name
/// contains it (`FolderSearch`), however deep; clicking one opens it, as
/// clicking it in the tree would. Clearing the field brings the tree back.
struct FolderSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Find folder", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Find folder")
                .help("Find folders by name inside your favourites")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search and show the folder tree")
                .accessibilityLabel("Clear folder search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
    }
}

struct FolderSearchResults: View {
    let query: String
    let roots: [URL]
    let currentFolder: URL?
    let onOpen: (URL) -> Bool
    @State private var matches: [FolderSearch.Match] = []
    @State private var searching = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if matches.isEmpty {
                    Text(searching ? "Searching…" : "No folder named like “\(query)” in your favourites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(matches) { match in
                    let current = currentFolder.map { FolderAccess.samePath($0, match.url) } ?? false
                    Button {
                        _ = onOpen(match.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Label(match.url.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(match.trail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.leading, 22)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(current ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(match.url.path)
                    .accessibilityLabel("Open \(match.url.lastPathComponent), in \(match.trail)")
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        // Each keystroke starts a new search after a pause and cancels the last.
        .task(id: query + "\u{0}" + roots.map(\.path).joined(separator: "\u{0}")) {
            searching = true
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let query = query, roots = roots
            // Off the main thread, and stopped when the next keystroke
            // replaces this search: a deep tree on a share can take a while.
            let search = Task.detached(priority: .userInitiated) { FolderSearch.find(query, under: roots) }
            let found = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
            guard !Task.isCancelled else { return }
            matches = found
            searching = false
        }
    }
}
