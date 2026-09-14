#if DEBUG
import AppKit
import SwiftUI
import Metal
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Catalog

/// Walks the app through its main states and saves a picture of the window
/// at each, then quits, so developers and agents can see the UI without
/// granting screen-recording permission.
///
///     LATENT_SNAPSHOT_DIR=.build/snapshots      turns the harness on; where the PNGs go
///     LATENT_SNAPSHOT_FOLDER=~/Pictures/Trip    opened as the catalog (not remembered as
///                                               the last folder); unset, nothing is opened
///     LATENT_SNAPSHOT_STEPS="library;loupe"     states to picture, in order (default:
///                                               library;loupe;develop;crop;heal;compare;
///                                               export;settings). Also `next`, which moves
///                                               the selection on. Each writes NN-step.png
///     LATENT_SNAPSHOT_SIZE=1400x900             window content size in points
///     LATENT_SNAPSHOT_SETTLE=1                  seconds to wait after a step's work is done
///     LATENT_SNAPSHOT_TIMEOUT=120               seconds before the whole run gives up
///     LATENT_SNAPSHOT_APPEARANCE=dark           light or dark instead of the app's setting
///
/// For example, from the package folder:
///
///     LATENT_SNAPSHOT_DIR=.build/snapshots LATENT_SNAPSHOT_FOLDER=/tmp/shoot swift run latent-app
///
/// Exit status is 0 when every step was pictured, 1 when a step or the
/// setup failed (the reason goes to standard error), 2 on timeout.
///
/// The steps only look: they switch modes, arm tools and open sheets, but
/// never change an edit, a rating or a file. The catalog in the opened
/// folder is still created or updated as opening any folder does, so point
/// it at a copy when that matters.
///
/// The picture is made inside the app by asking the window's views to
/// render into a bitmap, not by reading the screen, which is why no
/// permission is needed. Metal content never reaches such a bitmap (it goes
/// straight to the display), so each image view's last presented drawable
/// is read back and placed in the layer tree for the moment of the render;
/// SwiftUI overlays above it, such as the crop and heal handles, stay above.
///
/// Debug builds only: a release build neither reads these variables nor
/// carries any of this.
@MainActor
enum SnapshotHarness {
    /// Whether a run is under way. Image views only hand over their
    /// drawables while it is, so ordinary debug runs keep none alive.
    private(set) static var isActive = false

