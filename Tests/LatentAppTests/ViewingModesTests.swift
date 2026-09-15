import XCTest
import SwiftUI
import Catalog
@testable import latent_app

/// Full-screen image mode's fly-outs and the second display's Loupe, as
/// far as they are arithmetic and rules.
@MainActor
final class ViewingModesTests: XCTestCase {
    private var size: CGSize { CGSize(width: 1512, height: 945) }
    private var all: Set<FlyoutEdge> { [.left, .right, .bottom] }

    // MARK: Fly-outs

    func testEdgesOpenOnlyRightAgainstThem() {
        XCTAssertEqual(FlyoutGeometry.edge(at: CGPoint(x: 0, y: 400), in: size, available: all), .left)
        XCTAssertEqual(FlyoutGeometry.edge(at: CGPoint(x: 1511, y: 400), in: size, available: all), .right)
        XCTAssertEqual(FlyoutGeometry.edge(at: CGPoint(x: 700, y: 944), in: size, available: all), .bottom)
        XCTAssertNil(FlyoutGeometry.edge(at: CGPoint(x: 700, y: 0), in: size, available: all),
                     "the top is the menu bar's")
        XCTAssertNil(FlyoutGeometry.edge(at: CGPoint(x: 20, y: 400), in: size, available: all),
                     "passing near an edge while panning opens nothing")
        XCTAssertNil(FlyoutGeometry.edge(at: CGPoint(x: 1511, y: 400), in: size, available: [.left, .bottom]),
                     "Loupe has no adjustments to show")
        XCTAssertNil(FlyoutGeometry.edge(at: CGPoint(x: 0, y: 400), in: .zero, available: all))
    }

    func testCornersGoToTheNearerEdgeAndTheFilmstripOnATie() {
        XCTAssertEqual(FlyoutGeometry.edge(at: CGPoint(x: 0, y: 945), in: size, available: all), .bottom)
        XCTAssertEqual(FlyoutGeometry.edge(at: CGPoint(x: 0, y: 942), in: size, available: all), .left)
        XCTAssertEqual(FlyoutGeometry.edge(at: CGPoint(x: 0, y: 945), in: size, available: [.left]), .left)
    }

    func testAnOpenPanelStaysOpenUnderThePointerAndClosesWhenItLeaves() {
        let thickness = FullScreenImagePolicy.thickness
        func next(_ current: FlyoutEdge?, _ x: CGFloat, _ y: CGFloat, _ available: Set<FlyoutEdge>? = nil) -> FlyoutEdge? {
            FlyoutGeometry.openEdge(after: current, pointer: CGPoint(x: x, y: y), in: size,
                                    thickness: thickness, available: available ?? all)
        }
        XCTAssertEqual(next(nil, 0, 300), .left)
        XCTAssertEqual(next(.left, 150, 300), .left, "over the panel")
        XCTAssertEqual(next(.left, 150, 944), .left, "the panel beats the filmstrip's edge it covers")
        XCTAssertNil(next(.left, 400, 300), "back over the image")
        XCTAssertEqual(next(.right, 1300, 500), .right)
        XCTAssertEqual(next(.bottom, 900, 880), .bottom)
        XCTAssertNil(next(.bottom, 900, 700))
        XCTAssertEqual(next(.left, 1511, 300), .right, "straight across to the other edge")
        XCTAssertNil(next(.right, 1300, 500, [.left, .bottom]), "the mode changed and took the panel's edge away")
    }

    func testPanelFramesAreFlushWithTheirEdges() {
        XCTAssertEqual(FlyoutGeometry.frame(for: .left, thickness: 221, in: size), CGRect(x: 0, y: 0, width: 221, height: 945))
        XCTAssertEqual(FlyoutGeometry.frame(for: .right, thickness: 281, in: size), CGRect(x: 1231, y: 0, width: 281, height: 945))
        XCTAssertEqual(FlyoutGeometry.frame(for: .bottom, thickness: 87, in: size), CGRect(x: 0, y: 858, width: 1512, height: 87))
    }

