import SwiftUI
import Catalog

/// Back and Forward between the folders opened in the main window, each
/// returning to the images that were selected when it was left.
/// ContentView's `openFolder` records visits and selections here; the
/// history itself is `FolderHistory`.
@MainActor
final class FolderNavigator: ObservableObject {
    static let shared = FolderNavigator()

    @Published private(set) var history = FolderHistory()

    /// Records the open folder's selection, as it is about to be left.
    func remember(_ library: Library) {
        guard let folder = library.folderURL else { return }
        history.remember(selection: library.selectedImages.map(\.relPath),
                         lead: library.selectedImage?.relPath, in: folder)
    }

    /// A folder opened from the sidebar, Open Folder or at launch.
    func visit(_ folder: URL) {
        history.visit(folder)
    }

    /// Moves through the history and returns the entry to open.
    func step(_ offset: Int) -> FolderHistory.Entry? {
        history.step(offset)
    }

    /// Selects what an entry had selected, once its folder is open. Images
    /// that have gone since are left out.
    func restoreSelection(_ entry: FolderHistory.Entry, in library: Library) {
        guard !entry.selection.isEmpty || entry.lead != nil else { return }
        var ids: [String: Int64] = [:]
        for record in library.images { if let id = record.id { ids[record.relPath] = id } }
        var selected = Set(entry.selection.compactMap { ids[$0] })
        let lead = entry.lead.flatMap { ids[$0] } ?? selected.first
        if let lead { selected.insert(lead) }
        guard !selected.isEmpty else { return }
        library.setSelection(selected, primary: lead)
    }
}

/// Back and Forward buttons, at the top of the folder sidebar.
struct FolderHistoryButtons: View {
    @ObservedObject var navigator: FolderNavigator
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button(offset: -1, symbol: "chevron.left", title: "Back", command: .back, target: navigator.history.backEntry)
            button(offset: 1, symbol: "chevron.right", title: "Forward", command: .forward, target: navigator.history.forwardEntry)
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func button(offset: Int, symbol: String, title: String, command: KeyCommand,
                        target: FolderHistory.Entry?) -> some View {
        let keys = Shortcuts.shortcut(for: command).map { " (\($0.glyphs))" } ?? ""
        return Button { onStep(offset) } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 18)
        }
        .disabled(target == nil)
        .help(target.map { "\(title) to “\($0.folder.lastPathComponent)”\(keys)" } ?? "\(title)\(keys)")
        .accessibilityLabel(title)
        .accessibilityValue(target?.folder.lastPathComponent ?? "")
    }
}
