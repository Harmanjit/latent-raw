import XCTest
import SwiftUI
import PixelEngine
@testable import latent_app

/// The viewing aids (ViewingSettings, ViewingCommands): their settings,
/// commands, keys, the Navigator's arithmetic, the shortcuts overlay's
/// contents, and on a real image raw clipping, fine straightening and the
/// high-quality preview.
@MainActor
final class ViewingFeaturesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ViewingFeaturesTests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        let shared = ViewingSettings.shared
        shared.rawClipping = false
        shared.focusPeaking = false
        shared.colourAssessment = false
        shared.shortcutsOverlayShown = false
        shared.setPrimaryEditor(nil)
    }

    // MARK: - Settings

    func testDefaultsAndPersistence() {
        let settings = ViewingSettings(defaults: defaults)
        XCTAssertFalse(settings.focusPeaking)
        XCTAssertFalse(settings.highQualityPreview, "opt-in")
        XCTAssertEqual(settings.peakingColour, .red)
        XCTAssertEqual(settings.peakingSensitivity, .medium)
        XCTAssertEqual(settings.assessmentInset, 0.10)
        XCTAssertEqual(settings.clippingOptions, .standard)
        XCTAssertNil(settings.focusPeakingOverlay)
        XCTAssertEqual(settings.overlays(developTools: true), .none, "nothing new is drawn by default")

        settings.peakingColour = .yellow
        settings.peakingSensitivity = .high
        settings.assessmentInset = 0.5
        settings.clippingOptions = ClippingOptions(mode: .luminance)
        settings.highQualityPreview = true
        settings.focusPeaking = true
        XCTAssertEqual(settings.assessmentInset, 0.20, "held to 20%")

        let again = ViewingSettings(defaults: defaults)
        XCTAssertEqual(again.peakingColour, .yellow)
        XCTAssertEqual(again.peakingSensitivity, .high)
        XCTAssertEqual(again.assessmentInset, 0.20)
        XCTAssertEqual(again.clippingOptions.mode, .luminance)
        XCTAssertTrue(again.highQualityPreview)
        XCTAssertFalse(again.focusPeaking, "the switches last a session")
    }

    func testOverlaysFollowTheSwitches() {
        let settings = ViewingSettings(defaults: defaults)
        settings.focusPeaking = true
        settings.rawClipping = true
        settings.clippingOptions = ClippingOptions(scheme: .mono)
        let develop = settings.overlays(developTools: true)
        XCTAssertEqual(develop.focusPeaking?.colour, ViewingSettings.PeakingColour.red.linear)
        XCTAssertTrue(develop.rawClipping)
        XCTAssertEqual(develop.clipping.scheme, .mono)
        let loupe = settings.overlays(developTools: false)
        XCTAssertNotNil(loupe.focusPeaking, "peaking in Loupe and Survey too")
        XCTAssertFalse(loupe.rawClipping, "raw clipping is Develop's, as J is")
        XCTAssertEqual(loupe.clipping, .standard)
    }

    func testWelcomeShowsOnceAndNotUnderTests() {
        let settings = ViewingSettings(defaults: defaults)
        settings.showWelcomeIfFirstRun(environment: ["XCTestConfigurationFilePath": "x"])
        XCTAssertFalse(settings.welcomeShown, "never under tests")
        settings.showWelcomeIfFirstRun(environment: ["LATENT_SNAPSHOT_DIR": "/tmp/x"])
        XCTAssertFalse(settings.welcomeShown, "never under the snapshot harness")
        settings.showWelcomeIfFirstRun(environment: [:])
        XCTAssertTrue(settings.welcomeShown, "the first time")
        settings.dismissWelcome()
        XCTAssertFalse(settings.welcomeShown)
        settings.showWelcomeIfFirstRun(environment: [:])
        XCTAssertFalse(settings.welcomeShown, "only once")
        XCTAssertEqual(WelcomeSheet.helpPages.map(\.page), ["Getting-Started", "Keyboard-Shortcuts"])
        let wiki = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/wiki")
        for page in WelcomeSheet.helpPages {
            XCTAssertTrue(FileManager.default.fileExists(atPath: wiki.appendingPathComponent("\(page.page).md").path), page.page)
        }
    }

    // MARK: - Commands and keys

    func testEnabling() {
        var state = CommandState()
        state.mode = .library
        XCTAssertTrue(state.isEnabled(.viewing(.toggleFocusPeaking)))
        XCTAssertTrue(state.isEnabled(.viewing(.toggleShortcutsOverlay)))
        XCTAssertTrue(state.isEnabled(.viewing(.showWelcome)))
        XCTAssertFalse(state.isEnabled(.viewing(.toggleRawClipping)))
        XCTAssertFalse(state.isEnabled(.viewing(.straighten(tenths: 1))))
        XCTAssertFalse(state.isEnabled(.viewing(.focusExposure)))
        state.mode = .develop
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(.viewing(.toggleRawClipping)))
        XCTAssertTrue(state.isEnabled(.viewing(.straighten(tenths: -10))))
        XCTAssertTrue(state.isEnabled(.viewing(.focusExposure)))
        state.mode = .loupe
        state.viewing.rawClipping = true
        XCTAssertTrue(state.isEnabled(.viewing(.toggleRawClipping)), "turning it off is always allowed")
    }

    func testDefaultKeys() throws {
        let fine = try XCTUnwrap(Shortcuts.defaultShortcut(for: .viewing(.straighten(tenths: 1))))
        XCTAssertEqual(fine.glyphs, "⌥]")
        XCTAssertFalse(fine.isBare, "a menu key equivalent")
        XCTAssertEqual(fine.scope, .develop)
        let coarse = try XCTUnwrap(Shortcuts.defaultShortcut(for: .viewing(.straighten(tenths: -10))))
        XCTAssertEqual(coarse.modifiers, [.option, .shift])
        let overlay = try XCTUnwrap(Shortcuts.defaultShortcut(for: .viewing(.toggleShortcutsOverlay)))
        XCTAssertTrue(overlay.isBare)
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character("?"), shift: true), in: Shortcuts.all),
                       .viewing(.toggleShortcutsOverlay), "? (⇧/) reaches it")
        XCTAssertNil(Shortcuts.defaultShortcut(for: .viewing(.focusExposure)), "unbound by default")
        XCTAssertNil(Shortcuts.defaultShortcut(for: .viewing(.toggleFocusPeaking)))
        for id in ["straightenFineLeft", "straightenFineRight", "straightenLeft", "straightenRight", "focusExposure",
                   "shortcutsOverlay", "showWelcome", "focusPeaking", "rawClipping", "colourAssessment", "highQualityPreview"] {
            XCTAssertNotNil(Keymap.info(id: id), "\(id) is listed in Settings › Keyboard")
        }
    }

    // MARK: - Shortcuts overlay

    func testOverlayListsTheModesKeys() {
        let develop = ShortcutsOverlayContent.groups(for: .develop, table: Shortcuts.all)
        let developTitles = develop.flatMap(\.rows).map(\.title)
        XCTAssertTrue(developTitles.contains("Soft Proofing"), "Develop's S")
        XCTAssertFalse(developTitles.contains("Expand or Collapse Stack"), "the Library's S is not Develop's")
        XCTAssertTrue(developTitles.contains("Straighten +0.1°"))
        let library = ShortcutsOverlayContent.groups(for: .library, table: Shortcuts.all).flatMap(\.rows).map(\.title)
        XCTAssertTrue(library.contains("Expand or Collapse Stack"))
        XCTAssertFalse(library.contains("Soft Proofing"))
        XCTAssertTrue(library.contains("Pick"))
        XCTAssertEqual(develop.map(\.title), Keymap.groups.filter { g in develop.contains { $0.title == g } },
                       "groups in Settings › Keyboard's order")
        XCTAssertTrue(ShortcutsOverlayContent.applies(.library, in: .loupe))
        XCTAssertFalse(ShortcutsOverlayContent.applies(.survey, in: .compare))
    }

    // MARK: - Navigator

    func testNavigatorGeometry() throws {
        let image = CGSize(width: 6000, height: 4000)
        let navigator = CGSize(width: 300, height: 150)
        let placement = try XCTUnwrap(NavigatorGeometry.placement(imageSize: image, in: navigator))
        XCTAssertEqual(placement.scale, 0.0375, accuracy: 1e-9)
        XCTAssertEqual(placement.origin.x, 37.5, accuracy: 1e-9)
        let rect = try XCTUnwrap(NavigatorGeometry.visibleRect(CGRect(x: 0, y: 0, width: 3000, height: 2000),
                                                              imageSize: image, in: navigator))
        XCTAssertEqual(rect.width, 112.5, accuracy: 1e-9)
        XCTAssertEqual(rect.minX, 37.5, accuracy: 1e-9)
        let point = try XCTUnwrap(NavigatorGeometry.canvasPoint(at: CGPoint(x: 150, y: 75), imageSize: image, in: navigator))
        XCTAssertEqual(point.x, 3000, accuracy: 1e-6)
        XCTAssertEqual(point.y, 2000, accuracy: 1e-6)
        let outside = try XCTUnwrap(NavigatorGeometry.canvasPoint(at: CGPoint(x: 0, y: 0), imageSize: image, in: navigator))
        XCTAssertEqual(outside, .zero, "held to the picture")
        XCTAssertEqual(ZoomLevel.menu.map(\.title), ["Fit", "Fill", "25%", "50%", "100%", "200%", "400%"])
    }

    func testColourAssessmentInset() {
        XCTAssertEqual(ColourAssessment.inset(share: 0.1, size: CGSize(width: 1000, height: 600)), 60)
        XCTAssertEqual(ColourAssessment.inset(share: 0.9, size: CGSize(width: 1000, height: 600)), 120, "held to 20%")
        let settings = ViewingSettings(defaults: defaults)
        let prefs = AppPreferences.shared
        XCTAssertEqual(ColourAssessment.surroundLinear(settings, prefs), prefs.surroundLinear, "the user's surround")
        settings.colourAssessment = true
        XCTAssertEqual(ColourAssessment.surroundLinear(settings, prefs), 0.18, "18% grey")
    }

    // MARK: - On a real image

    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testRawClippingRidesOnTheMainEditorsRenders() async throws {
        let model = try await openModel()
        let other = try await openModel()
        XCTAssertFalse(model.displayOutput.rawClipMask)
        XCTAssertNil(model.preview?.rawClipMask)
        ViewingCommands.perform(.toggleRawClipping, editor: model, expandTone: {})
        XCTAssertTrue(ViewingSettings.shared.rawClipping)
        XCTAssertTrue(model.displayOutput.rawClipMask)
        XCTAssertFalse(other.displayOutput.rawClipMask, "Survey's panes don't pay for it")
        let mask = try XCTUnwrap(model.preview?.rawClipMask, "the toggle re-renders with the mask")
        XCTAssertEqual(mask.width, model.preview?.texture.width)
        ViewingCommands.perform(.toggleRawClipping, editor: model, expandTone: {})
        XCTAssertNil(model.preview?.rawClipMask)
    }

    func testFineStraightenIsOneUndoStepEach() async throws {
        let model = try await openModel()
        let before = model.history.steps.count
        model.nudgeStraighten(by: 0.1)
        XCTAssertEqual(model.parameters.crop.angle, 0.1, accuracy: 1e-5)
        XCTAssertEqual(model.history.steps.count, before + 1)
        ViewingCommands.perform(.straighten(tenths: 10), editor: model, expandTone: {})
        XCTAssertEqual(model.parameters.crop.angle, 1.1, accuracy: 1e-5)
        XCTAssertEqual(model.history.steps.count, before + 2)
        ViewingCommands.perform(.straighten(tenths: -1), editor: model, expandTone: {})
        XCTAssertEqual(model.parameters.crop.angle, 1.0, accuracy: 1e-5)
    }

    func testHighQualityPreviewReplacesTheBinnedOneAtFit() async throws {
        let model = try await openModel()
        let settings = ViewingSettings.shared
        let wasOn = settings.highQualityPreview
        defer { settings.highQualityPreview = wasOn }
        settings.highQualityPreview = true
        settings.setPrimaryEditor(model)
        XCTAssertTrue(model.fitMode)
        XCTAssertTrue(model.wantsHighQualityPreview)
        let binned = try XCTUnwrap(model.preview)
        model.renderHighQualityPreview()
        let high = try XCTUnwrap(model.preview)
        XCTAssertNotEqual(high.generation, binned.generation)
        XCTAssertEqual(high.coverage.width, binned.coverage.width, accuracy: 8, "the same sensor area")
        let longEdge = Int((max(model.sensorSize.width, model.sensorSize.height) * model.viewport.zoom).rounded(.up))
        XCTAssertEqual(max(high.texture.width, high.texture.height), longEdge, "shrunk to the size shown")
        settings.highQualityPreview = false
        model.highQualityPreviewSettingChanged()
        XCTAssertNotEqual(model.preview?.generation, high.generation, "off: back to the binned preview")
    }
}
