import XCTest
import SwiftUI
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
}
