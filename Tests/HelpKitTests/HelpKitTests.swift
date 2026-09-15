import Testing
import Foundation
@testable import HelpKit

/// Help > Latent Help: the wiki pages, the blocks they become, links
/// between them, and search.
@Suite struct HelpKitTests {
    /// docs/wiki, from this file's place in the repository.
    static let wiki = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/wiki", isDirectory: true)

    // MARK: - Pages

    /// Every wiki page loads, in the sidebar's order and with its titles,
    /// and the plumbing files aren't pages.
    @Test func wikiLoadsInSidebarOrder() throws {
        let book = HelpBook.load(from: Self.wiki)
        #expect(book.unreadable.isEmpty)
        let names = book.pages.map(\.name)
        #expect(names.first == "Home")
        #expect(!names.contains("README") && !names.contains("_Sidebar"))
        #expect(book.page(named: "Getting-Started")?.title == "Getting Started")
        let sidebar = HelpBook.sidebarPages(try String(contentsOf: Self.wiki.appendingPathComponent("_Sidebar.md"), encoding: .utf8))
        #expect(Array(names.prefix(sidebar.count)) == sidebar.map(\.name))
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.wiki.path)
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix("_") && $0 != "README.md" }
        #expect(Set(names) == Set(files.map { String($0.dropLast(3)) }))
        for page in book.pages {
            let blocks = try #require(book.blocks[page.name])
            #expect(blocks.count > 3, "\(page.name) is nearly empty")
            #expect(blocks.first?.kind == .heading(level: 1), "\(page.name) starts without a title")
        }
    }

    /// Links between pages name pages that exist (and headings on them).
    @Test func wikiLinksNamePages() throws {
        let book = HelpBook.load(from: Self.wiki)
        var internalLinks = 0
        for page in book.pages {
            for block in book.blocks[page.name] ?? [] {
                let texts: [AttributedString]
                if case .table(let table) = block.kind { texts = table.header + table.rows.flatMap { $0 } } else { texts = [block.text] }
                for text in texts {
                    for run in text.runs {
                        guard let url = run.link else { continue }
                        let link = try #require(HelpLink(url: url), "\(page.name) links to \(url), which help refuses")
                        switch link {
                        case .page(let name, let anchor):
                            internalLinks += 1
                            let target = try #require(book.page(named: name), "\(page.name) links to missing page \(name)")
                            if let anchor {
                                #expect(book.blocks[target.name]?.contains { $0.anchor == anchor } == true,
                                        "\(page.name) links to missing heading \(name)#\(anchor)")
                            }
                        case .anchor(let anchor):
                            #expect(book.blocks[page.name]?.contains { $0.anchor == anchor } == true)
                        case .external:
                            break
                        }
                    }
                }
            }
        }
        #expect(internalLinks >= 10)
    }

    @Test func linksResolve() {
        #expect(HelpLink(url: URL(string: "Develop")!) == .page("Develop", anchor: nil))
        #expect(HelpLink(url: URL(string: "Getting-Started#ratings")!) == .page("Getting-Started", anchor: "ratings"))
        #expect(HelpLink(url: URL(string: "./Export.md")!) == .page("Export", anchor: nil))
        #expect(HelpLink(url: URL(string: "#the-queue")!) == .anchor("the-queue"))
        #expect(HelpLink(url: URL(string: "https://github.com/x")!) == .external(URL(string: "https://github.com/x")!))
        #expect(HelpLink(url: URL(string: "file:///etc/passwd")!) == nil)
        #expect(HelpLink(url: URL(string: "../elsewhere/Page")!) == nil)
    }

    /// Pages the sidebar doesn't list still show, after it, by name.
    @Test func unlistedPagesFollowTheSidebar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("Zeta-Page.md", "# Zeta\n\nText.")
        try write("Alpha.md", "# Alpha\n\nText.")
        try write("README.md", "# Notes")
        #expect(HelpBook.load(from: folder).pages.map(\.name) == ["Alpha", "Zeta-Page"])
        try write("_Sidebar.md", "- [Last First](Zeta-Page)\n- [Gone](Missing)\n")
        let book = HelpBook.load(from: folder)
        #expect(book.pages == [HelpPage(name: "Zeta-Page", title: "Last First"), HelpPage(name: "Alpha", title: "Alpha")])

        // A symlink to the folder reads the same.
        let link = folder.deletingLastPathComponent().appendingPathComponent("help-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(HelpBook.load(from: link).pages == book.pages)
    }

    /// An app bundle's Help folder comes first; in `swift run` and tests
    /// the pages come from docs/wiki.
    @Test func pagesFolderPrefersTheBundle() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("help-app-\(UUID().uuidString)")
        let help = app.appendingPathComponent("Help")
        try FileManager.default.createDirectory(at: help, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let bundle = try #require(Bundle(url: app))
        #expect(HelpBook.pagesFolder(bundle: bundle)?.standardizedFileURL == Self.wiki.standardizedFileURL,
                "a Help folder without the sidebar isn't the pages")
        try "- [Home](Home)".write(to: help.appendingPathComponent("_Sidebar.md"), atomically: true, encoding: .utf8)
        #expect(HelpBook.pagesFolder(bundle: bundle)?.standardizedFileURL == help.standardizedFileURL)
        #expect(HelpBook.pagesFolder()?.standardizedFileURL == Self.wiki.standardizedFileURL)
    }

    // MARK: - Markdown

    @Test func markdownBecomesBlocks() throws {
        let blocks = try HelpMarkdown.blocks(from: """
            # Title

            A paragraph
            over two lines with **bold**, `code` and a [link](Export).

            ## Section Two: the (rest)

            - one
            - two
              continued

              second paragraph
              - nested

            1. first
            2. second

            > A note.

            ```
            let x = 1
            ```
            """)
        #expect(blocks.map(\.kind) == [
            .heading(level: 1), .paragraph, .heading(level: 2),
            .listItem(depth: 1, marker: "•"), .listItem(depth: 1, marker: "•"), .listItem(depth: 1, marker: nil),
            .listItem(depth: 2, marker: "•"),
            .listItem(depth: 1, marker: "1."), .listItem(depth: 1, marker: "2."),
            .note, .code,
        ])
        #expect(blocks[1].plainText == "A paragraph over two lines with bold, code and a link.")
        #expect(blocks[4].plainText == "two continued")
        #expect(blocks[10].plainText == "let x = 1")
        #expect(blocks[2].anchor == "section-two-the-rest")
        #expect(blocks[1].anchor == nil)
        // Inline styles and links stay for the view to draw.
        let bold = blocks[1].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(blocks[1].text[$0.range].characters) } == "bold")
        #expect(blocks[1].text.runs.contains { $0.link.flatMap(HelpLink.init(url:)) == .page("Export", anchor: nil) })
        #expect(Set(blocks.map(\.id)).count == blocks.count, "ids identify blocks in the view")
    }

    @Test func tablesKeepRowsAndColumns() throws {
        let blocks = try HelpMarkdown.blocks(from: """
            Before.

            | Keys | Action |
            |---|---|
            | ⌘Z | Undo, with **bold** and `code` |
            |  | Empty first cell |
            | [Export](Export) | Last |

            | | |
            |---|---|
            | a | b |
            """)
        #expect(blocks.count == 3)
        guard case .table(let table) = blocks[1].kind, case .table(let layout) = blocks[2].kind else {
            Issue.record("expected two tables, got \(blocks.map(\.kind))")
            return
        }
        #expect(table.columnCount == 2)
        #expect(table.header.map { String($0.characters) } == ["Keys", "Action"])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [
            ["⌘Z", "Undo, with bold and code"], ["", "Empty first cell"], ["Export", "Last"],
        ])
        #expect(table.rows[2][0].runs.first?.link == URL(string: "Export"))
        #expect(blocks[1].plainText.contains("Empty first cell"))
        #expect(layout.header.isEmpty)
        #expect(layout.rows.map { $0.map { String($0.characters) } } == [["a", "b"]])
        #expect(blocks[1].id != blocks[2].id)
    }

    @Test func anchorsFollowGitHub() {
        #expect(HelpMarkdown.anchor(forHeading: "Views and navigation") == "views-and-navigation")
        #expect(HelpMarkdown.anchor(forHeading: "Rating & metadata") == "rating--metadata")
        #expect(HelpMarkdown.anchor(forHeading: "Crop, straighten_and-rotate!") == "crop-straighten_and-rotate")
    }

    // MARK: - Search

    @Test func searchCountsAndFindsRanges() {
        #expect(HelpSearch.matchCount(of: "photo", in: "Photos and photo, PHOTO") == 3)
        #expect(HelpSearch.matchCount(of: "cafe", in: "Café") == 1)
        #expect(HelpSearch.matchCount(of: "  ", in: "anything") == 0)
        #expect(HelpSearch.matchCount(of: " tag ", in: "tag") == 1)

        let text = AttributedString("Tag or untag")
        #expect(HelpSearch.ranges(of: "tag", in: text).map { String(text[$0].characters) } == ["Tag", "tag"])
        #expect(HelpSearch.ranges(of: "", in: text).isEmpty)
    }

    /// Search sees titles and table cells, which is where shortcuts live.
    @Test func searchReachesTitlesAndTables() throws {
        let book = HelpBook.load(from: Self.wiki)
        let shortcuts = try #require(book.page(named: "Keyboard-Shortcuts"))
        #expect(HelpSearch.matchCount(of: "auto adjust", in: book.searchableText(of: shortcuts)) >= 1)
        let matching = book.pages.filter { HelpSearch.matchCount(of: "gatekeeper", in: book.searchableText(of: $0)) > 0 }
        #expect(matching.contains { $0.name == "Installation" })
        #expect(!matching.contains { $0.name == "Keyboard-Shortcuts" })
    }
}
