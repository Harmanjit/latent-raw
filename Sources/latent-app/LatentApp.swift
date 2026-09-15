import SwiftUI
import AppKit
import Catalog
import PixelEngine

/// Latent's application target.
///
/// Runs as a SwiftPM executable rather than an Xcode project, so `swift run`
/// keeps working and there's no .xcodeproj to maintain alongside
/// Package.swift; scripts/make_app.sh wraps the same binary in a .app.
///
/// One window, not a WindowGroup: two windows on the same folder would
/// write the same catalog and sidecars over each other. There is no New
/// Window, and the Window menu brings this one back, with the editor,
/// library and export queue it had (`MainWindowModels`).
@main
struct LatentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    @ObservedObject private var prefs = AppPreferences.shared

    static let mainWindowID = "main"

    var body: some Scene {
        Window("Latent, a catalog management and RAW editor for macOS", id: Self.mainWindowID) {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .tint(prefs.accent.color)
                .background(MainWindowOpener())
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            LatentCommands()
            HelpCommands()
        }

        Settings {
            PreferencesView()
                .tint(prefs.accent.color)
                .motionFollowsAccessibility()
        }
    }
}

/// Hands the app delegate a way to open the main window, which only a
/// view's environment has.
private struct MainWindowOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                let open = openWindow
                AppDelegate.showMainWindow = { open(id: LatentApp.mainWindowID) }
            }
    }
}

/// The main window's editor, library and export queue, built once for the
/// process rather than by the window. SwiftUI builds a Window scene's view
/// state afresh when the window is closed and opened again (from the Dock,
/// say, after Keep Exporting cancelled the quit that closing it started),
/// and a second set would run beside the first: the running export with no
/// progress or Cancel on screen and Export enabled again, the same catalog
/// opened twice, and the old image session holding its memory.
@MainActor
final class MainWindowModels {
    static let shared = MainWindowModels()