    func testFullScreenIsForOneImage() {
        XCTAssertEqual(FullScreenImagePolicy.entryMode(from: .library), .loupe)
        XCTAssertEqual(FullScreenImagePolicy.entryMode(from: .compare), .loupe)
        XCTAssertEqual(FullScreenImagePolicy.entryMode(from: .loupe), .loupe)
        XCTAssertEqual(FullScreenImagePolicy.entryMode(from: .develop), .develop)
        XCTAssertTrue(FullScreenImagePolicy.keepsFullScreen(in: .loupe))
        XCTAssertTrue(FullScreenImagePolicy.keepsFullScreen(in: .develop))
        XCTAssertFalse(FullScreenImagePolicy.keepsFullScreen(in: .library))
        XCTAssertFalse(FullScreenImagePolicy.keepsFullScreen(in: .compare))
    }

    func testPanelsOnOfferFollowTheMode() {
        XCTAssertEqual(FullScreenImagePolicy.availableEdges(mode: .develop, hasFolder: true), [.left, .right, .bottom])
        XCTAssertEqual(FullScreenImagePolicy.availableEdges(mode: .loupe, hasFolder: true), [.left, .bottom])
        XCTAssertEqual(FullScreenImagePolicy.availableEdges(mode: .develop, hasFolder: false), [.left, .right],
                       "a file opened on its own has no filmstrip")
        XCTAssertTrue(FullScreenImagePolicy.keepsPanel(.right))
        XCTAssertFalse(FullScreenImagePolicy.keepsPanel(.bottom))
    }

    /// Without a window (as in a test) the mode still switches panels, and
    /// leaving forgets what was built.
    func testModeShowsOnePanelAndForgetsThemOnLeaving() {
        let mode = FullScreenImageMode()
        mode.show(.left, animated: false)
        XCTAssertNil(mode.openEdge, "nothing shows while the mode is off")
        mode.enter(window: nil)
        XCTAssertTrue(mode.isActive)
        mode.pointerMoved(to: CGPoint(x: 1511, y: 400), in: size, available: all)
        XCTAssertEqual(mode.openEdge, .right)
        mode.pointerMoved(to: CGPoint(x: 700, y: 400), in: size, available: all)
        XCTAssertNil(mode.openEdge)
        XCTAssertEqual(mode.builtEdges, [.right], "Develop's panel is kept once built")
        mode.show(.bottom, animated: false)
        XCTAssertEqual(mode.builtEdges, [.right])
        mode.leave()
        XCTAssertFalse(mode.isActive)
        XCTAssertNil(mode.openEdge)
        XCTAssertTrue(mode.builtEdges.isEmpty)
    }

