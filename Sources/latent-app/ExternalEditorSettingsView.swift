import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings > External Editor: which application Edit in External Editor
/// (⌘E) opens, and where the TIFFs it makes go.
struct ExternalEditorSettingsTab: View {
    @ObservedObject var settings = ExternalEditorSettings.shared
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        Form {
            Picker("Open with", selection: $settings.chosenID) {
                Text("Default app for TIFF files").tag(String?.none)
                if !settings.apps.isEmpty { Divider() }
                ForEach(settings.apps) { app in
                    Label {
                        Text(app.name)
                    } icon: {
                        Image(nsImage: icon(for: app))
                    }
                    .tag(Optional(app.id))
                }
            }
            HStack {
                Button("Add Application…") { addApplication() }
                if let chosen = settings.chosen {
                    Button("Remove \(chosen.name)") { settings.remove(id: chosen.id) }
                }
            }
            Text("Edit in External Editor (⌘E) renders the open image, or the selected one in the grid, with its edits to a 16-bit Display P3 TIFF, then opens the TIFF in this application. Latent doesn't catalog the TIFF or watch it for changes.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Save TIFFs in")
                Spacer()
                Text(folderDescription)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { chooseFolder() }
                if settings.folder != nil {
                    Button("Use Export Folder") { settings.setFolder(nil) }
                        .help("Save them in the default export folder (Settings > Export), or ask the first time when there is none")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Save TIFFs in \(folderDescription)")
            Text("A file already there is never replaced: the next is named with a number, as in DSC_0107-Edit-2.tif.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var folderDescription: String {
        if let folder = settings.folder { return folder.path }
        if let export = prefs.defaultExportFolder { return "Export folder (\(export.path))" }
        return "Ask the first time"
    }

    private func icon(for app: ExternalEditorApp) -> NSImage {
        let image = FileManager.default.fileExists(atPath: app.path)
            ? NSWorkspace.shared.icon(forFile: app.path)
            : NSWorkspace.shared.icon(for: .application)
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Choose the application to edit images in"
        guard panel.runModal() == .OK, let url = panel.url,
              let app = ExternalEditorApp.application(at: url) else { return }
        settings.add(app)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setFolder(url)
    }
}
