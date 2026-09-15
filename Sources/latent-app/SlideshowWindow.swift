import AppKit
import QuartzCore
import Metal
import os
import Catalog
import PixelEngine
import MLKit

extension Log {
    static let slideshow = Logger(subsystem: "com.latent.app", category: "slideshow")
}

/// A slideshow (View > Slideshow, ⌘Return): full screen on the main
/// window's display, one slide at a time with a Metal transition between
/// them, ported from minivu's.
///
/// Slides are the photos with their edits, rendered at the size the screen
/// shows them by `ExportWorker.renderForScreen`, the export path minus the
/// file. The rest is timing, kept to the least work:
///
/// - **One slide ahead.** When a slide shows, only the next one renders.
///   At most four slides are alive at once: the one going, the one coming,
///   the next one ready and one rendering.
/// - **Skipping cancels.** A step to a slide that isn't ready waits for it,
///   and a further step moves the target on and cancels the render under
///   way, so holding → never queues up renders nobody sees.
/// - **Nothing runs between slides** but one sleeping task for the next.
///   The display link runs only while a transition animates.
/// - **The display stays awake while playing**, not while paused.
@MainActor
final class SlideshowController: NSWindowController, NSWindowDelegate {
    /// The slideshow on screen, if any. There is one at a time.
    private(set) static var current: SlideshowController?

    /// Transitions for → and ←: quick, or the setting if that's quicker.
    static let quickTransitionDuration: TimeInterval = 0.35
    /// Pointer stillness before the control bar and cursor hide.
    static let controlsHideDelay: Duration = .seconds(2)

    /// Makes one slide, for a picture area of the given pixel size.
    typealias Render = @Sendable (ImageRecord, CGSize) async throws -> SlideTexture

    struct Source {
        var records: [ImageRecord]
        var start: Int
        var library: Library
        var gpu: GPUContext
        /// Edits to use instead of the catalog's, by image id: the image open
        /// in the editor, whose latest change may not be saved yet. A nil
        /// value is an image at its defaults.
        var editOverrides: [Int64: String?] = [:]
        /// Tests make slides of their own; nil renders the photos.
        var render: Render?
    }

    /// Slides from the photos: each file with its edit (the catalog's, or
    /// the editor's unsaved one) through `ExportWorker.renderForScreen`.
    /// Nothing if another folder has opened meanwhile.
    static func pipelineRender(library: Library, gpu: GPUContext, editOverrides: [Int64: String?]) -> Render {
        let catalog = library.catalog
        return { record, screen in
            let url = await MainActor.run { library.catalog === catalog ? library.fileURL(for: record) : nil }
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            let json: String?
            if let unsaved = record.id.flatMap({ editOverrides[$0] }) {
                json = unsaved
            } else {
                json = try await library.editStack(for: record)
            }
            try Task.checkCancellation()
            return try await ExportWorker.renderForScreen(sourceURL: url, editStackJSON: json,
                                                         userRotation: record.userRotation, screen: screen, gpu: gpu)
        }
    }

