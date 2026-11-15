import XCTest
import PixelEngine
@testable import latent_app

/// The Navigator outside Develop (NavigatorView.swift): its one show/hide
/// setting and View menu command, the zoom presets, which Compare pane it
/// follows, and on a real image that moving or zooming one pane through it
/// carries to a linked pane and leaves an unlinked one alone.
@MainActor
final class NavigatorOverlayTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "NavigatorOverlayTests"
    private var sharedWasShown = false

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        sharedWasShown = NavigatorSettings.shared.isShown
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        NavigatorSettings.shared.isShown = sharedWasShown
    }

    func testSettingIsRememberedUnderDevelopsKey() {
        let settings = NavigatorSettings(defaults: defaults)
        XCTAssertFalse(settings.isShown, "hidden until asked for, as Develop's section was")
        settings.isShown = true
        XCTAssertTrue(defaults.bool(forKey: "latent.navigatorExpanded"), "the key Develop's section always used")
        XCTAssertTrue(NavigatorSettings(defaults: defaults).isShown)
    }

    func testShowNavigatorCommand() {
        var state = CommandState()
        state.mode = .library
        state.hasSelection = true
        XCTAssertFalse(state.isEnabled(.view(.toggleNavigator)), "the grid has no image to navigate")
        for mode in [AppMode.loupe, .compare, .survey, .develop] {
            state.mode = mode
            XCTAssertTrue(state.isEnabled(.view(.toggleNavigator)), "\(mode)")
        }

        let views = DevelopViewState(defaults: defaults)
        let model = EditorModel()
        NavigatorSettings.shared.isShown = false
        views.perform(.toggleNavigator, load: { _ in })
        XCTAssertTrue(NavigatorSettings.shared.isShown)
        XCTAssertTrue(views.commandState(main: model).navigatorShown, "the menu's tick")
        views.perform(.toggleNavigator, load: { _ in })
        XCTAssertFalse(NavigatorSettings.shared.isShown)
        XCTAssertFalse(views.commandState(main: model).navigatorShown)
    }

    func testShowNavigatorIsInTheKeymapCatalog() {
        XCTAssertTrue(Keymap.commands.contains { $0.command == .view(.toggleNavigator) })
    }

    func testZoomPresets() {
        XCTAssertEqual(NavigatorZoomPresets.levels.map(\.title), ["Fit", "Fill", "50%", "100%", "200%"])
        XCTAssertTrue(NavigatorZoomPresets.levels.allSatisfy(ZoomLevel.menu.contains), "the status bar's levels")
        XCTAssertTrue(NavigatorZoomPresets.isCurrent(.fit, label: "Fit"))
        XCTAssertTrue(NavigatorZoomPresets.isCurrent(.percent(100), label: "100%"))
        XCTAssertFalse(NavigatorZoomPresets.isCurrent(.percent(100), label: "101%"))
        XCTAssertFalse(NavigatorZoomPresets.isCurrent(.fill, label: "Fit"))
    }

    func testComparePaneFollowed() {
        let select = EditorModel(), candidate = EditorModel()
        XCTAssertTrue(ComparePane.candidate.model(select: select, candidate: candidate) === candidate)
        XCTAssertTrue(ComparePane.select.model(select: select, candidate: candidate) === select)
        XCTAssertTrue(ComparePane.select.model(select: nil, candidate: candidate) === candidate,
                      "the Candidate while the Select pane has nothing")
    }

    // MARK: - On a real image

    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testNavigatorOnOnePaneRespectsLinkedZoom() async throws {
        let active = try await openModel()
        let other = try await openModel()
        active.linkedPane = other
        other.linkedPane = active

        active.setZoomLevel(.percent(100))
        XCTAssertFalse(active.fitMode)
        XCTAssertEqual(other.viewport.zoom, active.viewport.zoom, accuracy: 1e-6, "a preset carries to the linked pane")

        let target = CGPoint(x: active.imageSize.width * 0.25, y: active.imageSize.height * 0.3)
        active.centreView(on: target)
        XCTAssertEqual(active.viewport.center.x, target.x, accuracy: 1)
        XCTAssertEqual(other.viewport.center.x, active.viewport.center.x, accuracy: 1, "dragging the rectangle pans both")
        XCTAssertEqual(other.viewport.center.y, active.viewport.center.y, accuracy: 1)

        // Sync off: the other pane stays where it was.
        active.linkedPane = nil
        other.linkedPane = nil
        let before = other.viewport
        active.centreView(on: CGPoint(x: active.imageSize.width * 0.7, y: active.imageSize.height * 0.6))
        XCTAssertEqual(other.viewport, before)
    }
}
