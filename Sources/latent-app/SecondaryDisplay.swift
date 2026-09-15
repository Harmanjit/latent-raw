import SwiftUI
import AppKit
import Catalog
import PixelEngine

// MARK: - Screens, as plain values

/// One connected screen, as the second display's Loupe needs to know it. A
/// plain value rather than `NSScreen`, which a test can't make.
struct ScreenInfo: Equatable {
    /// `CGDirectDisplayID`: stays the same while the display is connected,
    /// through resolution and arrangement changes, which the frame doesn't.
    var id: UInt32
    /// Global screen coordinates, origin bottom left.
    var frame: CGRect
    /// The frame less the menu bar and the Dock.
    var visibleFrame: CGRect
    /// The camera housing strip of a notched display; zero elsewhere.
    var safeAreaTop: CGFloat = 0
}

extension ScreenInfo {
    @MainActor init(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.init(id: number?.uint32Value ?? 0, frame: screen.frame, visibleFrame: screen.visibleFrame,
                  safeAreaTop: screen.safeAreaInsets.top)
    }
}

/// Which screen the Loupe goes to and where on it the picture sits, as
/// arithmetic on `ScreenInfo` so it is tested without displays.
enum SecondaryDisplayPlacement {
    /// A screen other than the main window's: the first of them from the
    /// left, as they sit on the desk. Nil when there is no other.
    static func target(screens: [ScreenInfo], mainWindowScreen: UInt32?) -> ScreenInfo? {
        screens
            .filter { $0.id != mainWindowScreen }
            .sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.maxY > $1.frame.maxY }
            .first
    }

    /// The connected screen with this id, with its current frames; nil once
    /// it has been disconnected.
    static func connected(_ id: UInt32, in screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first { $0.id == id }
    }

    /// How far the picture keeps in from each edge of the screen, in
    /// points: clear of that screen's menu bar (or camera housing) and its
    /// Dock, which a window at the normal level sits under. The surround
    /// colour fills the strips.
    static func contentInsets(for screen: ScreenInfo) -> EdgeInsets {
        let frame = screen.frame, visible = screen.visibleFrame
        return EdgeInsets(top: max(screen.safeAreaTop, frame.maxY - visible.maxY, 0),
                          leading: max(visible.minX - frame.minX, 0),
                          bottom: max(visible.minY - frame.minY, 0),
                          trailing: max(frame.maxX - visible.maxX, 0))
    }
}

/// The render decisions the second display adds to the editor's, as plain
/// arithmetic.
///
/// The Loupe there draws the editor's own preview, so nothing is decoded or
/// rendered twice; instead the one preview is rendered to suit both screens.
enum SecondaryPreview {
    /// How many sensor quads the preview bins, given the main view's zoom
    /// and the second display's fit zoom (nil for a view not laid out).
    /// Each view wants half a quad or less per screen pixel, as the editor
    /// always asked; the finer of the two wins, so neither is soft.
    static func previewQuads(mainZoom: CGFloat?, secondaryZoom: CGFloat?) -> Int {
        [mainZoom, secondaryZoom]
            .compactMap { $0 }
            .filter { $0 > 0 && $0.isFinite }
            .map { max(1, Int((1 / $0) / 2)) }
            .min() ?? 1
    }

    /// The potential headroom the preview is rendered for: the larger of
    /// the main view's screen and the second display's. The presenter rolls
    /// highlights off to what each screen shows at the moment, as it does
    /// for brightness, so HDR on either screen is real HDR.
    static func renderPotential(main: CGFloat, secondary: CGFloat?) -> CGFloat {
        max(main, secondary ?? 1)
    }
}

extension EditorModel {
    /// The zoom that fits the image to the second display, when it shows.
    var secondaryFitZoom: CGFloat? {
        guard hasImage, secondaryDrawableSize.width > 0, secondaryDrawableSize.height > 0 else { return nil }
        return ViewportTransform.fitZoom(imageSize: imageSize, drawableSize: secondaryDrawableSize)
    }

    /// The second display's image view has this drawable size. Renders only
    /// if the preview is now too coarse for it.
    func secondaryViewportDidResize(to size: CGSize) {
        guard size != secondaryDrawableSize else { return }
        secondaryDrawableSize = size
        if hasImage { rerenderForViewport() }
    }

    /// The second display's potential headroom, or nil once it has closed.
    /// Renders again only if the ceiling the pipeline uses moves.
    func secondaryDisplayHeadroomDidChange(to headroom: CGFloat?) {
        guard headroom != secondaryDisplayHeadroom else { return }
        let renderedBefore = displayOutput.headroom
        secondaryDisplayHeadroom = headroom
        if hasImage && displayOutput.headroom != renderedBefore { rerender() }
    }

    /// The Loupe on the second display closed. A finer preview it asked
    /// for stays until the next render: rendering a coarser one now would
    /// be work for nothing.
    func secondaryDisplayDidClose() {
        secondaryDrawableSize = .zero
        secondaryDisplayHeadroomDidChange(to: nil)
    }
}

// MARK: - The window