    /// Starts a show, or brings the running one forward. `onEnd` gets a
    /// message when the show ended because nothing would render.
    @discardableResult
    static func start(_ source: Source, from origin: NSWindow?,
                      settings: SlideshowSettings = SlideshowSettingsStore.shared.settings,
                      onEnd: @escaping (String?) -> Void = { _ in }) -> SlideshowController? {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            return current
        }
        guard !source.records.isEmpty else { return nil }
        let screen = origin?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let controller = SlideshowController(source: source, screen: screen, origin: origin, settings: settings,
                                             onEnd: onEnd)
        current = controller
        controller.begin()
        return controller
    }

    /// View > Slideshow: the selection when several images are selected,
    /// otherwise every image the filter shows from the selected one, each
    /// with its edit. The open image's edit is taken from the editor, since
    /// its latest change may not have reached the catalog yet.
    static func start(model: EditorModel, library: Library) {
        guard let gpu = model.gpu else { return }
        let chosen = SlideshowImages.choose(visible: library.visibleImages, selectedIDs: library.selectedImageIDs,
                                            primary: library.selectedImageID)
        var source = Source(records: chosen.records, start: chosen.start, library: library, gpu: gpu)
        if model.hasImage, let id = model.catalogImageID,
           chosen.records.contains(where: { $0.id == id && $0.fileName == model.imageTitle }) {
            if EditStack.isDefault(model.parameters, relativeTo: model.defaultParameters) {
                source.editOverrides.updateValue(nil, forKey: id)
            } else if let json = try? model.stackWithProvenance().encodeJSON() {
                source.editOverrides.updateValue(json, forKey: id)
            }
        }
        model.flushPendingSave()
        var settings = SlideshowSettingsStore.shared.settings
        #if DEBUG
        if let caption = debugCaption { settings.caption = caption }
        #endif
        start(source, from: NSApp.mainWindow, settings: settings) { message in
            if let message { model.lastError = message }
        }
    }

    private enum Step: Equatable {
        /// The opening slide, faded in from black.
        case first
        /// The interval is up.
        case auto
        /// → and ←, and the control bar's buttons.
        case next, previous

        var direction: Int { self == .previous ? -1 : 1 }
    }

    private struct Transition {
        var from: SlideTexture?
        var to: SlideTexture
        var kind: SlideshowTransition
        var direction: SlideshowDirection
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }

    private let records: [ImageRecord]
    private let startIndex: Int
    private let gpu: GPUContext
    private let render: Render
    private let settings: SlideshowSettings
    private let onEnd: (String?) -> Void
    private weak var origin: NSWindow?
    private(set) var sequence: SlideshowSequence
    /// The picture area in pixels, which slides render to fit.
    private var screenPixels: CGSize
    private var screenNumber: NSNumber?

    private let content = SlideshowContentView()
    private let slideView = SlideshowView()
    private let caption = SlideshowCaptionView()
    private let controlBar = SlideshowControlBar()
    private let spinner = NSProgressIndicator()

    /// The slide on screen, or arriving in the transition under way.
    private var shown: (index: Int, slide: SlideTexture)?
    private var transition: Transition?
    /// When the frame being drawn will show, from the display link.
    private var frameTime: CFTimeInterval = 0
    /// A move waiting for its slide to render.
    private var target: (index: Int, step: Step)?
    private var loading: (index: Int, id: Int, task: Task<Void, Never>)?
    private var loadCount = 0
    /// A rendered slide not yet shown: normally the next one.
    private var ready: (index: Int, slide: SlideTexture)?
    private var advanceTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var lastPointerMove = ContinuousClock.now
    private(set) var isPaused = false
    private var activity: NSObjectProtocol?
    private var music: SlideshowMusic?
    private(set) var hasEnded = false
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var observers: [NSObjectProtocol] = []
    #if DEBUG
    /// Snapshot harness only: the controls stay up.
    var pinsControls = false
    #endif

    private init(source: Source, screen: NSScreen?, origin: NSWindow?, settings: SlideshowSettings,
                 onEnd: @escaping (String?) -> Void) {
        records = source.records
        startIndex = min(max(source.start, 0), source.records.count - 1)
        gpu = source.gpu
        render = source.render
            ?? Self.pipelineRender(library: source.library, gpu: source.gpu, editOverrides: source.editOverrides)
        self.settings = settings
        self.onEnd = onEnd
        self.origin = origin
        sequence = SlideshowSequence(count: source.records.count, loops: settings.loop)
        // No screen at all (a headless test run): a laptop's.
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        screenPixels = screen.map(Self.pictureSize) ?? CGSize(width: 2880, height: 1800)
        screenNumber = screen.flatMap(Self.number)
        let window = SlideshowWindow(frame: frame)
        super.init(window: window)
        window.setFrame(frame, display: false)
        window.delegate = self
        window.onClose = { [weak self] in self?.end() }
        buildContent(in: window, screen: screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    private func buildContent(in window: NSWindow, screen: NSScreen?) {
        window.contentView = content
        content.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        content.onClick = { [weak self] in self?.end() }
        content.onPointerMoved = { [weak self] in self?.pointerMoved() }
        content.topInset = screen?.safeAreaInsets.top ?? 0

        slideView.configure(gpu: gpu)
        slideView.frameProvider = { [weak self] in self?.currentFrame() ?? .still(nil) }
        slideView.onAnimationFrame = { [weak self] time in self?.animationFrame(at: time) }
        content.picture = slideView
        content.addSubview(slideView)

        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Preparing the next slide")
        spinner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(spinner)

        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.onCommand = { [weak self] command in self?.controlBarCommand(command) }
        content.addSubview(controlBar)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            caption.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: controlBar.leadingAnchor, constant: -24),
            controlBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
        ])
        controlBar.update(isPaused: false)
    }

    // MARK: - Starting and ending

    private func begin() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        NSCursor.setHiddenUntilMouseMoves(true)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        if settings.hasMusic {
            music = SlideshowMusic(songs: settings.songs)
            music?.start()
        }
        updatePlaying()
        showSpinnerSoon()
        move(.first)
    }

    /// Esc, a click, ⌘W, the control bar's close button, or the end of a show
    /// that doesn't loop. Stops all work and gives the display its sleep,
    /// the menu bar and the Dock back.
    func end(message: String? = nil) {
        guard !hasEnded else { return }
        hasEnded = true
        advanceTask?.cancel()
        controlsTask?.cancel()
        spinnerTask?.cancel()
        loading?.task.cancel()
        loading = nil
        ready = nil
        target = nil
        transition = nil
        music?.finish()
        music = nil
        updatePlaying()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        restorePresentationOptions()
        NSCursor.setHiddenUntilMouseMoves(false)
        slideView.frameProvider = nil
        slideView.onAnimationFrame = nil
        if let window = window as? SlideshowWindow {
            window.delegate = nil
            window.onClose = nil
            // Out of the window, the view's display link stops, which would
            // otherwise keep the view and its renderer alive.
            window.contentView = nil
            window.orderOut(nil)
        }
        shown = nil
        if Self.current === self { Self.current = nil }
        origin?.makeKeyAndOrderFront(nil)
        onEnd(message)
    }

    // MARK: - Moving

    private func move(_ step: Step) {
        guard !hasEnded else { return }
        let base = target?.index ?? shown?.index
        let destination: Int? = switch step {
        case .first: sequence.first(from: startIndex)
        case .auto, .next, .previous: base.flatMap { sequence.step(from: $0, by: step.direction) }
        }
        guard let destination else {
            if step == .first || !sequence.hasPlayable {
                end(message: records.count == 1 ? "The slideshow couldn’t show \(records[0].fileName)"
                                                 : "The slideshow couldn’t show any of the images")
            } else if step == .auto, !sequence.loops {
                end()
            } else if step != .auto {
                pointerMoved()   // at an end: the controls say where the show is
            }
            return
        }
        go(to: destination, step: step)
    }

    private func go(to index: Int, step: Step) {
        if let ready, ready.index == index {
            self.ready = nil
            target = nil
            if let loading, loading.index != index {
                loading.task.cancel()
                self.loading = nil
            }
            show(ready.slide, index: index, step: step)
        } else {
            advanceTask?.cancel()
            target = (index, step)
            request(index)
            showSpinnerSoon()
        }
    }

    /// Renders slide `index` unless it is ready or rendering, cancelling any
    /// other render: only the slide wanted next is worth the work.
    private func request(_ index: Int) {
        guard ready?.index != index, loading?.index != index, !sequence.failed.contains(index) else { return }
        loading?.task.cancel()
        loadCount += 1
        let id = loadCount
        let record = records[index], render = render, screen = screenPixels
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<SlideTexture, Error>
            do {
                result = .success(try await render(record, screen))
            } catch {
                result = .failure(error)
            }
            await self?.loaded(index, id: id, result)
        }
        loading = (index, id, task)
    }

    private func loaded(_ index: Int, id: Int, _ result: Result<SlideTexture, Error>) {
        guard !hasEnded, loading?.id == id else { return }
        loading = nil
        switch result {
        case .success(let slide):
            ready = (index, slide)
            if let target, target.index == index { go(to: index, step: target.step) }
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            Log.slideshow.error("Slideshow skips \(self.records[index].fileName, privacy: .private): \(String(describing: error), privacy: .private)")
            sequence.markFailed(index)
            guard let target, target.index == index else { return }
            // On past it, the way the move was going.
            self.target = nil
            let direction = target.step.direction
            if let next = sequence.step(from: index, by: direction) ?? (shown == nil ? sequence.first(from: 0) : nil) {
                go(to: next, step: target.step)
            } else if shown == nil || !sequence.hasPlayable {
                end(message: "The slideshow couldn’t show any of the images")
            } else if target.step == .auto, !sequence.loops {
                end()
            } else {
                hideSpinner()
                scheduleAdvance()
            }
        }
    }

    /// Starts the transition to `slide`. One already under way ends at
    /// once: its slide becomes the one going away.
    private func show(_ slide: SlideTexture, index: Int, step: Step) {
        advanceTask?.cancel()
        hideSpinner()
        let quick = step == .next || step == .previous
        let kind = (step == .first ? .crossFade : settings.transition).reducingMotion(Motion.isReduced)
        let duration = quick ? min(Self.quickTransitionDuration, settings.transitionDuration)
                             : settings.transitionDuration
        let from = shown?.slide
        shown = (index, slide)
        updateCaption()
        if kind.animates {
            let now = CACurrentMediaTime()
            transition = Transition(from: from, to: slide, kind: kind,
                                    direction: step == .previous ? .backward : .forward,
                                    start: now, duration: duration)
            frameTime = now
            slideView.startAnimating()
        } else {
            transition = nil
            slideView.setNeedsRedraw()
            scheduleAdvance()
        }
        if let next = sequence.step(from: index, by: 1) { request(next) }
    }

    private func animationFrame(at time: CFTimeInterval) {
        frameTime = time
        guard let transition else {
            slideView.stopAnimating()
            return
        }
        if time - transition.start >= transition.duration {
            self.transition = nil
            slideView.stopAnimating()   // one more frame: the slide at rest
            scheduleAdvance()
        }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard !isPaused, !hasEnded, shown != nil, transition == nil, target == nil else { return }
        let interval = settings.interval
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.move(.auto)
        }
    }

    private func currentFrame() -> SlideshowFrame {
        guard let transition else { return .still(shown?.slide) }
        let progress = Float(min(max((frameTime - transition.start) / max(transition.duration, 0.001), 0), 1))
        return SlideshowFrame(from: transition.from, to: transition.to, transition: transition.kind,
                              progress: progress, direction: transition.direction)
    }

    // MARK: - Pausing, keys and controls

    func setPaused(_ paused: Bool) {
        guard paused != isPaused, !hasEnded else { return }
        isPaused = paused
        if paused {
            advanceTask?.cancel()
            if target?.step == .auto { target = nil; hideSpinner() }
            music?.pause()
        } else {
            music?.resume()
            scheduleAdvance()
        }
        updatePlaying()
        controlBar.update(isPaused: paused)
        updateAccessibility()
        Announcement.post(paused ? "Slideshow paused" : "Slideshow playing")
    }

    /// The display mustn't sleep during a show, but may once it is paused.
    private func updatePlaying() {
        let playing = !isPaused && !hasEnded
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Slideshow")
        } else if !playing, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Menu shortcuts (⌘Q) go on to the menu bar.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        switch Int(scalar.value) {
        case 0x20:
            if !event.isARepeat {
                setPaused(!isPaused)
                pointerMoved()   // the bar shows which it is now
            }
        case NSRightArrowFunctionKey, NSDownArrowFunctionKey, NSPageDownFunctionKey:
            move(.next)
        case NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSPageUpFunctionKey:
            move(.previous)
        case 0x1B:
            end()
        default:
            return false
        }
        return true
    }

    /// The control bar's buttons; also how tests step the show.
    func controlBarCommand(_ command: SlideshowControlBar.Command) {
        switch command {
        case .previous: move(.previous)
        case .playPause: setPaused(!isPaused)
        case .next: move(.next)
        case .close: end()
        }
    }

    /// Pointer events arrive many times a second, so a move only notes the
    /// time; one task checks it when due.
    private func pointerMoved() {
        guard !hasEnded else { return }
        lastPointerMove = .now
        controlBar.setShown(true, animated: !Motion.isReduced)
        guard controlsTask == nil else { return }
        scheduleControlsHide(after: Self.controlsHideDelay)
    }

    private func scheduleControlsHide(after delay: Duration) {
        controlsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.hasEnded else { return }
            self.controlsTask = nil
            #if DEBUG
            if self.pinsControls { return }
            #endif
            let still = ContinuousClock.now - self.lastPointerMove
            if still < Self.controlsHideDelay {
                self.scheduleControlsHide(after: Self.controlsHideDelay - still)
            } else if self.pointerIsOverControls {
                self.scheduleControlsHide(after: Self.controlsHideDelay)
            } else {
                self.controlBar.setShown(false, animated: !Motion.isReduced)
                if self.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    private var pointerIsOverControls: Bool {
        guard let window else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return controlBar.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    /// The spinner appears only when a slide keeps the show waiting.
    private func showSpinnerSoon() {
        guard spinnerTask == nil else { return }
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !self.hasEnded else { return }
            self.spinnerTask = nil
            if self.target != nil { self.spinner.startAnimation(nil) }
        }
    }

    private func hideSpinner() {
        spinnerTask?.cancel()
        spinnerTask = nil
        spinner.stopAnimation(nil)
    }

    // MARK: - Captions and accessibility

    private func updateCaption() {
        guard let index = shown?.index else {
            caption.show(nil, animated: false)
            return
        }
        caption.show(SlideshowCaptionText.text(settings.caption, record: records[index]),
                     animated: !Motion.isReduced)
        updateAccessibility()
        if NSWorkspace.shared.isVoiceOverEnabled {
            Announcement.post(records[index].fileName)
        }
    }

    private func updateAccessibility() {
        guard let index = shown?.index else {
            slideView.setAccessibilityLabel("Slideshow, preparing the first slide")
            return
        }
        var label = "Slideshow, \(records[index].fileName), \(index + 1) of \(records.count)"
        if isPaused { label += ", paused" }
        slideView.setAccessibilityLabel(label)
    }

    // MARK: - Window and screen

    /// The menu bar and Dock make way while the show is key and come back
    /// whenever it isn't.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !hasEnded, let app = NSApp, app.isActive else { return }
        if savedPresentationOptions == nil { savedPresentationOptions = app.presentationOptions }
        app.presentationOptions = [.hideDock, .hideMenuBar]
    }

    func windowDidResignKey(_ notification: Notification) {
        restorePresentationOptions()
    }

    private func restorePresentationOptions() {
        guard let saved = savedPresentationOptions, let app = NSApp else { return }
        savedPresentationOptions = nil
        app.presentationOptions = saved
    }

    /// A resolution change: keep covering the display. Its display gone:
    /// go on on the main one. Slides from here on render for the new size;
    /// the ones already made are drawn fitted.
    private func screensChanged() {
        guard !hasEnded, let window else { return }
        let screen = NSScreen.screens.first { Self.number(of: $0) == screenNumber } ?? NSScreen.main
        guard let screen else { return }
        screenNumber = Self.number(of: screen)
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        content.topInset = screen.safeAreaInsets.top
        let size = Self.pictureSize(on: screen)
        if size != screenPixels {
            screenPixels = size
            if let loading, target?.index != loading.index {
                // A prefetch for the old size: render it again for this one.
                let index = loading.index
                loading.task.cancel()
                self.loading = nil
                request(index)
            }
        }
    }

    private static func pictureSize(on screen: NSScreen) -> CGSize {
        let scale = screen.backingScaleFactor
        return CGSize(width: (screen.frame.width * scale).rounded(),
                      height: ((screen.frame.height - screen.safeAreaInsets.top) * scale).rounded())
    }

    private static func number(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    // MARK: - For tests

    var shownIndex: Int? { shown?.index }
    /// The slide a move is waiting for.
    var targetIndex: Int? { target?.index }
    var renderingIndex: Int? { loading?.index }
    var readyIndex: Int? { ready?.index }
    var keepsDisplayAwake: Bool { activity != nil }

    #if DEBUG
    /// Snapshot harness only: a caption style for the next show.
    static var debugCaption: SlideshowSettings.Caption?
    /// For the snapshot harness: whether a slide is on screen and at rest.
    var isShowingSlideAtRest: Bool { shown != nil && transition == nil }
    var slideshowWindow: NSWindow? { window }

    /// Snapshot harness only: the controls up and staying up.
    func debugPinControls() {
        pinsControls = true
        controlBar.setShown(true, animated: false)
    }
    #endif
}

// MARK: - Views

/// The slideshow's window: borderless, black, exactly covering one screen.
final class SlideshowWindow: NSWindow {
    /// ⌘W and Esc (when no view handled it first).
    var onClose: (() -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Windows made in code must not free themselves on close: the
        // controller still holds this one.
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.fullScreenNone, .managed]
        acceptsMouseMovedEvents = true
        title = "Slideshow"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// AppKit enables File > Close Window only for windows with a close
    /// button, which a borderless one lacks, so ⌘W would just beep.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) { return onClose != nil }
        return super.validateMenuItem(menuItem)
    }
}

