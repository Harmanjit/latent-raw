import SwiftUI
import AppKit

// MARK: - Fly-out geometry

/// The window edges that bring a panel in while the image fills the
/// screen: the library panel from the left, Develop's adjustments from the
/// right, the filmstrip from the bottom. The top is left to the menu bar,
/// which full screen reveals there.
enum FlyoutEdge: CaseIterable, Hashable {
    case left, right, bottom
}

/// Which edge the pointer touches and where panels sit, as plain rectangle
/// arithmetic so it is tested without a window (minivu's FlyoutGeometry).
/// SwiftUI's coordinates: origin top left, y down, in points.
enum FlyoutGeometry {
    /// How close to an edge the pointer must come. Small, so passing near
    /// an edge while panning doesn't throw a panel over the image.
    static let triggerDistance: CGFloat = 4

    /// The edge among `available` the pointer is touching, or nil. In a
    /// corner the nearer edge wins, and the filmstrip wins a tie.
    static func edge(at point: CGPoint, in size: CGSize, available: Set<FlyoutEdge>,
                     threshold: CGFloat = triggerDistance) -> FlyoutEdge? {
        guard size.width > 0, size.height > 0,
              point.x >= -threshold, point.x <= size.width + threshold,
              point.y >= -threshold, point.y <= size.height + threshold else { return nil }
        let distances: [(FlyoutEdge, CGFloat)] = [
            (.bottom, size.height - point.y), (.left, point.x), (.right, size.width - point.x),
        ]
        return distances
            .filter { available.contains($0.0) && $0.1 <= threshold }
            .min { $0.1 < $1.1 }?.0
    }

    /// Where the panel for `edge` sits while it shows: flush with its edge,
    /// the side panels full height, the filmstrip full width.
    static func frame(for edge: FlyoutEdge, thickness: CGFloat, in size: CGSize) -> CGRect {
        switch edge {
        case .left: CGRect(x: 0, y: 0, width: thickness, height: size.height)
        case .right: CGRect(x: size.width - thickness, y: 0, width: thickness, height: size.height)
        case .bottom: CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness)
        }
    }

    /// The panel to show after the pointer moved to `point`: the open one
    /// while the pointer is over it (or still against its edge), else the
    /// panel of an edge it touches, else none. One panel at a time.
    static func openEdge(after current: FlyoutEdge?, pointer point: CGPoint, in size: CGSize,
                         thickness: [FlyoutEdge: CGFloat], available: Set<FlyoutEdge>) -> FlyoutEdge? {
        if let current, available.contains(current), let width = thickness[current] {
            let hover = frame(for: current, thickness: width, in: size)
                .insetBy(dx: -triggerDistance, dy: -triggerDistance)
            if hover.contains(point) { return current }
        }
        return edge(at: point, in: size, available: available)
    }
}

// MARK: - What full-screen image mode shows

/// The rules of full-screen image mode, apart from any window.
@MainActor
enum FullScreenImagePolicy {
    /// The mode the image is shown in. It is for looking at one image, so
    /// the grid (and Compare) go to Loupe first; Develop stays Develop.
    static func entryMode(from mode: AppMode) -> AppMode {
        mode == .develop ? .develop : .loupe
    }

    /// Whether the mode keeps the image full screen. Going to the grid or
    /// Compare leaves it.
    static func keepsFullScreen(in mode: AppMode) -> Bool {
        mode == .loupe || mode == .develop
    }

    /// The panels that can fly out in `mode`. Only Develop has adjustments,
    /// and the filmstrip needs a folder.
    static func availableEdges(mode: AppMode, hasFolder: Bool) -> Set<FlyoutEdge> {
        var edges: Set<FlyoutEdge> = [.left]
        if mode == .develop { edges.insert(.right) }
        if hasFolder { edges.insert(.bottom) }
        return edges
    }

    /// Whether a panel stays built, off screen, once it has shown. Develop's
    /// adjustments do, so the panel keeps its scroll position and open
    /// groups; the library panel and filmstrip go when they close, taking
    /// their thumbnail loads with them.
    static func keepsPanel(_ edge: FlyoutEdge) -> Bool {
        edge == .right
    }

    /// Panel thicknesses in points: the library panel's 220 and Develop's
    /// 280 (as ContentView lays them out) plus a hairline, and the filmstrip.
    static let thickness: [FlyoutEdge: CGFloat] = [
        .left: 221, .right: 281, .bottom: FilmstripView.height + 1,
    ]
}

