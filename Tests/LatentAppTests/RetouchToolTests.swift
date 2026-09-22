import XCTest
import AppKit
import simd
import Catalog
import PixelEngine
@testable import latent_app

/// The red-eye tool and brush-stroke spot removal in the editor: keys,
/// menus, the tools' exclusivity and what a drag leaves in the edit.
@MainActor
final class RetouchToolTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    /// The screen point that shows a normalised OUTPUT-grid point: what
    /// the viewport draws, the lens map already applied.
    private func screenPoint(_ n: SIMD2<Float>, in model: EditorModel) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        return model.viewport.screenPoint(forSensorPoint: model.frame.canvasPoint(fromSensorPoint: sensor),
                                          drawableSize: model.drawableSize)
    }

    func testYArmsRedEyeInDevelopAndDeleteReachesItsSpot() {
        let press = BareKeyPress(charactersIgnoringModifiers: "y", shift: false, command: false, option: false, control: false)
        XCTAssertEqual(press.flatMap(KeyCommand.command(for:)), .redEye)
        var state = CommandState()
        state.mode = .develop
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(.redEye))
        state.redEyeToolActive = true
        XCTAssertFalse(state.isEnabled(.deleteHeal), "nothing selected")
        state.hasSelectedRedEye = true
        XCTAssertTrue(state.isEnabled(.deleteHeal))
        state.mode = .loupe
        XCTAssertFalse(state.isEnabled(.redEye))
        XCTAssertEqual(SpokenText.redEyeSpots(count: 2, selected: 0), "2 spots, spot 1 selected")
        XCTAssertEqual(SpokenText.redEyesFound(added: 0, detected: 0), "No red eyes found")
        XCTAssertEqual(SpokenText.redEyesFound(added: 2, detected: 2), "Fixed 2 red eyes")
    }

    /// Auto red-eye looks for faces in a small sRGB render of the edit. At
    /// the preview's bin factor that render must not land in the preview's
    /// textures: the view would show it washed out, and if no eyes are
    /// found nothing renders the preview again.
    func testRedEyeDetectionLeavesThePreviewOnScreenAlone() async throws {
        let model = try await openModel()
        let gpu = try XCTUnwrap(model.gpuContext)
        let summary = try XCTUnwrap(model.session).file.summary
        let longEdge = max(summary.rawWidth, summary.rawHeight)
        let detectionQuads = Int((Double(longEdge) / 3200).rounded(.up))
        // A view that bins the preview as far as detection does.
        let side = CGFloat(longEdge) / CGFloat(2 * detectionQuads + 1)
        model.viewportDidResize(to: CGSize(width: side, height: side))
        model.rerenderForViewport()
        XCTAssertEqual(model.previewQuads, detectionQuads, "the case where the pools would collide")
        let preview = try XCTUnwrap(model.preview)
        func pixels() throws -> Data? {
            try Exporter(gpu: gpu).cgImage(from: preview.texture, colorSpace: .displayP3).dataProvider?.data as Data?
        }
        let shown = try XCTUnwrap(try pixels())

        model.autoDetectRedEyes()
        XCTAssertTrue(model.preview?.texture === preview.texture)
        XCTAssertEqual(try pixels(), shown)
        for _ in 0..<100 where model.detectingRedEyes {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testOnlyOneOnImageToolAtATime() async throws {
        let model = try await openModel()
        model.healToolActive = true
        model.redEyeToolActive = true
        XCTAssertFalse(model.healToolActive)
        XCTAssertTrue(model.imageToolActive)
        model.healToolActive = true
        XCTAssertFalse(model.redEyeToolActive)
        model.redEyeToolActive = true
        model.cropToolActive = true
        XCTAssertFalse(model.redEyeToolActive)
        model.redEyeToolActive = true
        model.disarmTools()
        XCTAssertFalse(model.redEyeToolActive || model.healToolActive || model.cropToolActive)
    }

    func testClickingAddsASpotThatTheNextClickMovesAndKeysResize() async throws {
        let model = try await openModel()
        model.redEyeToolActive = true
        let centre = CGPoint(x: 600, y: 400)
        model.imageToolBegan(at: centre, exclude: false)
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.redEyes.count, 1)
        XCTAssertEqual(model.selectedRedEyeIndex, 0)
        let before = model.parameters.redEyes[0]

        // Inside the spot: moves it rather than adding another.
        model.imageToolBegan(at: centre, exclude: false)
        model.imageToolMoved(to: CGPoint(x: 610, y: 400))
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.redEyes.count, 1)
        XCTAssertGreaterThan(model.parameters.redEyes[0].centre.x, before.centre.x)

        XCTAssertTrue(model.toolSizeAdjustable)
        model.stepToolSize(by: 1)
        XCTAssertGreaterThan(model.parameters.redEyes[0].radius, before.radius)

        model.activeRedEyeStrength = 0.5
        XCTAssertEqual(model.parameters.redEyes[0].strength, 0.5)
        model.deleteSelectedRedEye()
        XCTAssertTrue(model.parameters.redEyes.isEmpty)
        XCTAssertNil(model.selectedRedEyeIndex)
    }

    func testBrushDragBecomesOneStrokePatchWithItsSourceBeside() async throws {
        let model = try await openModel()
        model.healToolActive = true
        model.healShape = .brush
        model.healRadius = 0.005
        model.imageToolBegan(at: CGPoint(x: 300, y: 400), exclude: false)
        XCTAssertTrue(model.parameters.heals.isEmpty, "nothing is rendered while painting")
        for x in stride(from: 310, through: 900, by: 10) {
            model.imageToolMoved(to: CGPoint(x: CGFloat(x), y: 400 + CGFloat(x % 30)))
        }
        XCTAssertGreaterThan(model.paintingHealStroke.count, 10)
        model.imageToolEnded()
        XCTAssertTrue(model.paintingHealStroke.isEmpty)
        let patch = try XCTUnwrap(model.parameters.heals.first)
        XCTAssertTrue(patch.isStroke)
        XCTAssertLessThanOrEqual(patch.stroke?.count ?? 0, HealPatch.maximumStrokePoints)
        XCTAssertFalse(patch.sourceBounds(sensorSize: model.sensorSize).intersects(patch.targetBounds(sensorSize: model.sensorSize)),
                       "the source clears the stroke")
        XCTAssertEqual(model.selectedHealIndex, 0)

        // Grabbing the stroke's source moves only the source.
        let target = patch.target
        let sourceScreen = model.viewport.screenPoint(
            forSensorPoint: model.frame.canvasPoint(fromSensorPoint: CGPoint(x: CGFloat(patch.source.x) * model.sensorSize.width,
                                                                             y: CGFloat(patch.source.y) * model.sensorSize.height)),
            drawableSize: model.drawableSize)
        model.imageToolBegan(at: sourceScreen, exclude: false)
        model.imageToolMoved(to: CGPoint(x: sourceScreen.x, y: sourceScreen.y + 40))
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, 1)
        XCTAssertEqual(model.parameters.heals[0].target, target)
        XCTAssertGreaterThan(model.parameters.heals[0].source.y, patch.source.y)

        // A click with Brush is an ordinary circle.
        model.imageToolBegan(at: CGPoint(x: 200, y: 200), exclude: false)
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, 2)
        XCTAssertFalse(model.parameters.heals[1].isStroke)
    }

    /// With a lens correction on, the viewport shows the corrected image
    /// while a patch and a red-eye spot are applied before the lens stage,
    /// on the raw grid. A click must go through the lens map to the pixel
    /// under the cursor, and the ring the overlay draws (the map run the
    /// other way) must take the next click — the same contract the dust
    /// and touch-up tools keep.
    func testHealAndRedEyeClicksGoThroughTheLensMapToTheRawGrid() async throws {
        let model = try await openModel()
        model.parameters.manualDistortion = 0.3
        let size = SIMD2(Float(model.sensorSize.width), Float(model.sensorSize.height))
        let raw = SIMD2<Float>(0.3, 0.4)
        let out = model.outputNormalized(raw)
        XCTAssertGreaterThan(simd_length((out - raw) * size), 1, "the distortion moves the point")
        XCTAssertEqual(simd_length((model.rawNormalized(out) - raw) * size), 0, accuracy: 0.05,
                       "the two maps are each other's inverse")

        // A spot patch lands on the raw pixel under the cursor.
        model.healToolActive = true
        model.healShape = .spot
        model.healRadius = 0.01
        model.imageToolBegan(at: screenPoint(out, in: model), exclude: false)
        model.imageToolEnded()
        let patch = try XCTUnwrap(model.parameters.heals.first)
        XCTAssertEqual(simd_length((patch.target - raw) * size), 0, accuracy: 0.5, "the raw pixel under the cursor")

        // Clicking where the overlay draws that patch grabs it, rather
        // than adding a second one beside it.
        model.selectedHealIndex = nil
        model.imageToolBegan(at: screenPoint(model.outputNormalized(patch.target), in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, 1, "the ring took the click")
        XCTAssertEqual(model.selectedHealIndex, 0)
        XCTAssertEqual(model.parameters.heals[0].target, patch.target, "grabbing it moved nothing")

        // The same for a red-eye spot.
        model.healToolActive = false
        model.redEyeToolActive = true
        let rawEye = SIMD2<Float>(0.7, 0.35)
        let outEye = model.outputNormalized(rawEye)
        XCTAssertGreaterThan(simd_length((outEye - rawEye) * size), 1)
        model.imageToolBegan(at: screenPoint(outEye, in: model), exclude: false)
        model.imageToolEnded()
        let spot = try XCTUnwrap(model.parameters.redEyes.first)
        XCTAssertEqual(simd_length((spot.centre - rawEye) * size), 0, accuracy: 0.5)

        model.selectedRedEyeIndex = nil
        model.imageToolBegan(at: screenPoint(model.outputNormalized(spot.centre), in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.redEyes.count, 1, "the circle took the click")
        XCTAssertEqual(model.selectedRedEyeIndex, 0)

        // The profile alone moves the point: this raw carries a lens
        // profile, so the two grids differ even with the manual slider at
        // zero, which is why the bug showed on ordinary photographs.
        model.parameters.manualDistortion = 0
        XCTAssertGreaterThan(simd_length((model.outputNormalized(raw) - raw) * size), 0.25,
                             "the D750 profile's own distortion")

        // With every lens correction off the two maps are the identity,
        // so an edit without one behaves exactly as it did before.
        model.parameters.lensDistortion = false
        model.parameters.lensTCA = false
        model.parameters.lensVignetting = false
        XCTAssertEqual(model.outputNormalized(raw), raw)
        XCTAssertEqual(model.rawNormalized(raw), raw)
    }

}
