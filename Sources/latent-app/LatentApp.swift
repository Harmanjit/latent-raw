import SwiftUI
import AppKit

/// Latent's application target.
///
/// Runs as a SwiftPM executable rather than an Xcode project, so `swift run`
/// keeps working and there's no .xcodeproj to maintain alongside
/// Package.swift. The tradeoff is no proper .app bundle yet: no custom icon,
/// no Dock persistence, limited menu bar. Worth adding a real bundle before
/// any release, but it would only slow development down now.
@main
struct LatentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Latent, a catalog management and RAW editor for macOS") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without a .app bundle the process launches as a background
        // accessory and the window never comes forward. Promoting it to a
        // regular app fixes that; unnecessary once bundled properly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
