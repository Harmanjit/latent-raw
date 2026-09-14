import AppKit
import SwiftUI
import HelpKit

/// Help > Latent Help (⌘?), replacing SwiftUI's default item, which looks
/// for a Help Book and says help isn't available. Installed with
/// `.commands { HelpCommands() }` on the app's scene.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Latent Help") { HelpWindow.show() }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// The Help window: the wiki's pages in a sidebar with search, rendered
/// natively. Nothing is fetched; the pages ship in the app
/// (see `HelpBook.pagesFolder`).
///
/// One window, made on first use and kept, so it reopens on the page and
/// search the user left. An AppKit window rather than a SwiftUI `Window`
/// scene, so opening it needs no scene of its own in the app's body.
@MainActor
enum HelpWindow {
    private static var controller: HelpWindowController?

    /// Brings the window forward, on the page named `page` (a wiki page's
    /// file name, as `"Keyboard-Shortcuts"`) if given.
    static func show(page: String? = nil) {
        let controller = controller ?? HelpWindowController()
        Self.controller = controller
        if let page { controller.model.open(page: page, anchor: nil) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

private final class HelpWindowController: NSWindowController {
    let model = HelpModel()

    static let defaultSize = NSSize(width: 900, height: 660)
    static let minimumSize = NSSize(width: 640, height: 420)

    init() {
        let hosting = NSHostingController(rootView: HelpView(model: model))
        // The window's size is the user's, not the content's: a split view
        // would otherwise shrink it to its smallest fitting size.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: Self.defaultSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.contentViewController = hosting
        window.title = "Latent Help"
        window.minSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName("LatentHelp")
        super.init(window: window)
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// What the Help window shows: the pages, the one selected, where to
/// scroll on it, and the search.
@MainActor @Observable
final class HelpModel {
    var selection: String?
    var query = ""
    private(set) var book: HelpBook?
    /// A heading to bring into view, set by a link. The token makes a
    /// second click on the same link scroll again.
    private(set) var scrollRequest: (anchor: String, token: Int)?
    private var scrollToken = 0

    /// Reads and parses the pages in the background (milliseconds); the
    /// window shows at once and fills in.
    func load() {
        Task {
            let book = await Task.detached(priority: .userInitiated) {
                HelpBook.pagesFolder().map(HelpBook.load(from:)) ?? HelpBook(pages: [], blocks: [:])
            }.value
            self.book = book
            if selection == nil { selection = book.pages.first?.name }
        }
    }

    func open(page: String, anchor: String?) {
        selection = page
        if let anchor {
            scrollToken += 1
            scrollRequest = (anchor, scrollToken)
        }
    }

    var isSearching: Bool { !HelpSearch.normalized(query).isEmpty }

    /// A search that leaves the open page out of the sidebar moves to the
    /// first page that matches, so what was found is on screen.
    func queryDidChange() {
        let visible = visiblePages
        guard isSearching, !visible.isEmpty, !visible.contains(where: { $0.name == selection }) else { return }
        selection = visible.first?.name
    }

    func matchCount(_ page: HelpPage) -> Int {
        guard isSearching, let book else { return 0 }
        return HelpSearch.matchCount(of: query, in: book.searchableText(of: page))
    }

    /// The sidebar: every page, or while searching only pages that match.
    var visiblePages: [HelpPage] {
        guard let book else { return [] }
        guard isSearching else { return book.pages }
        return book.pages.filter { matchCount($0) > 0 }
    }

    /// Follows a link in a page: other pages and headings open here, web
    /// and mail addresses go to the system, anything else is refused.
    func follow(_ url: URL) -> OpenURLAction.Result {
        switch HelpLink(url: url) {
        case .page(let name, let anchor)?:
            guard book?.page(named: name) != nil else { return .discarded }
            open(page: name, anchor: anchor)
            return .handled
        case .anchor(let anchor)?:
            if let selection { open(page: selection, anchor: anchor) }
            return .handled
        case .external?:
            return .systemAction
        case nil:
            return .discarded
        }
    }
}
