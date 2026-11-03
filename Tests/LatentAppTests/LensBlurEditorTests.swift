import XCTest
import CoreGraphics
import simd
import PixelEngine
import MLKit
@testable import latent_app

/// Lens Blur in the editor (EditorModel+LensBlur.swift): when the depth
/// map is made and made again, the amount as one undoable step that
/// records the depth source, Pick Focus, Show Depth, and an edit with a
/// blur stored and opened again. The models are stood in for by a drawn
/// depth map through `EditorModel.depthBuilder`, so the D750 raw is only a
/// photo to open.
@MainActor
final class LensBlurEditorTests: XCTestCase {
    /// The stand-in builder, counting its runs: near on the left half,
    /// far on the right.
    final class FakeBuilder: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs = 0
        var runs: Int { lock.withLock { _runs } }

        static let map: DepthMap = {
            let w = 32, h = 16
            var data = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { data[y * w + x] = x < w / 2 ? 230 : 25 } }
            return DepthMap(bitmap: MaskBitmap(width: w, height: h, data: data), source: LensBlur.subjectDepthVersion)
        }()

        var builder: EditorModel.DepthBuilder {
            { [self] _, _, _ in
                lock.withLock { _runs += 1 }
                return .success(LensBlurDepth.Result(depth: Self.map, substitutedModel: nil, seconds: 0))
            }
        }
    }

    override func tearDown() async throws {
        EditorModel.depthBuilder = EditorModel.liveDepthBuilder
    }

    private func openModel(editStackJSON: String? = nil, saved: ((String?) -> Void)? = nil) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, json in saved?(json) }
        model.open(url: url, catalogImageID: 1, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    private func screen(_ n: SIMD2<Float>, in model: EditorModel) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        return model.viewport.screenPoint(forSensorPoint: model.frame.canvasPoint(fromSensorPoint: sensor),
                                          drawableSize: model.drawableSize)
    }

    // MARK: - Amount

    /// The first move of Amount makes the depth map once, records where
    /// the depth comes from, blurs the preview, and is one undoable step.
    func testAmountBuildsTheDepthOnceAndUndoes() async throws {
        let fake = FakeBuilder()
        EditorModel.depthBuilder = fake.builder
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        XCTAssertFalse(session.hasDepthMap, "nothing is made for an edit without a blur")
        XCTAssertEqual(fake.runs, 0)
        let steps = model.history.steps.count

        model.setLensBlurAmount(80)
        XCTAssertTrue(model.lensBlurState.building)
        await waitUntil("the depth map", seconds: 20) { !model.lensBlurState.building }
        XCTAssertEqual(fake.runs, 1)
        XCTAssertTrue(session.hasDepthMap)
        XCTAssertEqual(model.parameters.lensBlur.amount, 80)
        XCTAssertEqual(model.parameters.lensBlur.depthModel, LensBlurDepth.defaultSource())
        XCTAssertEqual(model.lensBlurState.source, LensBlur.subjectDepthVersion)
        XCTAssertFalse(model.lensBlurState.histogram.isEmpty)

        // More slider moves don't make the map again.
        model.setLensBlurAmount(60)
        model.parameters.lensBlur.boost = 30
        XCTAssertEqual(fake.runs, 1)

        model.flushPendingSave()
        XCTAssertEqual(model.history.steps.count, steps + 1)
        XCTAssertEqual(model.history.steps.last?.label, "Lens Blur")
        model.undo()
        XCTAssertEqual(model.parameters.lensBlur, .neutral)
        model.redo()
        XCTAssertEqual(model.parameters.lensBlur.amount, 60)
        XCTAssertEqual(model.parameters.lensBlur.boost, 30)
    }

    // MARK: - Stored and opened again

    /// The saved edit carries the blur, and opening it makes the depth
    /// map at once.
    func testStoredBlurRoundTripsAndOpensWithItsDepth() async throws {
        let fake = FakeBuilder()
        EditorModel.depthBuilder = fake.builder
        var saved: String?
        let model = try await openModel(saved: { saved = $0 })
        model.setLensBlurAmount(70)
        model.parameters.lensBlur.bokeh = .blades5
        model.flushPendingSave()
        let json = try XCTUnwrap(saved)
        let stored = try EditStack.decode(json: json).parameters().lensBlur
        XCTAssertEqual(stored.amount, 70)
        XCTAssertEqual(stored.bokeh, .blades5)

        let reopened = try await openModel(editStackJSON: json)
        await waitUntil("the depth map on open", seconds: 20) { reopened.session?.hasDepthMap == true }
        XCTAssertEqual(reopened.parameters.lensBlur, stored)
    }

    // MARK: - Pick Focus and Show Depth

    /// Pick Focus: the next click centres the focus range on the depth
    /// under the pointer, then the picker is off.
    func testPickFocusSetsTheRangeFromTheClick() async throws {
        let fake = FakeBuilder()
        EditorModel.depthBuilder = fake.builder
        let model = try await openModel()
        model.setLensBlurAmount(100)
        await waitUntil("the depth map", seconds: 20) { !model.lensBlurState.building }

        model.setPickingFocus(true)
        XCTAssertTrue(model.imageToolActive)
        model.imageToolBegan(at: screen(SIMD2(0.8, 0.5), in: model), exclude: false)
        XCTAssertFalse(model.lensBlurState.pickingFocus)
        let far = Float(25) / 255
        XCTAssertEqual(model.parameters.lensBlur.focusFar, max(0, far - 0.08), accuracy: 0.02)
        XCTAssertLessThan(model.parameters.lensBlur.focusNear, 0.3)

        // Another armed tool takes the click instead.
        model.setPickingFocus(true)
        model.disarmTools()
        XCTAssertFalse(model.lensBlurState.pickingFocus)
    }

    /// Show Depth makes the map even with the blur off, and rides on the
    /// display output only.
    func testShowDepthMakesTheMapAndIsDisplayOnly() async throws {
        let fake = FakeBuilder()
        EditorModel.depthBuilder = fake.builder
        let model = try await openModel()
        model.setShowDepth(true)
        await waitUntil("the depth map", seconds: 20) { model.session?.hasDepthMap == true }
        XCTAssertTrue(model.displayOutput.depthVisualisation)
        XCTAssertFalse(model.parameters.lensBlur.isActive)
        XCTAssertEqual(model.parameters, model.defaultParameters, "Show Depth is not an edit")
        model.setShowDepth(false)
        XCTAssertFalse(model.displayOutput.depthVisualisation)
    }

    /// A keystone change moves the grid the map is sampled on: it is made
    /// again once the change settles.
    func testGeometryChangeMakesTheMapAgain() async throws {
        let fake = FakeBuilder()
        EditorModel.depthBuilder = fake.builder
        let model = try await openModel()
        model.setLensBlurAmount(50)
        await waitUntil("the depth map", seconds: 20) { !model.lensBlurState.building }
        XCTAssertEqual(fake.runs, 1)
        model.parameters.perspective = PerspectiveCorrection(vertical: 0.2, horizontal: 0)
        await waitUntil("the second depth map", seconds: 20) { fake.runs == 2 && !model.lensBlurState.building }
        XCTAssertEqual(fake.runs, 2)
    }

    func testStatusWording() {
        XCTAssertTrue(EditorModel.depthStatus(source: LensBlur.subjectDepthVersion, standingInFor: nil)
                        .contains("Settings › AI › Models"))
        XCTAssertEqual(EditorModel.depthStatus(source: LensBlur.subjectDepthVersion, standingInFor: "Depth Anything V2 Small"),
                       "Depth from Subject (two planes), because Depth Anything V2 Small is not installed.")
    }
}
