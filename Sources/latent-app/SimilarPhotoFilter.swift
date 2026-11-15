import SwiftUI
import Catalog

/// The filter bar's "Similar to …" chip, shown while the filter was set by
/// View › Similar to This Photo (or the grid's context menu). Its popover
/// switches each part (camera body, lens, within a day) on or off, to
/// widen the search; the ✕ stops it and clears those parts.
struct SimilarFilterChip: View {
    @ObservedObject var library: Library
    let criteria: SimilarPhotoCriteria
    @State private var showing = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                showing.toggle()
            } label: {
                Label(SimilarFilterText.chipTitle(criteria), systemImage: "square.on.square")
                    .lineLimit(1)
                    .frame(maxWidth: 170)
            }
            .help("Showing photos like \(criteria.photoName); click to choose what must match")
            .accessibilityLabel("Similar to \(criteria.photoName)")
            .accessibilityValue(SimilarFilterText.partsSummary(criteria))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SimilarFilterPopover(library: library, criteria: criteria)
            }
            Button {
                library.endSimilar()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop showing similar photos")
            .accessibilityLabel("Stop showing similar photos")
        }
    }
}

/// The toggles behind the chip. Each writes through `Library.updateSimilar`
/// so only camera, lens and capture date change in the filter.
struct SimilarFilterPopover: View {
    @ObservedObject var library: Library
    /// The criteria when the popover opened; the Library's own copy wins
    /// once a toggle has changed it.
    let initial: SimilarPhotoCriteria

    init(library: Library, criteria: SimilarPhotoCriteria) {
        self.library = library
        initial = criteria
    }

    private var criteria: SimilarPhotoCriteria { library.similarPhotoCriteria ?? initial }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Similar to \(criteria.photoName)").font(.caption.weight(.semibold))
            part("Same camera: \(criteria.camera ?? "not recorded")", \.matchesCamera,
                 available: criteria.camera != nil)
            part("Same lens: \(criteria.lens ?? "not recorded")", \.matchesLens,
                 available: criteria.lens != nil)
            part(SimilarFilterText.dateTitle(criteria), \.matchesDate,
                 available: criteria.captureTime != nil)
            Text("Turn a part off to widen the search.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func part(_ title: String, _ keyPath: WritableKeyPath<SimilarPhotoCriteria, Bool>,
                      available: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { criteria[keyPath: keyPath] },
            set: { on in
                var next = criteria
                next[keyPath: keyPath] = on
                library.updateSimilar(next)
            }))
            .disabled(!available)
            .lineLimit(1)
    }
}

/// Wording for the chip and popover, kept apart so it is tested.
enum SimilarFilterText {
    static func chipTitle(_ criteria: SimilarPhotoCriteria) -> String {
        "Similar to \(criteria.photoName)"
    }

    /// "camera, lens, date" for the parts that are on; "nothing" when none.
    static func partsSummary(_ criteria: SimilarPhotoCriteria) -> String {
        var parts: [String] = []
        if criteria.matchesCamera { parts.append("camera") }
        if criteria.matchesLens { parts.append("lens") }
        if criteria.matchesDate { parts.append("within a day") }
        return parts.isEmpty ? "nothing matched" : parts.joined(separator: ", ")
    }

    static func dateTitle(_ criteria: SimilarPhotoCriteria) -> String {
        guard let time = criteria.captureTime else { return "Within a day: no capture time" }
        return "Within a day of \(time.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// View › Similar to This Photo and the grid's context-menu item.
@MainActor
enum SimilarPhotoCommand {
    /// Filters to photos like the selection's lead photo, or says why not.
    static func run(_ library: Library) {
        guard let record = library.selectedImage else { return }
        if !library.showSimilar(to: record) {
            library.lastError = "\(record.fileName) records no camera, lens or capture time to match"
        }
    }
}
