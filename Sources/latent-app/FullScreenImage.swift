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

// MARK: - Following the window's own full screen

/// Full-screen image mode against its window's full screen, apart from
/// any window, so every interleaving of F, Esc, the green button and the
/// window's animations is tested.
///
/// The window's notifications are the truth, and the window is asked to
/// change only while it is still, because AppKit takes no request during
/// an animation: a toggle on the way in is ignored (even from inside
/// didEnter), and a toggle on the way out posts didExit at once and
/// willEnter, then drops the enter and puts the window back with no
/// notification (only the window's delegate, SwiftUI's, hears of it).
/// So F on the way out waits for the window to be out and then takes it
/// back in, and F on the way in takes it out once it has arrived.
struct FullScreenImageState: Equatable {
    enum Phase: Equatable {
        case windowed, entering, fullScreen, exiting

        var isAnimating: Bool { self == .entering || self == .exiting }
    }

    enum Event: Equatable {
        /// F. `drivesWindow` is false without a window, or in a snapshot
        /// run that pictures only the layout.
        case enter(drivesWindow: Bool)
        /// F again, Esc, or going to the grid or Compare.
        case leave
        case willEnter, didEnter
        /// `byMode` when the mode's own request posted it.
        case willExit(byMode: Bool)
        case didExit
        /// The window stopped an animation short, or ignored a request,
        /// and is full screen or not as `isFullScreen` says.
        case failed(isFullScreen: Bool)
        case closed
    }

    private(set) var phase: Phase
    /// The image alone, panels flying out.
    private(set) var isActive = false
    /// The mode made the window full screen, or is making it so, and
    /// leaving takes it out again. A window full screen (or on its way)
    /// by other means stays full screen after.
    private(set) var ownsFullScreen = false

    init(phase: Phase = .windowed) {
        self.phase = phase
    }

    /// Whether the window is to be asked to go in or out now.
    var needsToggle: Bool {
        guard ownsFullScreen else { return false }
        switch phase {
        case .windowed: return isActive
        case .fullScreen: return !isActive
        case .entering, .exiting: return false
        }
    }

    /// The mode is on and the window is where it will stay.
    var hasArrived: Bool { isActive && !phase.isAnimating && !needsToggle }

    mutating func handle(_ event: Event) {
        switch event {
        case .enter(let drivesWindow):
            guard !isActive else { return }
            isActive = true
            if drivesWindow, phase == .windowed || phase == .exiting { ownsFullScreen = true }
        case .leave:
            isActive = false
        case .willEnter:
            phase = .entering
        case .didEnter:
            phase = .fullScreen
        case .willExit(let byMode):
            phase = .exiting
            // Leaving full screen some other way (the green button, ⌃⌘F)
            // brings the panels back as it starts.
            if !byMode { isActive = false }
        case .didExit:
            phase = .windowed
        case .failed(let isFullScreen):
            phase = isFullScreen ? .fullScreen : .windowed
            // No image alone in a window; and no asking again, which could
            // go on failing.
            if !isFullScreen { isActive = false }
            if !isActive { ownsFullScreen = false }
        case .closed:
            phase = .windowed
            isActive = false
        }
        if !isActive, phase == .windowed || phase == .exiting { ownsFullScreen = false }
    }
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
/// pressed only loses its panels, and stays full screen after. The mode
/// follows the window's real full screen (`FullScreenImageState`).
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

    private(set) var state = FullScreenImageState()
    private weak var window: NSWindow?
    /// Windows part way into or out of full screen, from their
    /// notifications, watched from the start so F pressed during an
    /// animation that began before it is not taken for a still window.
    private var animating: [ObjectIdentifier: (phase: FullScreenImageState.Phase, since: Date)] = [:]
    /// While the mode's own request runs, to tell its notifications from
    /// the green button's.
    private var isToggling = false
    private var animationStarted = Date.distantPast
    private var animationCheck: Timer?
    private let observers = ObserverTokens()

    /// How long an animation may go without its did notification before
    /// the window's style mask is taken as where it ended.
    static let animationTimeout: TimeInterval = 5

