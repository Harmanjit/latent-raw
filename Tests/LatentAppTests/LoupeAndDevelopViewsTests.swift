import XCTest
import AppKit
import PixelEngine
import Catalog
@testable import latent_app

/// View › Loupe Overlay, Develop's Before/After views and settings, and
/// Reference view.
@MainActor
final class LoupeAndDevelopViewsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "LoupeAndDevelopViewsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Overlay geometry

    func testImageRectFollowsTheViewportInPoints() {
        let image = CGSize(width: 6000, height: 4000)
        let drawable = CGSize(width: 2400, height: 1600)
        let fit = ViewportTransform.fit(imageSize: image, drawableSize: drawable)
        let rect = LoupeOverlayGeometry.imageRect(imageSize: image, viewport: fit, drawableSize: drawable,
                                                  viewSize: CGSize(width: 1200, height: 800))
        XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1200, accuracy: 0.01)
        XCTAssertEqual(rect.height, 800, accuracy: 0.01)
        XCTAssertEqual(LoupeOverlayGeometry.imageRect(imageSize: image, viewport: fit, drawableSize: drawable,
                                                      viewSize: .zero), .zero)
    }

    func testGridLinesAreSquaresInsideThePicture() {
        let lines = LoupeOverlayGeometry.gridLines(in: CGRect(x: 10, y: 20, width: 100, height: 50), cell: 25)
        XCTAssertEqual(lines.xs, [35, 60, 85])
        XCTAssertEqual(lines.ys, [45])
        XCTAssertTrue(LoupeOverlayGeometry.gridLines(in: .zero, cell: 25).xs.isEmpty)
    }

    func testLayoutImageFitsScalesAndMoves() {
        let picture = CGRect(x: 0, y: 0, width: 300, height: 200)
        let fitted = LoupeOverlayGeometry.layoutRect(imageSize: CGSize(width: 100, height: 100), in: picture,
                                                     scale: 1, offset: .zero)
        XCTAssertEqual(fitted, CGRect(x: 50, y: 0, width: 200, height: 200))
        let moved = LoupeOverlayGeometry.layoutRect(imageSize: CGSize(width: 100, height: 100), in: picture,
                                                    scale: 0.5, offset: CGPoint(x: 0.1, y: -0.25))
        XCTAssertEqual(moved, CGRect(x: 130, y: 0, width: 100, height: 100))
    }

    func testGuidesStayOnThePicture() {
        XCTAssertEqual(LoupeOverlayGeometry.guideFraction(60, from: 10, length: 100), 0.5)
        XCTAssertEqual(LoupeOverlayGeometry.guideFraction(-40, from: 10, length: 100), 0)
        XCTAssertEqual(LoupeOverlayGeometry.guideFraction(400, from: 10, length: 100), 1)
        XCTAssertEqual(LoupeOverlayGeometry.guideFraction(5, from: 0, length: 0), 0.5)
    }

    // MARK: Overlay settings

    func testOverlaySettingsAreRememberedAndGuidesReset() {
        let settings = LoupeOverlaySettings(defaults: defaults, directory: directory)
        XCTAssertFalse(settings.isShown)
        XCTAssertTrue(settings.showsGrid)
        settings.isShown = true
        settings.gridSize = 100
        settings.guideX = 0.2
        settings.guideY = 0.9
        let again = LoupeOverlaySettings(defaults: defaults, directory: directory)
        XCTAssertTrue(again.isShown)
        XCTAssertEqual(again.gridSize, 100)
        XCTAssertEqual(again.guideX, 0.2)
        again.resetGuides()
        XCTAssertEqual(again.guideX, 0.5)
        XCTAssertEqual(again.guideY, 0.5)
    }

    func testLayoutImageIsCopiedInAndShown() throws {
        let settings = LoupeOverlaySettings(defaults: defaults, directory: directory)
        XCTAssertNil(settings.layoutImage)
        settings.layoutScale = 2
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName)-layout.png")
        defer { try? FileManager.default.removeItem(at: source) }
        try Self.writePNG(to: source)
        try settings.adoptLayoutImage(from: source)
        XCTAssertNotNil(settings.layoutImage)
        XCTAssertTrue(settings.showsLayoutImage)
        XCTAssertTrue(settings.isShown)
        XCTAssertEqual(settings.layoutScale, 1, "a new layout image starts fitted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.layoutFileURL.path))
        // Choosing another replaces the copy; the original may go.
        try settings.adoptLayoutImage(from: source)
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(LoupeOverlaySettings(defaults: defaults, directory: directory).layoutImage)

        let notAnImage = FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName)-bad.png")
        defer { try? FileManager.default.removeItem(at: notAnImage) }
        try Data("not a png".utf8).write(to: notAnImage)
        XCTAssertThrowsError(try settings.adoptLayoutImage(from: notAnImage))
    }

    private static func writePNG(to url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: Layouts and commands

    func testShiftYStepsThroughTheLayoutsAndBack() {
        XCTAssertEqual(nextBeforeAfterStep(kind: .single, layout: .topBottom), .leftRight)
        XCTAssertEqual(nextBeforeAfterStep(kind: .reference, layout: .topBottom), .leftRight)
        XCTAssertEqual(nextBeforeAfterStep(kind: .beforeAfter, layout: .leftRight), .leftRightSplit)
        XCTAssertEqual(nextBeforeAfterStep(kind: .beforeAfter, layout: .leftRightSplit), .topBottom)
        XCTAssertEqual(nextBeforeAfterStep(kind: .beforeAfter, layout: .topBottom), .topBottomSplit)
        XCTAssertNil(nextBeforeAfterStep(kind: .beforeAfter, layout: .topBottomSplit))
    }

    func testSplitsShowTheAfterInTheSecondHalf() {
        XCTAssertNil(BeforeAfterLayout.leftRight.afterFraction)
        XCTAssertNil(BeforeAfterLayout.topBottom.afterFraction)
        XCTAssertEqual(BeforeAfterLayout.leftRightSplit.afterFraction, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(BeforeAfterLayout.topBottomSplit.afterFraction, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        XCTAssertTrue(BeforeAfterLayout.topBottomSplit.isStacked)
        XCTAssertFalse(BeforeAfterLayout.leftRightSplit.isStacked)
    }

    func testViewCommandsAreEnabledWhereTheyApply() {
        var state = CommandState()
        state.mode = .library
        state.hasImage = true
        state.hasSelection = true
        XCTAssertFalse(state.isEnabled(.view(.toggleOverlay)))
        XCTAssertTrue(state.isEnabled(.view(.chooseLayoutImage)))
        XCTAssertFalse(state.isEnabled(.view(.cycleBeforeAfter)))
        state.mode = .loupe
        XCTAssertTrue(state.isEnabled(.view(.toggleOverlay)))
        XCTAssertFalse(state.isEnabled(.view(.referenceView)))
        state.mode = .develop
        XCTAssertTrue(state.isEnabled(.view(.cycleBeforeAfter)))
        XCTAssertTrue(state.isEnabled(.view(.copyAfterToBefore)))
        XCTAssertFalse(state.isEnabled(.view(.resetBefore)))
        XCTAssertFalse(state.isEnabled(.view(.resetGuides)))
        XCTAssertFalse(state.isEnabled(.view(.swapReference)))
        state.views.developView = .reference
        state.views.hasReference = true
        state.views.hasCustomBefore = true
        state.views.overlayGuides = true
        XCTAssertTrue(state.isEnabled(.view(.swapReference)))
        XCTAssertTrue(state.isEnabled(.view(.resetBefore)))
        XCTAssertTrue(state.isEnabled(.view(.resetGuides)))
        state.hasImage = false
        XCTAssertFalse(state.isEnabled(.view(.copyBeforeToAfter)))
    }

    func testKeysReachTheViewCommands() {
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character("y"), shift: true)), .view(.cycleBeforeAfter))
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character("r"), shift: true)), .view(.referenceView))
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character("y"), shift: false)), .redEye)
        XCTAssertEqual(Shortcuts.shortcut(for: .view(.toggleOverlay))?.glyphs, "⌥⌘O")
        XCTAssertEqual(Shortcuts.shortcut(for: .view(.swapBeforeAfter))?.glyphs, "⌥⇧⌘↑")
    }

    func testDevelopViewStateRemembersLayoutsAndSwitchesViews() {
        let state = DevelopViewState(defaults: defaults)
        XCTAssertEqual(state.kind, .single)
        state.perform(.cycleBeforeAfter, load: { _ in })
        XCTAssertEqual(state.kind, .beforeAfter)
        XCTAssertEqual(state.beforeAfterLayout, .leftRight)
        state.perform(.beforeAfter(.topBottomSplit), load: { _ in })
        XCTAssertEqual(state.beforeAfterLayout, .topBottomSplit)
        state.perform(.cycleBeforeAfter, load: { _ in })
        XCTAssertEqual(state.kind, .single)
        state.perform(.referenceLayout(.topBottom), load: { _ in })
        XCTAssertEqual(state.kind, .reference)
        state.perform(.referenceView, load: { _ in })
        XCTAssertEqual(state.kind, .single)
        state.perform(.lockReference, load: { _ in })
        let again = DevelopViewState(defaults: defaults)
        XCTAssertEqual(again.beforeAfterLayout, .topBottomSplit)
        XCTAssertEqual(again.referenceLayout, .topBottom)
        XCTAssertTrue(again.referenceLocked)
        XCTAssertNil(again.linkedPane(for: .develop))
    }

    // MARK: Before / After settings, on a real image

    private func openModel() async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: try TestAssets.d750URL(), catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testCopyAndSwapBeforeAndAfterSettings() async throws {
        let model = try await openModel()
        XCTAssertEqual(model.beforeParameters, model.defaultParameters)
        XCTAssertFalse(model.hasCustomBefore)

        model.parameters.exposureEV = 1
        model.copyAfterToBefore()
        XCTAssertTrue(model.hasCustomBefore)
        XCTAssertEqual(model.beforeParameters.exposureEV, 1)
        model.showingBefore = true
        XCTAssertEqual(model.renderParameters.exposureEV, 1, "\\ shows the Before that was set")
        model.showingBefore = false

        model.parameters.exposureEV = -0.5
        model.swapBeforeAndAfter()
        XCTAssertEqual(model.parameters.exposureEV, 1)
        XCTAssertEqual(model.beforeParameters.exposureEV, -0.5)

        model.copyBeforeToAfter()
        XCTAssertEqual(model.parameters.exposureEV, -0.5)
        model.undo()
        XCTAssertEqual(model.parameters.exposureEV, 1, "Copy Before to After is one undoable step")

        model.resetBefore()
        XCTAssertEqual(model.beforeParameters, model.defaultParameters)
    }

    func testBeforePaneKeepsTheAftersCrop() async throws {
        let model = try await openModel()
        let state = DevelopViewState(defaults: defaults)
        state.attach(main: model, library: Library())
        var crop = model.parameters.crop
        crop.size = SIMD2<Float>(0.5, 0.5)
        model.parameters.crop = crop
        model.parameters.exposureEV = 2
        let before = try XCTUnwrap(state.composedBefore())
        XCTAssertEqual(before.crop, crop)
        XCTAssertEqual(before.exposureEV, model.defaultParameters.exposureEV)
    }
}