    /// The image and its panels reach the top of the window. The main
    /// window's toolbar, which SwiftUI hides only as far as its views go,
    /// keeps its height reserved at the top of the content, full screen
    /// included, where the image was laid out below an empty grey strip.
    func testTheFullScreenImageAndPanelsReachTheTopOfTheWindow() throws {
        let mode = FullScreenImageMode()
        let image = Measured(), panel = Measured()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "ViewingModesTests")
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Probe(into: image)
            .fullScreenFlyouts(mode, available: [.left],
                               left: { Probe(into: panel).frame(width: 220) },
                               right: { EmptyView() }, bottom: { EmptyView() }))
        settle { !image.top.isNaN }
        let reserved = try XCTUnwrap(window.contentView?.safeAreaInsets.top)
        XCTAssertGreaterThan(reserved, 28, "the titlebar and the toolbar keep a strip, as in the app")
        XCTAssertEqual(image.top, reserved, "a window keeps clear of its titlebar and toolbar")

        mode.enter(window: nil)
        mode.show(.left, animated: false)
        settle { image.top == 0 && panel.top == 0 && panel.inset == 0 }
        XCTAssertEqual(image.top, 0, "nothing above the full-screen image")
        XCTAssertEqual(image.inset, 0)
        XCTAssertEqual(panel.top, 0, "the panels reach the top too")
        XCTAssertEqual(panel.inset, 0, "with nothing kept clear inside them")

        mode.leave()
        settle { image.top == reserved }
        XCTAssertEqual(image.top, reserved, "leaving puts the image back below the toolbar")
    }

    // MARK: Full screen against the window's own

    /// F again on the way in: AppKit ignores a toggle until the window has
    /// arrived (even from inside didEnter), which left the window full
    /// screen with the mode gone.
    func testLeavingOnTheWayInTakesTheWindowBackOnceItArrives() {
        let (mode, window) = fullScreenFixture()
        mode.enter(window: window)
        XCTAssertEqual(window.animation, .entering)
        mode.leave()
        XCTAssertFalse(mode.isActive)
        window.finishAnimation()
        settle { window.animation == .exiting }
        XCTAssertEqual(window.animation, .exiting, "asked out once it arrived")
        window.finishAnimation()
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertEqual(window.ignoredToggles, 0)
        XCTAssertFalse(mode.isActive)
    }

    /// F on the way out: a toggle then cuts the animation short and starts
    /// an enter AppKit abandons, so the mode waits for the window to be out
    /// and then takes it back in.
    func testEnteringOnTheWayOutGoesBackInOnceOut() {
        let (mode, window) = fullScreenFixture()
        mode.enter(window: window)
        window.finishAnimation()
        XCTAssertTrue(mode.hasArrived)
        mode.leave()
        XCTAssertEqual(window.animation, .exiting)
        mode.enter(window: window)
        XCTAssertTrue(mode.isActive)
        XCTAssertFalse(mode.hasArrived, "still on its way out")
        XCTAssertEqual(window.animation, .exiting, "not asked while it animates")
        window.finishAnimation()
        settle { window.animation == .entering }
        XCTAssertEqual(window.animation, .entering, "asked in once out")
        window.finishAnimation()
        XCTAssertTrue(window.styleMask.contains(.fullScreen))
        XCTAssertTrue(mode.isActive)
        XCTAssertTrue(mode.hasArrived)
        XCTAssertEqual(window.interruptedExits, 0)
    }

    /// ⌃⌘F out of full screen, then F before the animation ends.
    func testEnteringWhileTheWindowLeavesFullScreenByItselfWaitsForIt() {
        let (mode, window) = fullScreenFixture()
        window.toggleFullScreen(nil)
        window.finishAnimation()
        window.toggleFullScreen(nil)
        XCTAssertEqual(window.animation, .exiting)
        mode.enter(window: window)
        XCTAssertEqual(window.animation, .exiting)
        mode.checkAnimation()
        XCTAssertEqual(mode.state.phase, .exiting, "an animation begun before F is not taken as overdue")
        window.finishAnimation()
        settle { window.animation == .entering }
        window.finishAnimation()
        XCTAssertTrue(window.styleMask.contains(.fullScreen))
        XCTAssertTrue(mode.hasArrived)
        mode.leave()
        XCTAssertEqual(window.animation, .exiting, "the mode made it full screen, so leaving undoes it")
        window.finishAnimation()
        XCTAssertEqual(window.interruptedExits, 0)
    }

    /// The green button, then F before the window has arrived: the mode
    /// asks nothing of it, and leaves it full screen after.
    func testEnteringOnAWayInStartedElsewhereLeavesTheWindowFullScreen() {
        let (mode, window) = fullScreenFixture()
        window.toggleFullScreen(nil)
        mode.enter(window: window)
        XCTAssertFalse(mode.hasArrived)
        window.finishAnimation()
        XCTAssertTrue(mode.hasArrived)
        mode.leave()
        settle { window.animation != .none }
        XCTAssertEqual(window.animation, .none)
        XCTAssertTrue(window.styleMask.contains(.fullScreen), "it was full screen before the mode")
        XCTAssertEqual(window.ignoredToggles, 0)
    }

    /// F, Esc and F again, all on the way in, end full screen; ⌃⌘F then
    /// takes the panels back as the window starts out, and F on that way
    /// out goes back in once it is out.
    func testQuickPressesAndControlCommandFEndWhereTheWindowIs() {
        let (mode, window) = fullScreenFixture()
        mode.enter(window: window)
        mode.leave()
        mode.enter(window: window)
        window.finishAnimation()
        settle { window.animation != .none }
        XCTAssertEqual(window.animation, .none, "not asked out: F came back before it arrived")
        XCTAssertTrue(mode.hasArrived)
        window.toggleFullScreen(nil)
        XCTAssertFalse(mode.isActive, "the panels come back as the window starts out")
        mode.enter(window: window)
        XCTAssertEqual(window.animation, .exiting)
        window.finishAnimation()
        settle { window.animation == .entering }
        window.finishAnimation()
        XCTAssertTrue(mode.hasArrived)
        XCTAssertEqual(window.ignoredToggles, 0)
        XCTAssertEqual(window.interruptedExits, 0)
    }

    /// ⌃⌘F on the mode's own way out cuts it short into an enter AppKit
    /// drops without a word: the mode notices the window back in a
    /// window and is off, and F then works again.
    func testAnEnterTheWindowDropsEndsTheMode() {
        let (mode, window) = fullScreenFixture()
        mode.enter(window: window)
        window.finishAnimation()
        mode.leave()
        mode.enter(window: window)
        window.toggleFullScreen(nil)
        XCTAssertEqual(window.interruptedExits, 1)
        window.finishAnimation()
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        mode.checkAnimation()
        XCTAssertFalse(mode.isActive, "no image alone in a window")
        mode.enter(window: window)
        XCTAssertEqual(window.animation, .entering)
        window.finishAnimation()
        XCTAssertTrue(mode.hasArrived)
    }

    func testClosingTheWindowOnTheWayInEndsTheMode() {
        let (mode, window) = fullScreenFixture()
        mode.enter(window: window)
        window.close()
        XCTAssertFalse(mode.isActive)
        XCTAssertFalse(mode.state.needsToggle)
    }

    /// An animation whose did notification never comes is taken as ended
    /// where the style mask says, rather than waited on for ever.
    func testAnAnimationThatNeverEndsIsNotWaitedOnForEver() {
        let (mode, window) = fullScreenFixture()
        mode.enter(window: window)
        mode.checkAnimation()
        XCTAssertFalse(mode.hasArrived)
        mode.checkAnimation(now: Date().addingTimeInterval(FullScreenImageMode.animationTimeout + 1))
        XCTAssertTrue(mode.hasArrived)
    }

    /// The mode asks the window to change only while it is still, and
    /// follows what it does meanwhile.
    func testTheStateWaitsForTheWindowToBeStill() {
        var state = FullScreenImageState()
        state.handle(.enter(drivesWindow: true))
        XCTAssertTrue(state.needsToggle)
        XCTAssertFalse(state.hasArrived)
        state.handle(.willEnter)
        state.handle(.leave)
        XCTAssertFalse(state.needsToggle, "not on the way in")
        state.handle(.didEnter)
        XCTAssertTrue(state.needsToggle, "out once arrived")
        state.handle(.willExit(byMode: true))
        state.handle(.enter(drivesWindow: true))
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.needsToggle, "not on the way out")
        XCTAssertFalse(state.hasArrived)
        state.handle(.didExit)
        XCTAssertTrue(state.needsToggle, "back in once out")
        state.handle(.willEnter)
        state.handle(.didEnter)
        XCTAssertTrue(state.hasArrived)
        XCTAssertTrue(state.ownsFullScreen)
    }

    func testTheStateKeepsToFullScreenMadeElsewhere() {
        var state = FullScreenImageState(phase: .entering)
        state.handle(.enter(drivesWindow: true))
        XCTAssertFalse(state.ownsFullScreen)
        XCTAssertFalse(state.hasArrived)
        state.handle(.didEnter)
        XCTAssertTrue(state.hasArrived)
        state.handle(.willExit(byMode: false))
        XCTAssertFalse(state.isActive, "⌃⌘F takes the mode with it")
        state.handle(.enter(drivesWindow: true))
        XCTAssertTrue(state.ownsFullScreen, "F on that way out makes it full screen again")
        state.handle(.didExit)
        XCTAssertTrue(state.needsToggle)
    }

    func testTheStateGivesUpOnAWindowThatWontChange() {
        var state = FullScreenImageState()
        state.handle(.enter(drivesWindow: true))
        state.handle(.failed(isFullScreen: false))
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.needsToggle)
        state = FullScreenImageState(phase: .fullScreen)
        state.handle(.enter(drivesWindow: true))
        state.handle(.leave)
        XCTAssertFalse(state.needsToggle, "not the mode's to undo")
        state = FullScreenImageState()
        for event: FullScreenImageState.Event in [.enter(drivesWindow: true), .willEnter, .didEnter, .leave] {
            state.handle(event)
        }
        state.handle(.failed(isFullScreen: true))
        XCTAssertFalse(state.needsToggle, "not asked again")
        XCTAssertEqual(state.phase, .fullScreen)
        state.handle(.enter(drivesWindow: false))
        XCTAssertTrue(state.hasArrived)
        state = FullScreenImageState()
        state.handle(.enter(drivesWindow: false))
        XCTAssertTrue(state.hasArrived, "no window: only the layout")
        state.handle(.closed)
        XCTAssertFalse(state.isActive)
    }

    /// Every sequence of eight of F, ⌃⌘F, the window's animation ending and
    /// the window closing, against a model of AppKit's full screen: the mode
    /// never asks an animating window, and once all is still it is on only
    /// in a full-screen window and owns no full screen when off.
    func testEveryInterleavingEndsWhereTheWindowIs() {
        let length = 8
        for sequence in 0..<Int(pow(4, Double(length))) {
            var sim = FullScreenSimulation()
            var code = sequence
            for _ in 0..<length {
                switch code % 4 {
                case 0: sim.pressF()
                case 1: sim.toggle(byMode: false)
                case 2: sim.finishAnimation()
                default: sim.close()
                }
                code /= 4
            }
            sim.settle()
            guard sim.requestsWhileAnimating == 0, sim.state.phase == sim.window,
                  !sim.state.isActive || sim.window == .fullScreen,
                  sim.state.isActive || !sim.state.ownsFullScreen else {
                return XCTFail("sequence \(sequence): \(sim.state), window \(sim.window), "
                               + "\(sim.requestsWhileAnimating) requests while animating")
            }
        }
    }

    func testCommandsEnable() {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.fullScreenImage))
        XCTAssertFalse(state.isEnabled(.secondaryDisplay), "one display")
        state.hasSelection = true
        XCTAssertTrue(state.isEnabled(.fullScreenImage), "the grid goes to Loupe")
        state = CommandState()
        state.mode = .develop
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(.fullScreenImage), "a file opened on its own")
        state = CommandState()
        state.fullScreenImage = true
        XCTAssertTrue(state.isEnabled(.fullScreenImage), "always leaves")
        state.hasSecondDisplay = true
        XCTAssertTrue(state.isEnabled(.secondaryDisplay))
        state.hasSecondDisplay = false
        state.secondaryDisplayShowing = true
        XCTAssertTrue(state.isEnabled(.secondaryDisplay), "closes after its display went")
        XCTAssertEqual(Shortcuts.shortcut(for: .fullScreenImage)?.glyphs, "F")
        XCTAssertNil(Shortcuts.shortcut(for: .secondaryDisplay))
    }

    // MARK: Second display

    private func screen(_ id: UInt32, x: CGFloat, width: CGFloat = 1920, height: CGFloat = 1080,
                        menuBar: CGFloat = 25, dockBottom: CGFloat = 0, notch: CGFloat = 0) -> ScreenInfo {
        let frame = CGRect(x: x, y: 0, width: width, height: height)
        let visible = CGRect(x: x, y: dockBottom, width: width, height: height - menuBar - dockBottom)
        return ScreenInfo(id: id, frame: frame, visibleFrame: visible, safeAreaTop: notch)
    }

    func testTheLoupeGoesToAnotherScreen() {
        let laptop = screen(1, x: 0), left = screen(2, x: -2560), right = screen(3, x: 1920)
        XCTAssertNil(SecondaryDisplayPlacement.target(screens: [laptop], mainWindowScreen: 1))
        XCTAssertEqual(SecondaryDisplayPlacement.target(screens: [laptop, right], mainWindowScreen: 1)?.id, 3)
        XCTAssertEqual(SecondaryDisplayPlacement.target(screens: [laptop, right, left], mainWindowScreen: 1)?.id, 2,
                       "the leftmost of the others")
        XCTAssertEqual(SecondaryDisplayPlacement.target(screens: [laptop, right], mainWindowScreen: 3)?.id, 1)
        XCTAssertEqual(SecondaryDisplayPlacement.target(screens: [laptop, right], mainWindowScreen: nil)?.id, 1)
    }

    func testADisconnectedScreenIsGone() {
        let screens = [screen(1, x: 0), screen(3, x: 1920, width: 3840)]
        XCTAssertEqual(SecondaryDisplayPlacement.connected(3, in: screens)?.frame.width, 3840)
        XCTAssertNil(SecondaryDisplayPlacement.connected(2, in: screens))
    }

    func testThePictureKeepsClearOfTheMenuBarDockAndNotch() {
        XCTAssertEqual(SecondaryDisplayPlacement.contentInsets(for: screen(1, x: 0)),
                       EdgeInsets(top: 25, leading: 0, bottom: 0, trailing: 0))
        XCTAssertEqual(SecondaryDisplayPlacement.contentInsets(for: screen(1, x: 0, menuBar: 0, dockBottom: 70)),
                       EdgeInsets(top: 0, leading: 0, bottom: 70, trailing: 0))
        XCTAssertEqual(SecondaryDisplayPlacement.contentInsets(for: screen(1, x: 0, menuBar: 32, notch: 38)).top, 38)
        let sideDock = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 60, y: 0, width: 1860, height: 1055))
        XCTAssertEqual(SecondaryDisplayPlacement.contentInsets(for: sideDock),
                       EdgeInsets(top: 25, leading: 60, bottom: 0, trailing: 0))
    }

    /// The Loupe draws the model it is given: in Survey the focused pane's.
    /// The model it leaves forgets the display's size and headroom.
    func testTheLoupeFollowsTheModelItIsGiven() throws {
        let display = SecondaryDisplay()
        let editor = EditorModel(), pane = EditorModel()
        display.follow(pane)
        XCTAssertNil(display.drawnModel, "not showing")
        display.show(model: editor, library: Library(), beside: nil, debugSize: CGSize(width: 320, height: 200))
        try XCTSkipUnless(display.isShowing, "no screen to open it on")
        defer { display.close() }
        XCTAssertTrue(display.drawnModel === editor)
        editor.secondaryViewportDidResize(to: CGSize(width: 640, height: 400))
        display.follow(pane)
        XCTAssertTrue(display.drawnModel === pane)
        XCTAssertEqual(editor.secondaryDrawableSize, .zero)
        display.follow(editor)
        XCTAssertTrue(display.drawnModel === editor)
    }

    func testThePreviewIsFineEnoughForBothScreens() {
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: nil, secondaryZoom: nil), 1)
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.2, secondaryZoom: nil), 2, "the editor's own rule")
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.1, secondaryZoom: nil), 5)
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0.1, secondaryZoom: 0.6), 1, "a 5K second display")
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: nil, secondaryZoom: 0.2), 2, "the grid in the main window")
        XCTAssertEqual(SecondaryPreview.previewQuads(mainZoom: 0, secondaryZoom: 0.2), 2)
    }

    func testTheRenderCeilingIsTheBrighterScreens() {
        XCTAssertEqual(SecondaryPreview.renderPotential(main: 1, secondary: nil), 1)
        XCTAssertEqual(SecondaryPreview.renderPotential(main: 1, secondary: 16), 16)
        XCTAssertEqual(SecondaryPreview.renderPotential(main: 5, secondary: 1), 5)
    }

    private func fullScreenFixture() -> (FullScreenImageMode, FullScreenWindowDouble) {
        let window = FullScreenWindowDouble(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return (FullScreenImageMode(), window)
    }

    /// Lets SwiftUI lay out until `done`, for up to two seconds.
    private func settle(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while !done() && Date() < deadline
    }
}

