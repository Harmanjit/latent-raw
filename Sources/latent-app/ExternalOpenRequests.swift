import Foundation
import Catalog

/// Files and folders the system asks Latent to open: Finder's Open With,
/// a drop on the Dock icon, `open -a Latent file.NEF`, and a path given on
/// the command line, which AppKit turns into the same open-documents
/// request (`AppDelegate.application(_:openFiles:)`).
///
/// The event can arrive before the window exists (at launch, or after the
/// window was closed while Settings stayed open) or while it is showing.
/// Before, the item waits here and the window is asked to open; the
/// window takes it as it appears (`takeLaunchTarget` at launch, `attach`
/// afterwards). While it shows, the window's handler opens it at once.
@MainActor
final class ExternalOpenRequests {
    static let shared = ExternalOpenRequests()

    /// How long after the launch opened an item the same item arriving as
    /// an event is taken for that launch's own copy and dropped. AppKit
    /// delivers a command-line path as an event during launch; the window
    /// has normally taken it by then, but the order is AppKit's to choose.
    static let launchEchoWindow: TimeInterval = 5

    /// The item waiting for a window. Only the newest is kept: the window
    /// shows one image and one catalog.
    private(set) var pending: LaunchArguments.Target?
    /// The window's way to open an item, while the window is showing.
    private var handler: (@MainActor (LaunchArguments.Target) -> Void)?
    /// What the launch opened and when, to drop its echo (see above).
    private var launched: (target: LaunchArguments.Target, at: Date)?
    /// Asks for the window when an item arrives with none showing.
    var showWindow: @MainActor () -> Void = { AppDelegate.openMainWindowForExternalItem() }
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// An open-documents event. Opened by the window if it is showing;
    /// otherwise kept for it, and the window is asked to open.
    func receive(_ urls: [URL]) {
        guard let target = LaunchArguments.target(for: urls) else { return }
        if let launched, launched.target == target, now().timeIntervalSince(launched.at) < Self.launchEchoWindow {
            self.launched = nil
            return
        }
        if let handler {
            handler(target)
        } else {
            pending = target
            showWindow()
        }
    }

    /// The item the window opens as it first appears: an event's item if
    /// one arrived during launch, else the command line's. Called once.
    func takeLaunchTarget(arguments: [String]) -> LaunchArguments.Target? {
        let target = LaunchArguments.launchTarget(pendingEvent: pending, arguments: arguments)
        pending = nil
        if let target { launched = (target, now()) }
        return target
    }

    /// The window is showing and opens items with `open` from now on,
    /// starting with one that arrived while it was away.
    func attach(_ open: @escaping @MainActor (LaunchArguments.Target) -> Void) {
        handler = open
        if let waiting = pending {
            pending = nil
            open(waiting)
        }
    }

    /// The window closed: items wait for it again.
    func detach() {
        handler = nil
    }
}
