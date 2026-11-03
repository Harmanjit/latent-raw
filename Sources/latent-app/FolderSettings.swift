import SwiftUI
import AppKit
import Catalog
import PixelEngine

/// Settings › Folders: watching the open folder, and Auto Import from a
/// watched folder (AutoImportController).
struct FolderSettingsTab: View {
    @ObservedObject private var watching = FolderWatching.shared
    @ObservedObject private var autoImport = AutoImportController.shared
    @State private var presets: [Preset] = []

    var body: some View {
        Form {
            Section("Open folder") {
                Toggle("Watch the open folder for changes", isOn: $watching.watchOpenFolder)
                    .help("Photos copied into the open folder (or an included subfolder), deleted or renamed outside Latent show up by themselves.")
                Text("Photos added, removed or renamed in Finder appear without reopening the folder. Off, use File › Refresh Folder (⌘R). On a network share, changes made from another computer may not be noticed; Refresh always works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Auto Import") {
                Toggle("Import new photos from a watched folder", isOn: $autoImport.isEnabled)
                    .help("Raw files that appear in the watched folder are moved or copied into the destination folder.")
                folderRow("Watched folder", autoImport.source, help: "The folder to watch, such as the one your tethering software or card reader saves into. Only the files directly in it are imported, not its subfolders.") {
                    choose(message: "Choose the folder Latent watches for new raw files.") { autoImport.setSource($0) }
                }
                folderRow("Destination", autoImport.destination, help: "Where imported photos go. When it is the open folder, or inside it, they appear in the grid at once.") {
                    choose(message: "Choose the folder imported photos go into.") { autoImport.setDestination($0) }
                }
                Picker("Bring photos in by", selection: $autoImport.mode) {
                    Text("Moving them").tag(TransferMode.move)
                    Text("Copying them").tag(TransferMode.copy)
                }
                .help("Moving empties the watched folder as photos arrive. Copying leaves the originals there; Latent remembers what it has copied and doesn’t copy a photo twice.")
                Picker("Develop preset", selection: $autoImport.presetName) {
                    Text("None").tag(String?.none)
                    ForEach(presets) { Text($0.name).tag(Optional($0.name)) }
                }
                .help("Each imported photo starts with this preset’s settings, as if you had applied it. A photo that brings settings of its own keeps them.")
                Text(autoImport.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Auto Import status: \(autoImport.status)")
            }
        }
        .formStyle(.grouped)
        .onAppear { presets = PresetStore.load() }
    }

    private func folderRow(_ title: String, _ url: URL?, help: String, choose: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url?.path ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .help(url?.path ?? help)
                Button("Choose…", action: choose)
                    .help(help)
                    .accessibilityLabel("Choose \(title)")
            }
        }
    }

    private func choose(message: String, _ done: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(url)
    }
}
