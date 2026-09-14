import AppKit
import SwiftUI
import HelpKit

struct HelpView: View {
    @Bindable var model: HelpModel

    var body: some View {
        NavigationSplitView {
            List(model.visiblePages, selection: $model.selection) { page in
                let matches = model.matchCount(page)
                Text(page.title)
                    .badge(matches)
                    .accessibilityValue(model.isSearching ? "\(matches) \(matches == 1 ? "match" : "matches")" : "")
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search Help")
            .onChange(of: model.query) { model.queryDidChange() }
            .overlay {
                if model.isSearching && model.visiblePages.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            detail
        }
        .environment(\.openURL, OpenURLAction { model.follow($0) })
    }

    @ViewBuilder private var detail: some View {
        if let book = model.book {
            if let name = model.selection, let blocks = book.blocks[name] {
                // A view of its own identity per page, so each opens at its top.
                HelpPageView(blocks: blocks, query: model.isSearching ? model.query : "",
                             scrollRequest: model.scrollRequest)
                    .id(name)
                    .navigationTitle(book.page(named: name)?.title ?? "Latent Help")
            } else if book.pages.isEmpty {
                ContentUnavailableView("Help Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("The help pages couldn’t be found in the app."))
            } else {
                ContentUnavailableView("Choose a Topic", systemImage: "questionmark.circle")
            }
        } else {
            Color.clear
        }
    }
}

/// A page: blocks in a readable column, search matches highlighted and the
/// first one scrolled into view, and headings that links can scroll to.
struct HelpPageView: View {
    let blocks: [HelpBlock]
    let query: String
    let scrollRequest: (anchor: String, token: Int)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        HelpBlockView(block: block, query: query)
                            .padding(.top, topSpacing(before: index))
                            .id(block.id)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if !scrollToAnchor(proxy) { scrollToFirstMatch(proxy) }
            }
            .onChange(of: query) { scrollToFirstMatch(proxy) }
            .onChange(of: scrollRequest?.token) { _ = scrollToAnchor(proxy) }
        }
    }

    /// Headings get room above them; list items sit close together.
    private func topSpacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (blocks[index - 1].kind, blocks[index].kind) {
        case (_, .heading(let level)): return level <= 2 ? 24 : 16
        case (.heading(let level), _): return level == 1 ? 12 : 8
        case (.listItem, .listItem(_, let marker)): return marker == nil ? 4 : 6
        default: return 10
        }
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) -> Bool {
        guard let anchor = scrollRequest?.anchor,
              let target = blocks.first(where: { $0.anchor == anchor }) else { return false }
        proxy.scrollTo(target.id, anchor: .top)
        return true
    }

    /// While searching, brings the first match into view, a little below
    /// the top so the title bar never covers it. Without a search the page
    /// stays where the reader put it.
    private func scrollToFirstMatch(_ proxy: ScrollViewProxy) {
        guard !query.isEmpty,
              let target = blocks.first(where: { HelpSearch.matchCount(of: query, in: $0.plainText) > 0 }) else { return }
        proxy.scrollTo(target.id, anchor: UnitPoint(x: 0, y: 0.25))
    }
}

struct HelpBlockView: View {
    let block: HelpBlock
    let query: String

    var body: some View {
        switch block.kind {
        case .heading(let level):
            text(block.text)
                .font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
        case .paragraph:
            text(block.text).fixedSize(horizontal: false, vertical: true)
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker ?? "").foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    .accessibilityHidden(marker == nil)
                text(block.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth - 1) * 22)
        case .code:
            text(block.text)
                .font(.body.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .note:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb").foregroundStyle(.secondary).accessibilityHidden(true)
                text(block.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let table):
            HelpTableView(table: table, query: query)
        }
    }

    private func text(_ attributed: AttributedString) -> Text {
        Text(HelpHighlight.highlighting(query, in: attributed))
    }
}

/// A table in a rounded box, header row bold, a rule between rows.
struct HelpTableView: View {
    let table: HelpTable
    let query: String

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
            if !table.header.isEmpty {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[column]).fontWeight(.semibold)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Divider()
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().opacity(0.6) }
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(row[column])
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }

    private func cell(_ text: AttributedString) -> some View {
        Text(HelpHighlight.highlighting(query, in: text))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Search matches, marked the way Find marks them.
enum HelpHighlight {
    static func highlighting(_ query: String, in text: AttributedString) -> AttributedString {
        let ranges = HelpSearch.ranges(of: query, in: text)
        guard !ranges.isEmpty else { return text }
        var result = text
        for range in ranges {
            result[range].backgroundColor = Color(nsColor: .findHighlightColor).opacity(0.6)
        }
        return result
    }
}