/// Loupe on a second display: a borderless window filling another screen
/// that shows the editor's image as the main window's Loupe would, while
/// the main window keeps the grid, Compare or Develop.
///
/// It draws the main editor model's preview with its own fit, so edits and
/// selection changes appear on it as they are made, and nothing is decoded
/// or rendered a second time (see `SecondaryPreview`). The window never
/// becomes key: keys and menus stay with the main window. It closes when
/// its display is disconnected or the main window closes, and follows a
/// resolution change.
@MainActor
final class SecondaryDisplay: ObservableObject {
    static let shared = SecondaryDisplay()

    @Published private(set) var isShowing = false
    /// More than one screen is connected, so there is somewhere to show it.
    @Published private(set) var hasSecondScreen = NSScreen.screens.count > 1
    /// Where the picture keeps in from the window's edges.
    @Published private(set) var contentInsets = EdgeInsets()

    private var window: NSWindow?
    private var screenID: UInt32?
    private weak var model: EditorModel?
    private var screenObserver: (any NSObjectProtocol)?
    private var mainWindowObserver: (any NSObjectProtocol)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Opens the Loupe on a screen other than `mainWindow`'s. Does nothing
    /// with only one screen (except in a snapshot run, which opens it in a
    /// window of `debugSize` on the one screen there is).
    func show(model: EditorModel, library: Library, beside mainWindow: NSWindow?, debugSize: CGSize? = nil) {
        guard !isShowing else { return }
        let screens = NSScreen.screens.map(ScreenInfo.init)
        let frame: CGRect
        if let target = SecondaryDisplayPlacement.target(screens: screens, mainWindowScreen: mainWindow?.screen.map(ScreenInfo.init)?.id) {
            frame = target.frame
            screenID = target.id
            contentInsets = SecondaryDisplayPlacement.contentInsets(for: target)
        } else if let debugSize, let screen = NSScreen.main {
            frame = CGRect(origin: CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY - debugSize.height),
                           size: debugSize)
            screenID = nil
            contentInsets = EdgeInsets()
        } else {
            return
        }
        self.model = model
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = false
        // On every Space of that display, and beside a full-screen window.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = NSColor(white: AppPreferences.shared.surround.level, alpha: 1)
        window.setAccessibilityLabel("Loupe on second display")
        let host = NSHostingView(rootView: SecondaryLoupeView(model: model, library: library, display: self))
        // The window is the screen's size, whatever the content would like.
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(frame, display: false)
        window.orderFront(nil)
        self.window = window
        isShowing = true

        if let mainWindow {
            mainWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: mainWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        guard isShowing else { return }
        isShowing = false
        if let mainWindowObserver { NotificationCenter.default.removeObserver(mainWindowObserver) }
        mainWindowObserver = nil
        // Taking the content down stops its image view's display link.
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        screenID = nil
        model?.secondaryDisplayDidClose()
        model = nil
    }

    /// The window being pictured by a snapshot run.
    var debugWindow: NSWindow? { window }

    /// A display connected or disconnected, or a resolution changed.
    private func screensChanged() {
        let screens = NSScreen.screens.map(ScreenInfo.init)
        if hasSecondScreen != (screens.count > 1) { hasSecondScreen = screens.count > 1 }
        guard isShowing, let screenID, let window else { return }
        guard let screen = SecondaryDisplayPlacement.connected(screenID, in: screens) else {
            close()
            Announcement.post("The second display was disconnected, so its Loupe has closed.")
            return
        }
        let insets = SecondaryDisplayPlacement.contentInsets(for: screen)
        if insets != contentInsets { contentInsets = insets }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
    }
}

/// What the second display's window shows: the image, fitted, over the
/// surround, with the Loupe's caption under it.
struct SecondaryLoupeView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var library: Library
    @ObservedObject var display: SecondaryDisplay
    @ObservedObject private var prefs = AppPreferences.shared
    /// The image view's drawable, in pixels, for the fit.
    @State private var drawableSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                prefs.surroundColor
                if let device = model.device, let presenter = model.presenter, let preview = model.preview, model.hasImage {
                    let model = model
                    MetalImageView(preview: preview,
                                   tile: nil,
                                   transform: .fit(imageSize: model.imageSize, drawableSize: drawableSize),
                                   frame: model.frame,
                                   presenter: presenter,
                                   device: device,
                                   onResize: { size in
                                       drawableSize = size
                                       model.secondaryViewportDidResize(to: size)
                                   },
                                   onHeadroomChange: { model.secondaryDisplayHeadroomDidChange(to: $0) },
                                   backgroundLevel: prefs.surroundLinear,
                                   // A view to look at: zoom, pan and the tools stay in the main window.
                                   onZoom: { _, _ in }, onPan: { _ in }, onDoubleClick: { _ in },
                                   atFit: true, onStep: nil,
                                   allowsMagnifier: false, magnifierTile: nil, onMagnifier: { _ in },
                                   toolActive: false,
                                   onToolBegan: { _, _ in }, onToolMoved: { _ in }, onToolEnded: {})
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityLabel(model.imageTitle ?? "Image")
                        .accessibilityValue(model.showingBefore ? "Loupe on second display, before editing" : "Loupe on second display")
                } else {
                    Text(model.isReady ? "No image open" : "Starting…")
                        .foregroundStyle(.secondary)
                }
            }
            ImageCaption(record: library.selectedImage)
        }
        .padding(display.contentInsets)
        .background(prefs.surroundColor)
        .motionFollowsAccessibility()
    }
}