/// Where a view sits in its window, as SwiftUI lays it out.
@MainActor
private final class Measured {
    var top: CGFloat = .nan
    var inset: CGFloat = .nan
}

private struct Probe: View {
    let into: Measured

    var body: some View {
        GeometryReader { proxy in
            let _ = into.top = proxy.frame(in: .global).minY
            let _ = into.inset = proxy.safeAreaInsets.top
            Color.black
        }
    }
}

/// A window that goes in and out of full screen as AppKit's do, as far as
/// full-screen image mode can tell, without taking over the screen. Its
/// animations end when the test says. Measured on macOS 15: the style mask
/// changes as soon as a toggle starts; a toggle on the way in (even from
/// inside didEnter) is ignored; a toggle on the way out posts didExit at
/// once and willEnter, then the enter fails and the window drops back
/// with no notification (only the delegate hears of it).
@MainActor
private final class FullScreenWindowDouble: NSWindow {
    enum Animation { case none, entering, exiting }
    private(set) var animation = Animation.none
    private(set) var ignoredToggles = 0
    private(set) var interruptedExits = 0
    private var isFull = false
    private var postingDidEnter = false
    private var enterFails = false

    override var styleMask: NSWindow.StyleMask {
        get { isFull ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }

    override func toggleFullScreen(_ sender: Any?) {
        switch animation {
        case .entering:
            ignoredToggles += 1
        case .none where postingDidEnter:
            ignoredToggles += 1
        case .none:
            if isFull { begin(.exiting) } else { begin(.entering) }
        case .exiting:
            interruptedExits += 1
            animation = .none
            post(NSWindow.didExitFullScreenNotification)
            begin(.entering)
            enterFails = true
        }
    }

    /// The animation under way ends: the window arrives, or an enter that
    /// cut a way out short drops back to a window unannounced.
    func finishAnimation() {
        switch animation {
        case .none:
            return
        case .entering where enterFails:
            enterFails = false
            animation = .none
            isFull = false
        case .entering:
            animation = .none
            postingDidEnter = true
            post(NSWindow.didEnterFullScreenNotification)
            postingDidEnter = false
        case .exiting:
            animation = .none
            post(NSWindow.didExitFullScreenNotification)
        }
    }

    private func begin(_ next: Animation) {
        animation = next
        if next == .entering {
            post(NSWindow.willEnterFullScreenNotification)
            isFull = true
        } else {
            post(NSWindow.willExitFullScreenNotification)
            isFull = false
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }
}

/// AppKit's full screen as the mode sees it, for `FullScreenImageState`
/// alone: the real mode's requests after a did notification run a turn
/// later, and its check notices a dropped enter.
private struct FullScreenSimulation {
    var state = FullScreenImageState()
    var window = FullScreenImageState.Phase.windowed
    var requestsWhileAnimating = 0
    private var enterFails = false

    mutating func pressF() {
        state.handle(state.isActive ? .leave : .enter(drivesWindow: true))
        request()
    }

    mutating func toggle(byMode: Bool) {
        switch window {
        case .windowed:
            window = .entering
            state.handle(.willEnter)
        case .fullScreen:
            window = .exiting
            state.handle(.willExit(byMode: byMode))
        case .entering:
            if byMode { requestsWhileAnimating += 1 }
        case .exiting:
            if byMode { requestsWhileAnimating += 1 }
            state.handle(.didExit)
            window = .entering
            state.handle(.willEnter)
            enterFails = true
        }
        if !byMode { request() }
    }

    mutating func finishAnimation() {
        switch window {
        case .entering where enterFails:
            enterFails = false
            window = .windowed
            state.handle(.failed(isFullScreen: false))
        case .entering:
            window = .fullScreen
            state.handle(.didEnter)
        case .exiting:
            window = .windowed
            state.handle(.didExit)
        case .windowed, .fullScreen:
            return
        }
        request()
    }

    mutating func close() {
        state.handle(.closed)
        state = FullScreenImageState()
        window = .windowed
        enterFails = false
    }

    mutating func settle() {
        for _ in 0..<8 {
            request()
            finishAnimation()
        }
    }

    private mutating func request() {
        if state.needsToggle { toggle(byMode: true) }
    }
}
