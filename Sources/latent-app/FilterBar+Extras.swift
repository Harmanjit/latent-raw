import SwiftUI
import AppKit
import Catalog

// The filter bar's newer controls, each beside the one it extends: the
// rating range popover, Option-click exclusion in the Label menu, the
// Edited toggle's Unedited state, No Keywords in the keyword menu, the
// Kind menu, the Date popover and the search scope menu. Left alone, every
// one of them leaves the filter as it was.

/// Option-click in the Label menu: hide photos with a label.
enum LabelFilterExclusion {
    /// Whether Option is down as the menu item is chosen.
    @MainActor static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    /// Excluded ⇄ not, taking the label out of the included set on the way.
    static func toggleExcluded(_ choice: LabelFilterChoice, selection: Binding<Set<LabelFilterChoice>>,
                               excluded: Binding<Set<LabelFilterChoice>>) {
        if excluded.wrappedValue.contains(choice) {
            excluded.wrappedValue.remove(choice)
        } else {
            excluded.wrappedValue.insert(choice)
            selection.wrappedValue.remove(choice)
        }
    }

    static func excludedTitle(_ choice: LabelFilterChoice) -> String { "Not \(choice.title)" }

    /// "Red, −Blue", "−Red", "3 labels".
    static func summary(selection: Set<LabelFilterChoice>, excluded: Set<LabelFilterChoice>) -> String {
        let parts = LabelFilterChoice.all.compactMap { choice -> String? in
            if selection.contains(choice) { return choice.title }
            if excluded.contains(choice) { return "−" + choice.title }
            return nil
        }
        return parts.count <= 2 ? parts.joined(separator: ", ") : "\(parts.count) labels"
    }

    static func spoken(selection: Set<LabelFilterChoice>, excluded: Set<LabelFilterChoice>) -> String {
        let shown = LabelFilterChoice.all.filter(selection.contains).map(\.title)
        let hidden = LabelFilterChoice.all.filter(excluded.contains).map(\.title)
        var parts: [String] = []
        if !shown.isEmpty { parts.append(shown.joined(separator: ", ")) }
        if !hidden.isEmpty { parts.append("not " + hidden.joined(separator: ", not ")) }
        return parts.joined(separator: "; ")
    }
}

