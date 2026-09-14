import SwiftUI
import Catalog

/// The grid's thumbnail size: a slider between a small and a large photo
/// button, which step the size with ⌘- and ⌘=. Remembered in preferences.
///
/// The keys live here, in the Library's own bar, so they exist only while
/// the grid shows; in Loupe, Compare and Develop the same keys zoom.
struct ThumbnailSizeControl: View {
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        HStack(spacing: 4) {
            Button {
                step(larger: false)
            } label: {
                Image(systemName: "photo").imageScale(.small)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("-", modifiers: .command)
            .disabled(prefs.thumbnailSize <= ThumbnailGridLayout.sizeRange.lowerBound)
            .help("Smaller thumbnails (⌘-)")
            .accessibilityLabel("Smaller thumbnails")

            Slider(value: $prefs.thumbnailSize, in: ThumbnailGridLayout.sizeRange,
                   step: ThumbnailGridLayout.sizeStep)
                .frame(width: 90)
                .help("Thumbnail size")
                .accessibilityLabel("Thumbnail size")
                .accessibilityValue("\(Int(prefs.thumbnailSize)) points")

            Button {
                step(larger: true)
            } label: {
                Image(systemName: "photo").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("=", modifiers: .command)
            .disabled(prefs.thumbnailSize >= ThumbnailGridLayout.sizeRange.upperBound)
            .help("Larger thumbnails (⌘=)")
            .accessibilityLabel("Larger thumbnails")
        }
    }

    private func step(larger: Bool) {
        prefs.thumbnailSize = ThumbnailGridLayout.stepped(prefs.thumbnailSize, larger: larger)
    }
}