// MARK: - The mode itself

/// Full-screen image mode (F): the main window goes full screen with only
/// the image in it, and panels fly out from the edges as the pointer
/// reaches them.
///
/// The window uses the system's own full screen rather than a borderless
/// window: the main window is SwiftUI's, and a borderless SwiftUI window
/// can't be relied on to take the keyboard. The system's full screen also
/// keeps the image below a notch (the safe area), and it cross-fades rather
/// than slides under Reduce Motion. A window already full screen when F is
/// pressed only loses its panels, and stays full screen after.
///
/// Held for the process, like `MainWindowModels`, so the snapshot harness
/// can reach it.
@MainActor
final class FullScreenImageMode: ObservableObject {
    static let shared = FullScreenImageMode()

    @Published private(set) var isActive = false
    /// The panel showing, if any.
    @Published private(set) var openEdge: FlyoutEdge?
    /// Panels kept after they first showed (see
    /// `FullScreenImagePolicy.keepsPanel`). A panel never shown is never built.
    @Published private(set) var builtEdges: Set<FlyoutEdge> = []

    private weak var window: NSWindow?
    /// Set when entering made the window full screen, so leaving undoes it.
    private var enteredSystemFullScreen = false
    /// Between asking the window to go full screen and its arrival, when
    /// it can't be asked to come back.
    private var animatingIn = false
    private var observers: [any NSObjectProtocol] = []

    /// `window` goes full screen (unless it already is).
    func enter(window: NSWindow?) {
        guard !isActive else { return }
        isActive = true
        openEdge = nil
        builtEdges = []
        self.window = window
        Announcement.post("Full-screen image. Move the pointer to the left, right or bottom edge for panels; F or Escape leaves.")
        guard let window else { return }
        removeObservers()
        let center = NotificationCenter.default
        observers = [
            // Leaving full screen some other way (the green button, ⌃⌘F)
            // brings the panels back.
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemFullScreenEnded() }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemFullScreenArrived() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.leave() }
            },
        ]
        #if DEBUG
        // A snapshot run pictures the layout without taking over the screen.
        if SnapshotHarness.isActive { return }
        #endif
        if !window.styleMask.contains(.fullScreen) {
            enteredSystemFullScreen = true
            animatingIn = true
            window.toggleFullScreen(nil)
        }
    }

    /// Back to the window as it was, panels and all.
    func leave() {
        guard isActive else { return }
        isActive = false
        openEdge = nil
        builtEdges = []
        // Still animating in: it comes back once it has arrived.
        guard !animatingIn else { return }
        removeObservers()
        if enteredSystemFullScreen, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredSystemFullScreen = false
    }

    /// Shows the panel for `edge`, or none. Every change goes through here.
    func show(_ edge: FlyoutEdge?, animated: Bool = true) {
        guard isActive, edge != openEdge else { return }
        let change = {
            if let edge, FullScreenImagePolicy.keepsPanel(edge) { self.builtEdges.insert(edge) }
            self.openEdge = edge
        }
        if animated {
            withAnimation(Motion.animation(.easeOut(duration: 0.18))) { change() }
        } else {
            change()
        }
    }

    /// The pointer moved to `point` in a view of `size`.
    func pointerMoved(to point: CGPoint, in size: CGSize, available: Set<FlyoutEdge>) {
        guard isActive else { return }
        show(FlyoutGeometry.openEdge(after: openEdge, pointer: point, in: size,
                                     thickness: FullScreenImagePolicy.thickness, available: available))
    }

    private func systemFullScreenArrived() {
        animatingIn = false
        // F again (or Esc) while it was on its way.
        guard !isActive else { return }
        removeObservers()
        if enteredSystemFullScreen, let window { window.toggleFullScreen(nil) }
        enteredSystemFullScreen = false
    }

    private func systemFullScreenEnded() {
        animatingIn = false
        enteredSystemFullScreen = false
        leave()
        removeObservers()
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

// MARK: - Views

/// Reports the pointer's movement over the view it backs, without taking
/// any clicks: a tracking area only, which sends nothing while the pointer
/// is still, so an idle full-screen image costs nothing.
struct PointerTracker: NSViewRepresentable {
    var onMove: @MainActor (CGPoint, CGSize) -> Void
    var onExit: @MainActor () -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onMove = onMove
        view.onExit = onExit
    }

    final class TrackerView: NSView {
        var onMove: (@MainActor (CGPoint, CGSize) -> Void)?
        var onExit: (@MainActor () -> Void)?

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("made in code") }

        /// Clicks go to the image and panels above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil), bounds.size)
        }

        override func mouseEntered(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil), bounds.size)
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}