/// Holds the picture, caption and controls, and hands keys, clicks and
/// pointer movement to the controller.
final class SlideshowContentView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onClick: (() -> Void)?
    var onPointerMoved: (() -> Void)?
    /// The picture, kept clear of a notched display's camera housing, so it
    /// shows whole.
    var picture: NSView? { didSet { needsLayout = true } }
    var topInset: CGFloat = 0 { didSet { needsLayout = true } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        let area = CGRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        if let picture, picture.frame != area { picture.frame = area }
        super.layout()
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseMoved(with event: NSEvent) { onPointerMoved?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}

/// The picture: a view backed by a CAMetalLayer set up like the viewport's
/// (half-float, extended linear Display P3, EDR off). Frames come from a
/// display link that runs only while a transition animates, plus one frame
/// whenever something else changes. A slide at rest costs nothing.
final class SlideshowView: NSView {
    var frameProvider: (() -> SlideshowFrame)?
    /// Called on each refresh while animating, before drawing, with the time
    /// the frame will reach the screen. The owner may stop animating here.
    var onAnimationFrame: ((CFTimeInterval) -> Void)?

    private var renderer: SlideshowRenderer?
    private var displayLink: CADisplayLink?
    private(set) var isAnimating = false
    private var needsRedraw = true

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Frames are presented by hand; AppKit must never ask the layer to draw.
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    func configure(gpu: GPUContext) {
        do {
            renderer = try SlideshowRenderer(gpu: gpu)
        } catch {
            Log.slideshow.error("Slideshow renderer unavailable: \(String(describing: error), privacy: .public)")
        }
        metalLayer?.device = gpu.device
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = SlideshowRenderer.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = false
        // Readable only for the debug snapshot harness, which pictures it.
        #if DEBUG
        layer.framebufferOnly = !SnapshotHarness.isActive
        #endif
        layer.isOpaque = true
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    func startAnimating() {
        isAnimating = true
        displayLink?.isPaused = false
    }

    /// Stops the link after one more frame, which shows where things ended.
    func stopAnimating() {
        isAnimating = false
        setNeedsRedraw()
    }

    func setNeedsRedraw() {
        needsRedraw = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if isAnimating { onAnimationFrame?(link.targetTimestamp) }
        // Paused before drawing: anything that asks for a frame meanwhile
        // unpauses it again.
        link.isPaused = !isAnimating
        guard isAnimating || needsRedraw else { return }
        draw()
    }

    private func draw() {
        guard let renderer, let layer = metalLayer, window != nil, let frameProvider else { return }
        let size = CGSize(width: (bounds.width * backingScale).rounded(), height: (bounds.height * backingScale).rounded())
        guard size.width >= 1, size.height >= 1 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable() else { return }
        needsRedraw = false
        renderer.draw(frameProvider(), to: drawable)
        #if DEBUG
        SnapshotHarness.noteDrawable(drawable.texture, presentedBy: self)
        #endif
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The link retains its target, so it must not outlive the window.
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.isPaused = !(isAnimating || needsRedraw)
        link.add(to: .main, forMode: .common)
        displayLink = link
        metalLayer?.contentsScale = backingScale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer?.contentsScale = backingScale
        setNeedsRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRedraw()
    }
}

/// The caption in the bottom-left corner: white text with a soft shadow, so
/// it reads on any photo without a box over the picture.
final class SlideshowCaptionView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 15, weight: .medium)
        textColor = .white
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        self.shadow = shadow
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// A read-out: clicks go to the slideshow beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `text`, or fades out for nil.
    func show(_ text: String?, animated: Bool) {
        if let text { stringValue = text }
        setAccessibilityElement(text != nil)
        let target: CGFloat = text == nil ? 0 : 1
        guard alphaValue != target else { return }
        guard animated else { alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = target
        }
    }
}

