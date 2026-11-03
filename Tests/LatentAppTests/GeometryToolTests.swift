import XCTest
import simd
import PixelEngine
@testable import latent_app

/// The geometry tools in the editor: flips, Constrain Crop, Upright and
/// its guides, the straighten ruler and Auto, and the crop panel's
/// aspect and overlay choices.
@MainActor
final class GeometryToolTests: XCTestCase {
    private func openModel(editStackJSON: String? = nil) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    /// Waits for an analysis started by Upright or Auto straighten.
    private func waitForAnalysis(_ model: EditorModel) async throws {
        for _ in 0..<400 where model.geometry.analysing {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.geometry.analysing, "the analysis finished")
    }

    // MARK: - Flip

    /// A flip mirrors the crop and the masks with the picture, and Undo
    /// takes all of it back in one step.
    func testFlipMirrorsCropAndMasksAndUndoes() async throws {
        let model = try await openModel()
        model.parameters.crop = CropParameters(centre: [0.35, 0.5], size: [0.5, 0.5], angle: 3)
        var local = LocalAdjustment(name: "Gradient", shape: .linear(start: [0.2, 0.2], end: [0.4, 0.6]))
        local.exposureEV = 0.5
        model.parameters.locals = [local]
        model.parameters.perspective.horizontal = 0.3
        model.flushPendingSave()
        let before = model.parameters

        model.flip(horizontal: true)
        XCTAssertTrue(model.parameters.perspective.flipHorizontal)
        XCTAssertEqual(model.parameters.perspective.horizontal, -0.3, "keystone keeps acting on what is seen")
        XCTAssertEqual(model.parameters.crop.centre.x, 0.65, accuracy: 1e-6)
        XCTAssertEqual(model.parameters.crop.angle, -3)
        XCTAssertEqual(model.parameters.locals.first?.shape,
                       .linear(start: [1 - Float(0.2), 0.2], end: [1 - Float(0.4), 0.6]))

        model.undo()
        XCTAssertEqual(model.parameters, before, "one undo takes the whole flip back")
    }

    // MARK: - Constrain Crop

    func testConstrainCropKeepsTheCropOnThePicture() async throws {
        let model = try await openModel()
        model.setConstrainCrop(true)
        model.setTransform { $0.vertical = 0.6; $0.rotate = 5 }
        let p = model.parameters
        XCTAssertLessThan(p.crop.size.x, 1, "the crop shrank")
        let session = try XCTUnwrap(model.session), pipeline = try XCTUnwrap(model.pipeline)
        let s = model.sensorSize
        let frame = CropFrame(sensorSize: s, crop: p.crop)
        let canvas = frame.canvasSize
        for (x, y) in [(2.0, 2.0), (canvas.width - 2, 2.0), (2.0, canvas.height - 2), (canvas.width - 2, canvas.height - 2)] {
            let out = frame.sensorPoint(fromCanvasPoint: CGPoint(x: x, y: y))
            let raw = pipeline.rawSensorPoint(forOutputPoint: SIMD2(Float(out.x), Float(out.y)), session: session, parameters: p)
            XCTAssertTrue(raw.x >= -1 && raw.y >= -1 && raw.x <= Float(s.width) + 1 && raw.y <= Float(s.height) + 1,
                          "corner (\(x), \(y)) shows picture")
        }
        // Easing the transform lets the crop grow back.
        model.setTransform { $0.vertical = 0; $0.rotate = 0 }
        XCTAssertEqual(model.parameters.crop.size.x, 1, accuracy: 0.01)
        model.resetTransform()
        XCTAssertTrue(model.parameters.perspective.constrainCrop, "Reset leaves the preference")
    }

    // MARK: - Upright

    /// Each automatic mode stores its choice; the picture's lines are read
    /// once and kept for the next mode.
    func testUprightModesAreStoredAndLinesAreKept() async throws {
        let model = try await openModel()
        model.setUpright(.level)
        try await waitForAnalysis(model)
        XCTAssertEqual(model.uprightMode, .level)
        XCTAssertNotNil(model.geometry.lines)
        model.setUpright(.vertical)
        XCTAssertFalse(model.geometry.analysing, "the kept lines answer at once")
        XCTAssertEqual(model.uprightMode, .vertical)
        model.setUpright(nil)
        XCTAssertNil(model.parameters.perspective.upright)
    }

    /// Two guides drawn along converging verticals come out plumb on the
    /// canvas once Guided Upright has corrected the picture.
    func testGuidedUprightMakesGuidesPlumb() async throws {
        let model = try await openModel()
        model.setUpright(.guided)
        XCTAssertTrue(model.geometry.guidedToolActive)
        let size = model.imageSize
        model.addGuide(fromCanvas: CGPoint(x: size.width * 0.2, y: size.height * 0.9),
                       to: CGPoint(x: size.width * 0.26, y: size.height * 0.1))
        model.addGuide(fromCanvas: CGPoint(x: size.width * 0.8, y: size.height * 0.9),
                       to: CGPoint(x: size.width * 0.74, y: size.height * 0.1))
        XCTAssertEqual(model.parameters.perspective.upright?.guides?.count, 2)
        XCTAssertNotNil(model.parameters.perspective.upright?.matrix)
        for (a, b) in model.guideCanvasLines {
            let angle = abs(atan2(b.y - a.y, b.x - a.x) * 180 / .pi)
            XCTAssertEqual(angle, 90, accuracy: 0.2, "guide is plumb now")
        }
        // Survives a save and a reload in this build.
        let json = try EditStack(parameters: model.parameters).encodeJSON()
        let reopened = try await openModel(editStackJSON: json)
        XCTAssertEqual(reopened.parameters.perspective, model.parameters.perspective)
        model.removeGuide(0)
        XCTAssertEqual(model.parameters.perspective.upright?.guides?.count, 1)
        model.clearGuides()
        XCTAssertNil(model.parameters.perspective.upright?.guides)
        XCTAssertNil(model.parameters.perspective.upright?.matrix)
        model.disarmTools()
        XCTAssertFalse(model.geometry.guidedToolActive)
    }