    /// Called by ContentView when it appears. Returns true when a snapshot
    /// run has started, in which case ContentView must not open a folder
    /// of its own (the launch argument or the last folder).
    static func start(model: EditorModel, library: Library,
                      perform: @escaping (KeyCommand) -> Bool,
                      exportSheet: Binding<Bool>) -> Bool {
        guard !isActive else { return true }
        let plan: SnapshotPlan
        do {
            guard let parsed = try SnapshotPlan(environment: ProcessInfo.processInfo.environment) else { return false }
            plan = parsed
        } catch {
            report("\(error)")
            exit(1)
        }
        isActive = true
        // A stuck run must not leave a windowed app behind in an agent's
        // session, so a background timer ends the process whatever the
        // main thread is doing.
        let timeout = plan.timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            FileHandle.standardError.write(Data("LATENT_SNAPSHOT: gave up after \(Int(timeout)) s\n".utf8))
            exit(2)
        }
        let run = Run(plan: plan, model: model, library: library, perform: perform, exportSheet: exportSheet)
        Task { await run.start() }
        return true
    }

    // MARK: - Metal image views

    /// The drawable texture each image view presented last. Weak keys, so a
    /// view that leaves the window lets its entry go.
    private static let presented = NSMapTable<NSView, AnyObject>.weakToStrongObjects()

    /// Called by MetalLayerView after each present.
    static func noteDrawable(_ texture: MTLTexture, presentedBy view: NSView) {
        guard isActive else { return }
        presented.setObject(texture, forKey: view)
    }

    /// The image views in `root` that are showing something, in drawing order.
    private static func imageViews(in root: NSView) -> [MetalLayerView] {
        var found: [MetalLayerView] = []
        forEachVisibleView(in: root) { view in
            if let view = view as? MetalLayerView, !view.visibleRect.isEmpty,
               presented.object(forKey: view) != nil {
                found.append(view)
            }
        }
        return found
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The view's last drawable as an sRGB image, upright. Read in the
    /// layer's own colour space, since that is how the compositor shows it.
    private static func image(of view: MetalLayerView) -> CGImage? {
        guard let texture = presented.object(forKey: view) as? MTLTexture,
              let layer = view.layer as? CAMetalLayer,
              let space = layer.colorspace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              var image = CIImage(mtlTexture: texture, options: [.colorSpace: space])
        else { return nil }
        // Metal rows run top down, Core Image's bottom up.
        image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
    }

    // MARK: - Capture

    /// Renders the whole window (titlebar included) at its backing scale
    /// into an sRGB bitmap, with any sheet drawn over it.
    static func capture(_ window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        // The content view's superview is the window's frame view, which
        // also holds the titlebar.
        let root = content.superview ?? content
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()

        let scale = window.backingScaleFactor
        let bounds = root.bounds
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        render(window, root: root, in: context)
        if let sheet = window.attachedSheet, sheet.isVisible {
            drawSheet(sheet, over: window, in: context)
        }
        return context.makeImage()
    }

    /// Renders the frame view's layer tree, which draws the layer contents
    /// already made for the screen, with each image view's picture placed
    /// in a temporary sublayer of its Metal layer. Sublayers draw above
    /// their layer and below whatever sits above it, so the stacking is
    /// the screen's.
    private static func render(_ window: NSWindow, root: NSView, in context: CGContext) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var standIns: [CALayer] = []
        for view in imageViews(in: root) {
            guard let layer = view.layer, let image = image(of: view) else {
                report("could not read back an image view's drawable; its area will be blank")
                continue
            }
            let standIn = CALayer()
            standIn.frame = layer.bounds
            standIn.contents = image
            standIn.contentsGravity = .resize
            layer.addSublayer(standIn)
            standIns.append(standIn)
        }
        CATransaction.commit()
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            standIns.forEach { $0.removeFromSuperlayer() }
            CATransaction.commit()
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            fillBackdrops(of: window, root: root, in: context)
            root.layer?.render(in: context)
        }
    }

    /// A sheet is a window of its own; it is drawn where it sits over its
    /// parent, clipped to the rounded shape sheets have.
    private static func drawSheet(_ sheet: NSWindow, over window: NSWindow, in context: CGContext) {
        guard let content = sheet.contentView else { return }
        let root = content.superview ?? content
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        context.saveGState()
        context.translateBy(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        context.addPath(CGPath(roundedRect: root.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.clip()
        render(sheet, root: root, in: context)
        context.restoreGState()
    }

    /// Paints what a bitmap render leaves empty: the window background, and
    /// a solid stand-in for each translucent material, whose blur of the
    /// desktop behind only exists on screen.
    private static func fillBackdrops(of window: NSWindow, root: NSView, in context: CGContext) {
        context.setFillColor(window.backgroundColor.cgColor)
        context.fill(root.bounds)
        forEachVisibleView(in: root) { view in
            guard let effect = view as? NSVisualEffectView else { return }
            let color: NSColor = effect.material == .sidebar ? .underPageBackgroundColor : .windowBackgroundColor
            context.setFillColor(color.cgColor)
            context.fill(effect.convert(effect.bounds, to: nil))
        }
    }

    /// Visits `root` and its descendants in drawing order, skipping hidden
    /// subtrees. Rectangles converted `to: nil` are in window coordinates,
    /// which match the bitmap: origin bottom left, in points.
    private static func forEachVisibleView(in root: NSView, _ body: (NSView) -> Void) {
        guard !root.isHidden, root.alphaValue > 0 else { return }
        body(root)
        for subview in root.subviews { forEachVisibleView(in: subview, body) }
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    fileprivate static func report(_ message: String) {
        FileHandle.standardError.write(Data("LATENT_SNAPSHOT: \(message)\n".utf8))
    }

    // MARK: - The run

    /// One pass through the plan's steps, driving ContentView through the
    /// same commands its keys send.
    @MainActor private final class Run {
        let plan: SnapshotPlan
        let model: EditorModel
        let library: Library
        let perform: (KeyCommand) -> Bool
        let exportSheet: Binding<Bool>
        var mainWindow: NSWindow?
        var failures = 0

        init(plan: SnapshotPlan, model: EditorModel, library: Library,
             perform: @escaping (KeyCommand) -> Bool, exportSheet: Binding<Bool>) {
            self.plan = plan
            self.model = model
            self.library = library
            self.perform = perform
            self.exportSheet = exportSheet
        }

        func start() async {
            if let appearance = plan.appearance {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            // Let the window order in and lay out.
            await pause(0.3)
            // Launched from a terminal the app may not become active, so
            // there may be no key window; the frontmost visible one is next.
            mainWindow = NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.sheetParent == nil }
            guard let window = mainWindow else { fail("no visible window"); finish() }
            if let size = plan.windowSize { window.setContentSize(size) }
            if let folder = plan.folder { await open(folder) }

            for index in plan.steps.indices {
                let step = plan.steps[index]
                let target = await enter(step)
                guard let target else { continue }
                await pause(plan.settle)
                let url = plan.output(forStepAt: index)
                if let image = capture(target), write(image, to: url) {
                    report("wrote \(url.path) (\(image.width)x\(image.height) px)")
                } else {
                    fail("\(step.rawValue): could not capture or write \(url.path)")
                }
                leave(step, window: target)
            }
            // Opening the folder may still be writing the catalog; a
            // bounded wait, as quitting does, so the next run finds it whole.
            let library = library
            _ = await wait("catalog writes", upTo: 10) { !library.hasPendingWork }
            finish()
        }

        /// Exits rather than terminating: a sheet still up would make a
        /// normal quit stop and ask, and a snapshot run has nothing to save.
        func finish() -> Never {
            report(failures == 0 ? "done" : "done with \(failures) failure\(failures == 1 ? "" : "s")")
            exit(failures == 0 ? 0 : 1)
        }

        func fail(_ message: String) {
            failures += 1
            report(message)
        }

        /// Opens `folder` as ContentView's folder panel does, minus
        /// remembering it as the last folder, and selects its first image.
        func open(_ folder: URL) async {
            let library = library
            library.perform("Opening \(folder.lastPathComponent)") {
                try await library.open(folder: folder, defaultSubfolderMode: AppPreferences.shared.defaultSubfolderMode)
            }
            let opened = await wait("the folder to open", upTo: 60) {
                library.lastError != nil || (library.folderURL != nil && !library.isBusy)
            }
            if let error = library.lastError { fail(error); return }
            guard opened else { return }
            if library.selectedImageID == nil { library.moveSelection(by: 1) }
            _ = await wait("thumbnails", upTo: 60) {
                library.thumbnailsTotal == 0 || library.thumbnailsDone >= library.thumbnailsTotal
            }
        }

        /// Puts the window in the step's state and returns the window to
        /// picture, or nil when the step can't be reached here.
        func enter(_ step: SnapshotPlan.Step) async -> NSWindow? {
            guard let window = mainWindow else { return nil }
            switch step {
            case .library:
                _ = perform(.library)
            case .next:
                // Only a mode showing an image loads the next one; the grid
                // just moves its highlight.
                let showing = window.contentView?.superview.map { SnapshotHarness.imageViews(in: $0).count } ?? 0
                _ = perform(.step(1))
                if showing > 0 { await waitForImage(views: showing) }
            case .loupe, .develop, .crop, .heal:
                guard library.selectedImage != nil else { fail("\(step.rawValue): no image selected"); return nil }
                _ = perform(step == .loupe ? .loupe : .develop)
                await waitForImage(views: 1)
                // Tools arm only once there is an image to use them on.
                if step == .crop, !model.cropToolActive { _ = perform(.crop) }
                if step == .heal, !model.healToolActive { _ = perform(.heal) }
                // The tools' sections open below the everyday ones, out of
                // sight; the panel's end shows both, with only collapsed
                // groups after them.
                if step == .crop || step == .heal { await pause(0.2); scrollAdjustments(toEnd: true) }
            case .compare:
                guard let selected = library.selectedImage else { fail("compare: no image selected"); return nil }
                // Compare's left pane takes the other selected image; with
                // only one selected, both panes would show the same.
                if library.selectedImageIDs.count < 2,
                   let index = library.visibleImages.firstIndex(where: { $0.id == selected.id }),
                   let other = library.visibleImages.dropFirst(index + 1).first ?? library.visibleImages.first,
                   let id = other.id {
                    library.selectedImageIDs.insert(id)
                }
                _ = perform(.compare)
                await waitForImage(views: 2)
            case .export:
                guard !library.selectedImageIDs.isEmpty else { fail("export: no image selected"); return nil }
                exportSheet.wrappedValue = true
                _ = await wait("the export sheet", upTo: 10) { window.attachedSheet?.isVisible == true }
            case .settings:
                let before = Set(NSApp.windows.map(ObjectIdentifier.init))
                // The menu item rather than its action: SwiftUI's handler
                // isn't reachable down the responder chain when the app
                // was launched from a terminal and never became key.
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let index = menu.items.firstIndex(where: {
                          $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
                      })
                else { fail("settings: no Settings… item in the app menu"); return nil }
                menu.performActionForItem(at: index)
                var settings: NSWindow?
                _ = await wait("the Settings window", upTo: 10) {
                    settings = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
                        ?? NSApp.windows.first { $0 !== window && $0.isVisible && $0.sheetParent == nil
                            && $0.identifier?.rawValue.contains("Settings") == true }
                    return settings != nil
                }
                guard let settings else { fail("settings: the window did not open"); return nil }
                return settings
            }
            return window
        }

        /// Undoes what a step put over the window, so the next step
        /// pictures the main window again.
        func leave(_ step: SnapshotPlan.Step, window: NSWindow) {
            switch step {
            case .export: exportSheet.wrappedValue = false
            case .settings: window.close()
            case .crop, .heal:
                _ = perform(.disarmTools)
                scrollAdjustments(toEnd: false)
            default: break
            }
        }

        /// Scrolls Develop's adjustment panel, the right-most scroll view
        /// with more content than fits, to its end or back to its start.
        func scrollAdjustments(toEnd: Bool) {
            guard let root = mainWindow?.contentView?.superview else { return }
            var panel: NSScrollView?
            SnapshotHarness.forEachVisibleView(in: root) { view in
                guard let scroll = view as? NSScrollView, let document = scroll.documentView,
                      document.frame.height > scroll.contentSize.height else { return }
                if let current = panel, current.convert(current.bounds, to: nil).minX
                    >= scroll.convert(scroll.bounds, to: nil).minX { return }
                panel = scroll
            }
            guard let panel, let document = panel.documentView else { report("no adjustment panel to scroll"); return }
            let atEnd = document.isFlipped ? document.bounds.maxY - 1 : document.bounds.minY
            let atStart = document.isFlipped ? document.bounds.minY : document.bounds.maxY - 1
            document.scrollToVisible(NSRect(x: 0, y: toEnd ? atEnd : atStart, width: 1, height: 1))
        }

        /// Waits for the selection to be decoded and rendered, and for
        /// `views` image views to have presented it.
        func waitForImage(views: Int) async {
            let model = model, library = library
            guard let window = mainWindow, let root = window.contentView?.superview else { return }
            _ = await wait("the image to render", upTo: 60) {
                model.preview != nil && model.imageTitle == library.selectedImage?.fileName
                    && SnapshotHarness.imageViews(in: root).count >= views
            }
        }

        /// Polls `condition` until it holds or `seconds` pass. A timeout is
        /// reported and the step pictured anyway: an unfinished picture
        /// says more than none.
        func wait(_ what: String, upTo seconds: Double, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else {
                    fail("gave up waiting for \(what) after \(Int(seconds)) s")
                    return false
                }
                await pause(0.1)
            }
            return true
        }

        func pause(_ seconds: Double) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }
}
#endif