/// The small translucent bar that appears when the pointer moves during a
/// slideshow: previous, play or pause, next, end.
final class SlideshowControlBar: NSVisualEffectView {
    enum Command: Int {
        case previous, playPause, next, close
    }

    static let height: CGFloat = 44

    var onCommand: ((Command) -> Void)?

    private lazy var previousButton = button("backward.fill", "Previous Slide (←)", .previous)
    private lazy var playPauseButton = button("pause.fill", "Pause (Space)", .playPause)
    private lazy var nextButton = button("forward.fill", "Next Slide (→)", .next)
    private lazy var closeButton = button("xmark", "End Slideshow (Esc)", .close)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        // Over a photo, not the app's chrome: dark in every theme.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Slideshow controls")

        let stack = NSStackView(views: [previousButton, playPauseButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    /// A press between the buttons stays in the bar; beneath it, a click
    /// would end the slideshow.
    override func mouseDown(with event: NSEvent) {}

    func update(isPaused: Bool) {
        let title = isPaused ? "Play (Space)" : "Pause (Space)"
        guard playPauseButton.toolTip != title else { return }
        playPauseButton.image = Self.symbol(isPaused ? "play.fill" : "pause.fill", title)
        playPauseButton.toolTip = title
        playPauseButton.setAccessibilityLabel(Self.spoken(title))
    }

    private(set) var isShown = false

    func setShown(_ shown: Bool, animated: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        let target: CGFloat = shown ? 1 : 0
        guard animated else { alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.15 : 0.35
            animator().alphaValue = target
        }
    }

    /// Hidden, it takes no clicks: a click where it was ends the show.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }

    private func button(_ symbolName: String, _ toolTip: String, _ command: Command) -> NSButton {
        let button = NSButton(image: Self.symbol(symbolName, toolTip), target: self, action: #selector(pressed(_:)))
        button.tag = command.rawValue
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.toolTip = toolTip
        button.setAccessibilityLabel(Self.spoken(toolTip))
        // Never the key focus: Space must always pause the show, not press
        // whichever button was focused last.
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        return button
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let command = Command(rawValue: sender.tag) else { return }
        onCommand?(command)
    }

    /// "Pause (Space)" is spoken as "Pause".
    static func spoken(_ title: String) -> String {
        title.components(separatedBy: " (").first ?? title
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: spoken(description)) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? image
    }
}
