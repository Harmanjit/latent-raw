import Foundation

/// One page of help: a Markdown file from docs/wiki.
public struct HelpPage: Identifiable, Hashable, Sendable {
    /// The file name without `.md`, which is how wiki pages link to each
    /// other: `[Export](Export)`.
    public let name: String
    public let title: String
    public var id: String { name }

    public init(name: String, title: String) {
        self.name = name
        self.title = title
    }
}

/// Where a link in a help page goes.
public enum HelpLink: Equatable, Sendable {
    /// Another page, by name, and a heading on it if the link names one.
    case page(String, anchor: String?)
    /// A heading on the same page.
    case anchor(String)
    /// A web or mail address, for the system to open in the user's browser
    /// or mail app. The app itself never fetches anything.
    case external(URL)

    /// Nil for anything else (file URLs, other schemes), which help refuses.
    public init?(url: URL) {
        if let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "mailto"].contains(scheme) else { return nil }
            self = .external(url)
            return
        }
        // Wiki links are bare page names, relative to the wiki's root.
        var name = url.path(percentEncoded: false)
        if name.hasPrefix("./") { name.removeFirst(2) }
        if name.hasSuffix(".md") { name.removeLast(3) }
        let fragment = url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        if name.isEmpty {
            guard let fragment else { return nil }
            self = .anchor(fragment)
            return
        }
        guard !name.contains("/") else { return nil }
        self = .page(name, anchor: fragment)
    }
}

/// Every help page, read and parsed.
///
/// The pages are the GitHub wiki's own Markdown (docs/wiki), so the wiki
/// and the app never disagree. `_Sidebar.md` gives their order and titles,
/// as it does on GitHub; a page it doesn't list comes after, by name.
/// Files starting with an underscore and README.md are wiki plumbing, not
/// pages.
public struct HelpBook: Sendable {
    public let pages: [HelpPage]
    /// Each page's blocks, by page name.
    public let blocks: [String: [HelpBlock]]
    /// Pages that were listed or present but couldn't be read or parsed.
    public let unreadable: [String]

    public init(pages: [HelpPage], blocks: [String: [HelpBlock]], unreadable: [String] = []) {
        self.pages = pages
        self.blocks = blocks
        self.unreadable = unreadable
    }

    public static let sidebarFile = "_Sidebar"

    public func page(named name: String) -> HelpPage? {
        pages.first { $0.name == name }
    }

    /// The page's title and text, as search sees them.
    public func searchableText(of page: HelpPage) -> String {
        ([page.title] + (blocks[page.name] ?? []).map(\.plainText)).joined(separator: "\n")
    }

    /// Reads every page in `folder`. File I/O and parsing, a few
    /// milliseconds for the whole wiki: call it off the main thread.
    public static func load(from folder: URL) -> HelpBook {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.hasPrefix("_") && $0 != "README" })

        var ordered: [HelpPage] = []
        if let sidebar = try? String(contentsOf: folder.appendingPathComponent(sidebarFile + ".md"), encoding: .utf8) {
            for page in sidebarPages(sidebar) where names.contains(page.name) && !ordered.contains(page) {
                ordered.append(page)
            }
        }
        let listed = Set(ordered.map(\.name))
        ordered += names.subtracting(listed).sorted().map {
            HelpPage(name: $0, title: $0.replacingOccurrences(of: "-", with: " "))
        }

        var blocks: [String: [HelpBlock]] = [:]
        var unreadable: [String] = []
        for page in ordered {
            let url = folder.appendingPathComponent(page.name + ".md")
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let parsed = try? HelpMarkdown.blocks(from: text) else {
                unreadable.append(page.name)
                continue
            }
            blocks[page.name] = parsed
        }
        return HelpBook(pages: ordered.filter { blocks[$0.name] != nil }, blocks: blocks, unreadable: unreadable)
    }

    /// The pages a wiki sidebar links to, in its order, titled by the
    /// link text.
    public static func sidebarPages(_ markdown: String) -> [HelpPage] {
        guard let blocks = try? HelpMarkdown.blocks(from: markdown) else { return [] }
        var pages: [HelpPage] = []
        for block in blocks {
            for run in block.text.runs {
                guard let url = run.link, case .page(let name, nil) = HelpLink(url: url) else { continue }
                let title = String(block.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                pages.append(HelpPage(name: name, title: title.isEmpty ? name : title))
            }
        }
        return pages
    }

    /// Where the pages are: Contents/Resources/Help in the app bundle,
    /// which scripts/make_app.sh fills from docs/wiki, or docs/wiki itself
    /// when running from the source tree (`swift run`).
    public static func pagesFolder(bundle: Bundle = .main) -> URL? {
        let candidates = [bundle.resourceURL?.appendingPathComponent("Help", isDirectory: true), sourceTreeWiki]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(sidebarFile + ".md").path)
        }
    }

    /// docs/wiki, found from this file's place in the repository
    /// (Sources/HelpKit/HelpBook.swift).
    static let sourceTreeWiki = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/wiki", isDirectory: true)
}
