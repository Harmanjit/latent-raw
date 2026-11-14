import SwiftUI

/// The first-run welcome: what Latent is in a paragraph, a way to open a
/// folder, and the two Help pages worth reading first. Shown once (the
/// `latent.welcomeSeen` default), never under tests or the snapshot
/// harness; Help › Show Welcome brings it back. A plain view given its
/// actions, so the harness and tests can draw it without a window.
struct WelcomeSheet: View {
    let onOpenFolder: () -> Void
    /// Opens a Help page by its wiki name ("Getting-Started").
    let onOpenHelp: (String) -> Void
    let onClose: () -> Void

    static let tour = "Latent keeps your photos where they are: each folder you open becomes its own catalog, with Latent's notes in a _latent folder inside it and no import step. Cull in the Library grid, Loupe, Compare and Survey with Lightroom's keys (P, X, U and the numbers), then press D to develop. Edits never touch the original and can be undone step by step; File › Export writes JPEG, HEIF, TIFF, PNG and more. Everything runs on this Mac, with nothing sent anywhere."

    static let helpPages: [(title: String, page: String)] = [
        ("Getting Started", "Getting-Started"),
        ("Keyboard Shortcuts", "Keyboard-Shortcuts"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Welcome to Latent")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(Self.tour)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                ForEach(Self.helpPages, id: \.page) { link in
                    Button(link.title) { onOpenHelp(link.page) }
                        .buttonStyle(.link)
                        .accessibilityHint("Opens the \(link.title) page in Latent Help")
                }
            }
            Text("Help › Show Welcome brings this back.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Folder…") { onOpenFolder() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