    init() {
        let center = NotificationCenter.default
        let events: [(Notification.Name, FullScreenImageState.Event)] = [
            (NSWindow.willEnterFullScreenNotification, .willEnter),
            (NSWindow.didEnterFullScreenNotification, .didEnter),
            (NSWindow.willExitFullScreenNotification, .willExit(byMode: false)),
            (NSWindow.didExitFullScreenNotification, .didExit),
            (NSWindow.willCloseNotification, .closed),
        ]
        // Delivered as posted (AppKit posts on the main thread), so the
        // notifications of the mode's own request arrive during it.
        observers.tokens = events.map { name, event in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.window(window, posted: event) }
            }
        }
    }

    /// Whether the window is where entering asked it to be, not still on
    /// its way to (or, first, out of) full screen.
    var hasArrived: Bool { state.hasArrived }

    /// `window` goes full screen (unless it already is).
    func enter(window: NSWindow?) {
        guard !isActive else { return }
        if self.window == nil || window !== self.window { track(window) }
        var drivesWindow = window != nil
        #if DEBUG
        // A snapshot run pictures the layout without taking over the screen,
        // unless it was asked to.
        if SnapshotHarness.isActive, !SnapshotHarness.usesSystemFullScreen { drivesWindow = false }
        #endif
        Announcement.post("Full-screen image. Move the pointer to the left, right or bottom edge for panels; F or Escape leaves.")
        apply(.enter(drivesWindow: drivesWindow))
    }

    /// Back to the window as it was, panels and all: at once, or once the
    /// window has arrived if it is still on its way in.
    func leave() {
        guard isActive else { return }
        apply(.leave)
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

    /// Catches an animation the window gave up without a notification (it
    /// tells only its delegate), or one whose notification never came.
    /// Run every tenth of a second while the window animates.
    func checkAnimation(now: Date = Date()) {
        guard let window, state.phase.isAnimating else { return stopAnimationCheck() }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if isFullScreen != (state.phase == .entering) {
            animating[ObjectIdentifier(window)] = nil
            apply(.failed(isFullScreen: isFullScreen))
        } else if now.timeIntervalSince(animationStarted) > Self.animationTimeout {
            animating[ObjectIdentifier(window)] = nil
            apply(isFullScreen ? .didEnter : .didExit, deferringToggle: true)
        }
    }

    // MARK: Plumbing

    private func track(_ window: NSWindow?) {
        self.window = window
        stopAnimationCheck()
        guard let window else { state = FullScreenImageState(); return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        // A recorded animation counts only while the style mask agrees:
        // an enter AppKit dropped leaves no notification behind.
        let recorded = animating[ObjectIdentifier(window)]
        state = switch recorded?.phase {
        case .entering? where isFullScreen: FullScreenImageState(phase: .entering)
        case .exiting? where !isFullScreen: FullScreenImageState(phase: .exiting)
        default: FullScreenImageState(phase: isFullScreen ? .fullScreen : .windowed)
        }
        if let recorded, state.phase.isAnimating {
            animationStarted = recorded.since
            startAnimationCheck()
        }
    }

    private func window(_ window: NSWindow, posted event: FullScreenImageState.Event) {
        let id = ObjectIdentifier(window)
        switch event {
        case .willEnter: animating[id] = (.entering, Date())
        case .willExit: animating[id] = (.exiting, Date())
        default: animating[id] = nil
        }
        guard window === self.window else { return }
        switch event {
        case .willEnter, .willExit:
            animationStarted = Date()
            apply(event == .willEnter ? .willEnter : .willExit(byMode: isToggling))
        case .closed:
            apply(.closed)
            self.window = nil
        default:
            // AppKit ignores a request made inside didEnter.
            apply(event, deferringToggle: true)
        }
    }

    private func apply(_ event: FullScreenImageState.Event, deferringToggle: Bool = false) {
        let wasActive = state.isActive
        state.handle(event)
        if state.isActive != wasActive {
            openEdge = nil
            builtEdges = []
            isActive = state.isActive
        }
        if state.phase.isAnimating { startAnimationCheck() } else { stopAnimationCheck() }
        guard state.needsToggle else { return }
        if deferringToggle {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.toggleIfNeeded() } }
        } else {
            toggleIfNeeded()
        }
    }

    private func toggleIfNeeded() {
        guard state.needsToggle, let window else { return }
        let before = state.phase
        isToggling = true
        window.toggleFullScreen(nil)
        isToggling = false
        // The request posts willEnter or willExit as it starts; none, and
        // the window didn't take it.
        if state.phase == before {
            apply(.failed(isFullScreen: window.styleMask.contains(.fullScreen)))
        }
    }

    private func startAnimationCheck() {
        guard animationCheck == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            let isOwned = MainActor.assumeIsolated {
                self?.checkAnimation()
                return self != nil
            }
            if !isOwned { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationCheck = timer
    }

    private func stopAnimationCheck() {
        animationCheck?.invalidate()
        animationCheck = nil
    }
}

/// Notification observers, removed when their owner goes.
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
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
    /// opens them, over this view (ContentView's main area), which is laid
    /// out up to the top of the window. Nothing changes while the mode is off.
    ///
    /// The top safe area is ignored because the main window's toolbar keeps
    /// it: `.toolbar(.hidden, for: .windowToolbar)` hides the toolbar's
    /// views, but AppKit still counts the toolbar as showing and goes on
    /// reserving its height (52 pt with the titlebar) at the top of the
    /// content, in full screen too, where the view was laid out below an
    /// empty strip of window background: a grey bar between the menu bar
    /// (or a notched display's camera housing) and the image. Hiding the
    /// NSToolbar instead doesn't hold, since SwiftUI shows it again. The
    /// system already places a full-screen window below a camera housing,
    /// so nothing goes under one.
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
            // After the panels, so they reach the top too, their contents
            // with no inset for the toolbar either.
            .ignoresSafeArea(.container, edges: mode.isActive ? .top : [])
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