    let model = EditorModel()
    let library = LibrarySortDefaults.attached(to: Library())
    let exportQueue = ExportQueue()
    /// Set once the first window has opened the launch folder or file; a
    /// window opened again finds everything as it was left.
    var openedAtLaunch = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window first appears.
    static var showMainWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Window tabs would offer a second window by another route.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Clicking the Dock icon brings the window forward, or back if it was
    /// closed while Settings stayed open (closing it alone quits). Opening
    /// a Window scene that is already open only brings it to the front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow?()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run with `swift run`, without a .app bundle, the process launches
        // as a background accessory and the window never comes forward.
        // Promoting it to a regular app fixes that; harmless when bundled.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppPreferences.shared.applyAppearance()
    }

    /// Closing the last window quits through `terminate`, so it takes the
    /// same careful path as Cmd-Q below.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Quitting without losing work

    /// What a window holds that quitting must not cut short. ContentView
    /// registers them (from `MainWindowModels`) when it appears.
    private struct WindowWork {
        let model: EditorModel
        let library: Library
        let exportQueue: ExportQueue
    }

    /// Held strongly on purpose: closing the last window can release the
    /// view's objects before AppKit asks whether to terminate, and an
    /// edit still waiting for its save would go with them. The window
    /// reopened registers the same objects again, which adds nothing.
    private static var windows: [WindowWork] = []

    /// Called by ContentView when it appears.
    static func register(model: EditorModel, library: Library, exportQueue: ExportQueue) {
        guard !windows.contains(where: { $0.model === model }) else { return }
        windows.append(WindowWork(model: model, library: library, exportQueue: exportQueue))
    }

    /// How long quitting waits for catalog writes (ratings, keywords, the
    /// edit flushed below). They take milliseconds; this only stops a
    /// stuck one, on a hung network volume say, from blocking quit forever.
    static let catalogWaitLimit: Duration = .seconds(10)
    /// How long quitting waits for the export file being written. Longer,
    /// because one full-size render with AI noise reduction can take tens
    /// of seconds, and stopping short would leave that file half-written.
    static let exportWaitLimit: Duration = .seconds(60)

    /// Quitting must not lose work. Three things can be at risk:
    ///
    /// 1. An edit made less than a second ago, not yet saved: saved now.
    /// 2. Catalog writes still running (that save, a rating, keywords,
    ///    snapshots): waited for, so the XMP sidecar and the database
    ///    both have them.
    /// 3. An export under way: ask whether to stop after the current file
    ///    and quit, or keep exporting and not quit. Export Open Image is one
    ///    file, so for it the choice is to let it finish and quit.
    ///
    /// `.terminateLater` keeps the app alive until `reply` is called.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = Self.windows
        let exporting = windows.map(\.exportQueue).filter(\.isRunning)
        let exportingOpenImage = windows.map(\.model).filter(\.isExporting)
        if !exporting.isEmpty || !exportingOpenImage.isEmpty,
           !confirmStoppingExports(exporting, openImage: !exportingOpenImage.isEmpty) {
            return .terminateCancel
        }
        // Saving goes through Library.perform, so from here on the flushed
        // edit counts as pending work below.
        for window in windows { window.model.flushPendingSave() }
        let libraries = windows.map(\.library)
        guard !exporting.isEmpty || !exportingOpenImage.isEmpty || libraries.contains(where: \.hasPendingWork) else {
            return .terminateNow
        }
        Task {
            // Exports first. Catalog writes carry on while the current file
            // finishes, so waiting for them afterwards is usually instant.
            for queue in exporting {
                if await !Self.finishes(within: Self.exportWaitLimit, queue.stopAfterCurrentFile) {
                    Log.export.error("Quit: the export file being written did not finish within \(Self.exportWaitLimit, privacy: .public); quitting anyway")
                }
            }
            for model in exportingOpenImage {
                if await !Self.finishes(within: Self.exportWaitLimit, model.waitForExport) {
                    Log.export.error("Quit: Export Open Image did not finish within \(Self.exportWaitLimit, privacy: .public); quitting anyway")
                }
            }
            for library in libraries {
                if await !Self.finishes(within: Self.catalogWaitLimit, library.waitForPendingWork) {
                    Log.catalog.error("Quit: catalog writes did not finish within \(Self.catalogWaitLimit, privacy: .public); quitting anyway")
                }
            }
            // An export still writing is cut short by the exit: remove its
            // hidden temporary file now, or nothing ever would.
            let abandoned = SafeFileWriter.abandonPendingWrites()
            if abandoned > 0 {
                Log.export.error("Quit: removed \(abandoned, privacy: .public) unfinished export file(s)")
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Asks before cutting an export short, or waiting for Export Open
    /// Image (`openImage`). Returns whether to quit.
    private func confirmStoppingExports(_ queues: [ExportQueue], openImage: Bool) -> Bool {
        let done = queues.reduce(0) { $0 + $1.done }
        let total = queues.reduce(0) { $0 + $1.total }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if queues.isEmpty {
            alert.messageText = "Latent is still exporting the open image"
            alert.informativeText = "Quitting now waits for its file to be written, then quits."
            alert.addButton(withTitle: "Finish Exporting and Quit")
        } else {
            alert.messageText = "Latent is still exporting (\(done) of \(total) done)"
            alert.informativeText = "Quitting now finishes the image being written and skips the rest. "
                + (openImage ? "The open image being exported is finished too. " : "")
                + "Files already exported stay where they are."
            alert.addButton(withTitle: "Stop After This Image and Quit")
        }
        let keep = alert.addButton(withTitle: queues.isEmpty ? "Keep Working" : "Keep Exporting")
        keep.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Runs `work` and returns true if it finished within `limit`, false if
    /// the limit passed first. The work isn't cancelled on timeout (neither
    /// wait here can be), but the app is about to exit anyway.
    private static func finishes(within limit: Duration,
                                 _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let outcome = WaitOutcome()
        return await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            Task { @MainActor in
                await work()
                outcome.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                outcome.resume(false)
            }
        }
    }

    /// Whichever of the work and the timer ends first resumes the waiter;
    /// the other finds it already resumed. Main-actor, so no race.
    @MainActor private final class WaitOutcome {
        var continuation: CheckedContinuation<Bool, Never>?
        func resume(_ finished: Bool) {
            continuation?.resume(returning: finished)
            continuation = nil
        }
    }
}