    // MARK: - Straighten

    func testRulerStraightensByTheDrawnLine() async throws {
        let model = try await openModel()
        model.cropToolActive = true
        model.geometry.straightenLineArmed = true
        // A line rising 3° to the right on the canvas.
        let a = CGPoint(x: 100, y: 500), r = 3 * CGFloat.pi / 180
        model.straighten(alongCanvasLineFrom: a, to: CGPoint(x: a.x + 1000 * cos(r), y: a.y - 1000 * sin(r)))
        XCTAssertEqual(model.parameters.crop.angle, 3, accuracy: 0.01)
        XCTAssertFalse(model.geometry.straightenLineArmed, "the ruler is used once")
        // A second line along the new level asks for the same angle.
        let frame = model.frame
        let p = frame.canvasPoint(fromSensorPoint: CGPoint(x: 1000, y: 1500))
        let q = frame.canvasPoint(fromSensorPoint: CGPoint(x: 3000, y: 1500 - 2000 * tan(r)))
        model.straighten(alongCanvasLineFrom: p, to: q)
        XCTAssertEqual(model.parameters.crop.angle, 3, accuracy: 0.01)
    }

    func testAutoStraightenRunsOnTheRealPicture() async throws {
        let model = try await openModel()
        model.autoStraighten()
        try await waitForAnalysis(model)
        XCTAssertLessThanOrEqual(abs(model.parameters.crop.angle), 15, "a level within the tool's reach, or none")
    }

    // MARK: - Panel choices

    func testCustomAspectAndNewRatios() {
        XCTAssertEqual(CropAspectOption.matching(5 / 7, original: 1.5), .r5x7)
        XCTAssertEqual(CropAspectOption.matching(7 / 5, original: 1.5), .r7x5)
        XCTAssertEqual(CropAspectOption.matching(1.85, original: 1.5), .custom)
        XCTAssertEqual(CropAspectOption.matching(nil, original: 1.5), .free)
        XCTAssertEqual(CropAspectOption.customRatio(width: 1.85, height: 1), 1.85)
        XCTAssertNil(CropAspectOption.customRatio(width: 0, height: 4))
        XCTAssertNil(CropAspectOption.customRatio(width: 100, height: 1))
        XCTAssertEqual(CropAspectOption.describe(1.85), "1.85:1")
        XCTAssertEqual(CropAspectOption.describe(0.5), "1:2")
        XCTAssertEqual(CropAspectOption.custom.menuTitle(current: 1.85, original: 1.5), "Custom (1.85:1)")
        XCTAssertEqual(CropAspectOption.custom.menuTitle(current: 1.5, original: 1.5), "Custom…")
    }

    func testCropGuidesCycleAndDraw() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: CropToolPreferences.guideKey),
                     defaults.object(forKey: CropToolPreferences.orientationKey))
        defer {
            defaults.set(saved.0, forKey: CropToolPreferences.guideKey)
            defaults.set(saved.1, forKey: CropToolPreferences.orientationKey)
        }
        CropToolPreferences.guide = .thirds
        var seen: [CropGuide] = []
        for _ in CropGuide.allCases {
            seen.append(CropToolPreferences.guide)
            CropToolPreferences.cycleGuide()
        }
        XCTAssertEqual(seen, CropGuide.allCases, "O visits every overlay")
        XCTAssertEqual(CropToolPreferences.guide, .thirds, "and comes back round")

        CropToolPreferences.guide = .goldenSpiral
        CropToolPreferences.rotateGuide()
        XCTAssertEqual(defaults.integer(forKey: CropToolPreferences.orientationKey), 1)

        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        for guide in CropGuide.allCases where guide != .none {
            for o in 0..<guide.orientations {
                let bounds = guide.path(in: rect, orientation: o).boundingRect
                XCTAssertFalse(bounds.isEmpty, "\(guide) draws")
                XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "\(guide) \(o) stays in the crop")
            }
        }
        XCTAssertTrue(CropGuide.none.path(in: rect, orientation: 0).isEmpty)
    }

    /// The new commands are wired to the menus and take free keys only.
    func testGeometryCommandsAreEnabledOnlyWhereTheyAct() {
        var state = CommandState()
        state.mode = .develop
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(.geometry(.flipHorizontal)))
        XCTAssertFalse(state.isEnabled(.geometry(.cycleCropGuide)), "O cycles only while cropping")
        state.cropToolActive = true
        XCTAssertTrue(state.isEnabled(.geometry(.cycleCropGuide)))
        state.mode = .library
        XCTAssertFalse(state.isEnabled(.geometry(.upright(.auto))))
        XCTAssertEqual(Shortcuts.shortcut(for: .geometry(.cycleCropGuide))?.glyphs, "O")
        XCTAssertEqual(Shortcuts.shortcut(for: .geometry(.rotateCropGuide))?.glyphs, "⇧O")
    }
}