/// The small button after the stars that opens the rating range: the
/// operator and a star range with two ends.
struct RatingRangeButton: View {
    @Binding var filter: LibraryFilter
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: filter.ratingOperator == .atLeast ? "chevron.down" : "line.3.horizontal.decrease")
                .font(.system(size: 8, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(filter.ratingOperator == .atLeast ? Color.secondary : Color.accentColor)
        .help("Rating range: at least, exactly, at most or between")
        .accessibilityLabel("Rating range")
        .accessibilityValue(RatingRangeText.summary(filter))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Rating", selection: $filter.ratingOperator) {
                    ForEach(RatingOperator.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch filter.ratingOperator {
                case .atLeast, .exactly:
                    starRow(filter.ratingOperator == .atLeast ? "From" : "Stars", value: $filter.minRating)
                case .atMost:
                    starRow("Up to", value: $filter.maxRating)
                case .between:
                    starRow("From", value: $filter.minRating)
                    starRow("To", value: $filter.maxRating)
                }
                Text(RatingRangeText.summary(filter))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Reset") {
                        filter.ratingOperator = .atLeast
                        filter.minRating = 0
                        filter.maxRating = 5
                    }
                }
            }
            .controlSize(.small)
            .padding(14)
            .frame(width: 280)
        }
    }

    /// No stars, then one to five.
    private func starRow(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            Text(title).frame(width: 40, alignment: .leading).foregroundStyle(.secondary)
            Button {
                value.wrappedValue = 0
            } label: {
                Text("⊘").foregroundStyle(value.wrappedValue == 0 ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("No stars")
            ForEach(1...5, id: \.self) { star in
                Button {
                    value.wrappedValue = star
                } label: {
                    Text(star <= value.wrappedValue ? "★" : "☆")
                        .foregroundStyle(star <= value.wrappedValue ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(SpokenText.stars(value.wrappedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value.wrappedValue = min(value.wrappedValue + 1, 5)
            case .decrement: value.wrappedValue = max(value.wrappedValue - 1, 0)
            @unknown default: break
            }
        }
    }
}

enum RatingRangeText {
    static func stars(_ n: Int) -> String { n == 1 ? "1 star" : "\(n) stars" }

    /// "Any rating", "3 stars or more", "exactly 2 stars", "1 to 3 stars".
    static func summary(_ filter: LibraryFilter) -> String {
        switch filter.ratingOperator {
        case .atLeast: return filter.minRating == 0 ? "Any rating" : "\(stars(filter.minRating)) or more"
        case .exactly: return filter.minRating == 0 ? "Unrated only" : "Exactly \(stars(filter.minRating))"
        case .atMost: return filter.maxRating >= 5 ? "Any rating" : "\(stars(filter.maxRating)) or fewer"
        case .between:
            let low = min(filter.minRating, filter.maxRating), high = max(filter.minRating, filter.maxRating)
            return low == 0 && high == 5 ? "Any rating" : "\(low) to \(stars(high))"
        }
    }

    /// The mark after the bar's stars for an operator other than At least
    /// (which keeps its "+").
    static func operatorMark(_ filter: LibraryFilter) -> String {
        switch filter.ratingOperator {
        case .atLeast: "+"
        case .exactly: "="
        case .atMost: "≤"
        case .between: "\(min(filter.minRating, filter.maxRating))–\(max(filter.minRating, filter.maxRating))"
        }
    }

    /// The stars the bar's own five show under the operator: the minimum,
    /// as always, except At most, which shows its top.
    static func shownRating(_ filter: LibraryFilter) -> Int {
        filter.ratingOperator == .atMost ? (filter.maxRating >= 5 ? 0 : filter.maxRating) : filter.minRating
    }
}

/// The Edited toggle. A click works as it always has; Option-click turns
/// it to Unedited only (and back off).
struct EditedFilterToggle: View {
    @Binding var filter: LibraryFilter

    var body: some View {
        Toggle(isOn: Binding(get: { filter.editedOnly || filter.uneditedOnly }, set: { on in
            if NSEvent.modifierFlags.contains(.option) {
                filter.uneditedOnly.toggle()
                filter.editedOnly = false
            } else if filter.uneditedOnly {
                filter.uneditedOnly = false
            } else {
                filter.editedOnly = on
            }
        })) {
            if filter.uneditedOnly {
                Label("Unedited", systemImage: "pencil.slash").labelStyle(.titleAndIcon)
            } else {
                Text("Edited")
            }
        }
        .toggleStyle(.button)
        .help(filter.uneditedOnly ? "Showing only photos without an edit. Click to show all."
              : "Show only edited photos. Option-click for only unedited ones.")
        .accessibilityLabel(filter.uneditedOnly ? "Unedited only" : "Edited only")
    }
}

/// The keyword menu: Any, No Keywords, then every keyword.
struct KeywordFilterMenu: View {
    @Binding var filter: LibraryFilter
    let options: [String]

    var body: some View {
        Menu {
            Button("Any") {
                filter.keyword = nil
                filter.noKeywords = false
            }
            Button {
                filter.noKeywords.toggle()
                if filter.noKeywords { filter.keyword = nil }
            } label: {
                if filter.noKeywords { Label("No Keywords", systemImage: "checkmark") } else { Text("No Keywords") }
            }
            if !options.isEmpty { Divider() }
            ForEach(options, id: \.self) { option in
                Button {
                    filter.keyword = option
                    filter.noKeywords = false
                } label: {
                    if filter.keyword == option {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            Text(filter.noKeywords ? "No Keywords" : filter.keyword ?? "Keyword")
                .lineLimit(1)
                .frame(maxWidth: 140)
        }
        .disabled(options.isEmpty && filter.keyword == nil && !filter.noKeywords)
        .accessibilityLabel("Keyword")
        .accessibilityValue(filter.noKeywords ? "No keywords" : filter.keyword ?? "Any")
    }
}

/// File kind and virtual-copy kind, in one menu.
struct KindFilterMenu: View {
    @Binding var filter: LibraryFilter

    var body: some View {
        Menu {
            Section("File") {
                ForEach(FileKindFilter.allCases, id: \.self) { kind in
                    choice(kind.title, on: filter.fileKind == kind) { filter.fileKind = kind }
                }
            }
            Section("Copies") {
                ForEach(CopyKindFilter.allCases, id: \.self) { kind in
                    choice(kind.title, on: filter.copyKind == kind) { filter.copyKind = kind }
                }
            }
        } label: {
            Text(summary).lineLimit(1).frame(maxWidth: 140)
        }
        .help("Show only raw files, other files or RAW+JPEG pairs; masters, virtual copies or masters with copies")
        .accessibilityLabel("Kind")
        .accessibilityValue(summary)
    }

    private func choice(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var summary: String {
        let parts = [filter.fileKind == .any ? nil : filter.fileKind.title,
                     filter.copyKind == .any ? nil : filter.copyKind.title].compactMap { $0 }
        return parts.isEmpty ? "Kind" : parts.joined(separator: ", ")
    }
}

/// The capture date range: From and To, and quick ranges.
struct DateFilterButton: View {
    @Binding var filter: LibraryFilter
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Text(summary).lineLimit(1)
        }
        .help("Show only photos taken between two dates")
        .accessibilityLabel("Capture date")
        .accessibilityValue(filter.captureDateRange == nil ? "Any" : summary)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("From", selection: bound(\.lowerBound), displayedComponents: .date)
                DatePicker("To", selection: bound(\.upperBound), displayedComponents: .date)
                HStack(spacing: 6) {
                    ForEach(CaptureDateQuickRange.allCases, id: \.self) { quick in
                        Button(quick.title) { filter.captureDateRange = quick.range() }
                    }
                }
                HStack {
                    Text("Photos without a capture date are hidden while a range is set.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Any Date") { filter.captureDateRange = nil }
                        .disabled(filter.captureDateRange == nil)
                }
            }
            .controlSize(.small)
            .padding(14)
            .frame(width: 330)
        }
    }

    /// One end of the range; choosing a day with no range set starts one
    /// on that day alone.
    private func bound(_ end: KeyPath<ClosedRange<Date>, Date>) -> Binding<Date> {
        Binding(get: { filter.captureDateRange?[keyPath: end] ?? Date() }, set: { day in
            let current = filter.captureDateRange ?? CaptureDateQuickRange.days(from: day, to: day)
            filter.captureDateRange = end == \ClosedRange<Date>.lowerBound
                ? CaptureDateQuickRange.days(from: day, to: current.upperBound)
                : CaptureDateQuickRange.days(from: current.lowerBound, to: day)
        })
    }

    private var summary: String {
        guard let range = filter.captureDateRange else { return "Date" }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let from = range.lowerBound.formatted(style), to = range.upperBound.formatted(style)
        return from == to ? from : "\(from) – \(to)"
    }
}

/// Where the search box looks, and its syntax in the wider scope.
struct SearchScopeMenu: View {
    @Binding var scope: TextSearchScope

    var body: some View {
        Menu {
            ForEach(TextSearchScope.allCases, id: \.self) { option in
                Button {
                    scope = option
                } label: {
                    if scope == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
            Divider()
            Text("All fields: every word must match, \"quotes\" for a phrase, -word to leave out")
        } label: {
            Image(systemName: scope == .names ? "magnifyingglass" : "text.magnifyingglass")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where the search looks: \(scope.title.lowercased())")
        .accessibilityLabel("Search in")
        .accessibilityValue(scope.title)
    }
}

/// The Keyword List's first row: the photos without any keyword. Clicking
/// it filters the grid to them (the filter bar's No Keywords), and again
/// shows everything.
struct KeywordListNoKeywordsRow: View {
    @ObservedObject var library: Library
    let count: Int

    var body: some View {
        let isFilter = library.filter.noKeywords
        Button {
            library.filter.noKeywords.toggle()
            if library.filter.noKeywords { library.filter.keyword = nil }
        } label: {
            HStack(spacing: 4) {
                Color.clear.frame(width: 24, height: 10)
                Text("No Keywords").italic().lineLimit(1)
                    .fontWeight(isFilter ? .semibold : .regular)
                Spacer(minLength: 2)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.vertical, 1)
        .background(isFilter ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 3))
        .help(isFilter ? "Showing photos without keywords. Click to show all again."
              : "Show the \(count) photos without any keyword")
        .accessibilityLabel("Show photos without keywords")
        .accessibilityValue("\(count) photos")
        .accessibilityAddTraits(isFilter ? .isSelected : [])
    }
}