/// One fly-out panel over the full-screen image: built the first time it
/// shows, then slid (or, under Reduce Motion, faded) in and out.
struct FlyoutPanel<Content: View>: View {
    let edge: FlyoutEdge
    @ObservedObject var mode: FullScreenImageMode
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { mode.openEdge == edge }

    var body: some View {
        if isOpen || mode.builtEdges.contains(edge) {
            content()
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: hairlineAlignment) { hairline }
                // A kept panel slides out of sight; under Reduce Motion it
                // fades where it stands.
                .offset(isOpen || reduceMotion ? .zero : closedOffset)
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
                .accessibilityHidden(!isOpen)
                .transition(reduceMotion ? .opacity : .move(edge: moveEdge).combined(with: .opacity))
        }
    }

    private var moveEdge: Edge {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
        }
    }

    /// Just past its edge, where the panel slides in from.
    private var closedOffset: CGSize {
        let thickness = FullScreenImagePolicy.thickness[edge] ?? 0
        return switch edge {
        case .left: CGSize(width: -thickness, height: 0)
        case .right: CGSize(width: thickness, height: 0)
        case .bottom: CGSize(width: 0, height: thickness)
        }
    }

    private var hairlineAlignment: Alignment {
        switch edge {
        case .left: .trailing
        case .right: .leading
        case .bottom: .top
        }
    }

    @ViewBuilder private var hairline: some View {
        if edge == .bottom { Divider() } else { Divider().frame(maxHeight: .infinity) }
    }
}

extension View {
    /// The full-screen image's fly-out panels and the pointer tracking that
    /// opens them, over this view (ContentView's main area). Nothing is
    /// added while the mode is off.
    func fullScreenFlyouts<Left: View, Right: View, Bottom: View>(
        _ mode: FullScreenImageMode, available: Set<FlyoutEdge>,
        @ViewBuilder left: @escaping () -> Left,
        @ViewBuilder right: @escaping () -> Right,
        @ViewBuilder bottom: @escaping () -> Bottom
    ) -> some View {
        modifier(FullScreenFlyouts(mode: mode, available: available, left: left, right: right, bottom: bottom))
    }
}

private struct FullScreenFlyouts<Left: View, Right: View, Bottom: View>: ViewModifier {
    @ObservedObject var mode: FullScreenImageMode
    let available: Set<FlyoutEdge>
    let left: () -> Left
    let right: () -> Right
    let bottom: () -> Bottom

    func body(content: Content) -> some View {
        content
            .background {
                if mode.isActive {
                    PointerTracker(onMove: { point, size in
                        mode.pointerMoved(to: point, in: size, available: available)
                    }, onExit: { mode.show(nil) })
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .leading) {
                if mode.isActive, available.contains(.left) {
                    FlyoutPanel(edge: .left, mode: mode, content: left)
                }
            }
            .overlay(alignment: .trailing) {
                if mode.isActive, available.contains(.right) {
                    FlyoutPanel(edge: .right, mode: mode, content: right)
                }
            }
            .overlay(alignment: .bottom) {
                if mode.isActive, available.contains(.bottom) {
                    FlyoutPanel(edge: .bottom, mode: mode, content: bottom)
                }
            }
            // The edges can't be reached without a pointer; VoiceOver and
            // Full Keyboard Access users open the panels from here.
            .accessibilityActions {
                if mode.isActive {
                    if available.contains(.left) {
                        Button(mode.openEdge == .left ? "Hide Library Panel" : "Show Library Panel") { toggle(.left) }
                    }
                    if available.contains(.right) {
                        Button(mode.openEdge == .right ? "Hide Adjustments" : "Show Adjustments") { toggle(.right) }
                    }
                    if available.contains(.bottom) {
                        Button(mode.openEdge == .bottom ? "Hide Filmstrip" : "Show Filmstrip") { toggle(.bottom) }
                    }
                }
            }
    }

    private func toggle(_ edge: FlyoutEdge) {
        mode.show(mode.openEdge == edge ? nil : edge)
    }
}
