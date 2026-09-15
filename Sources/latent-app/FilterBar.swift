import SwiftUI
import Catalog

/// The strip above the grid: rating threshold, flag set, edited-only,
/// attribute pickers, text search, sort, and how many images survive.
/// Everything writes straight into `library.filter` / `library.sort`,
/// and the grid follows `library.visibleImages`.
struct FilterBar: View {
    @ObservedObject var library: Library

    /// The controls need about 900 pt. In a column narrower than that (a
    /// small window with the sidebar showing) the bar scrolls sideways
    /// instead: a row that can't shrink would make the whole window's
    /// content wider than the window, cutting off the sidebar and grid.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollView(.horizontal, showsIndicators: false) { bar }
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var bar: some View {
        HStack(spacing: 10) {
            ratingThreshold
            flagToggles
            Toggle("Edited", isOn: $library.filter.editedOnly)
                .toggleStyle(.button)
                .accessibilityLabel("Edited only")

            attributeMenu("Camera", selection: $library.filter.camera, options: library.availableCameras)
            attributeMenu("Lens", selection: $library.filter.lens, options: library.availableLenses)
            attributeMenu("Keyword", selection: $library.filter.keyword, options: library.availableKeywords)

            TextField("Search file names", text: $library.filter.text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search file names")
                .frame(width: 150)

            Spacer()

            countLabel
            ThumbnailSizeControl()
            if library.filter.isActive {
                Button("Clear") { library.filter = LibraryFilter() }
            }
            sortMenu
        }
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Five stars; clicking the n-th means "n stars or better", clicking
    /// the current threshold again clears it (Lightroom's behaviour).
    private var ratingThreshold: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    library.filter.minRating = library.filter.minRating == star ? 0 : star
                } label: {
                    Text(star <= library.filter.minRating ? "★" : "☆")
                        .foregroundStyle(star <= library.filter.minRating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            if library.filter.minRating > 0 {
                Text("+").foregroundStyle(.secondary)
            }
        }
        .help("Show images rated this many stars or more")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minimum rating")
        .accessibilityValue(SpokenText.minimumRating(library.filter.minRating))
        .accessibilityAdjustableAction { direction in
            let rating = library.filter.minRating
            switch direction {
            case .increment: library.filter.minRating = min(rating + 1, 5)
            case .decrement: library.filter.minRating = max(rating - 1, 0)
            @unknown default: break
            }
        }
    }

    /// Picked / unflagged / rejected, each independently toggled. None
    /// selected means all are shown.
    private var flagToggles: some View {
        HStack(spacing: 2) {
            flagToggle(.picked, "✓", .green)
            flagToggle(.none, "–", .secondary)
            flagToggle(.rejected, "✗", .red)
        }
        .help("Show only these flag states")
    }

    private func flagToggle(_ flag: ImageFlag, _ glyph: String, _ color: Color) -> some View {
        let on = library.filter.flags.contains(flag)
        return Button {
            if on { library.filter.flags.remove(flag) } else { library.filter.flags.insert(flag) }
        } label: {
            Text(glyph)
                .foregroundStyle(on ? color : .secondary)
                .frame(width: 18)
        }
        .buttonStyle(.bordered)
        .tint(on ? color : nil)
        .accessibilityLabel("Show \(SpokenText.flag(flag.rawValue).lowercased())")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func attributeMenu(_ title: String, selection: Binding<String?>, options: [String]) -> some View {
        Menu {
            Button("Any") { selection.wrappedValue = nil }
            if !options.isEmpty { Divider() }
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue == option {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            Text(selection.wrappedValue ?? title)
                .lineLimit(1)
                .frame(maxWidth: 140)
        }
        .disabled(options.isEmpty && selection.wrappedValue == nil)
        .accessibilityLabel(title)
        .accessibilityValue(selection.wrappedValue ?? "Any")
    }

    private var countLabel: some View {
        let shown = library.visibleImages.count
        let total = library.images.count
        return Text(shown == total ? "\(total) images" : "\(shown) of \(total)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var sortMenu: some View {
        HStack(spacing: 4) {
            Picker("Sort", selection: $library.sort.key) {
                ForEach(LibrarySortKey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Button {
                library.sort.ascending.toggle()
            } label: {
                Image(systemName: library.sort.ascending ? "arrow.up" : "arrow.down")
            }
            .help(library.sort.ascending ? "Ascending" : "Descending")
            .accessibilityLabel("Sort order")
            .accessibilityValue(library.sort.ascending ? "Ascending" : "Descending")
        }
    }
}
