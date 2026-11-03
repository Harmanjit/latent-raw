import XCTest
import simd
import PixelEngine
import MLKit
@testable import latent_app

/// Content-aware Remove in the editor: placing patches, switching modes,
/// the size limit, Undo and Detect Objects.
@MainActor
final class RemoveToolTests: XCTestCase {
    private func openModel(_ url: URL) async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testRemoveClickPlacesAPatchWithNoSourceAndModesSwitch() async throws {
        let model = try await openModel(try TestAssets.d750URL())
        model.removeDetectsObjects = false
        model.healToolActive = true
        model.healMode = .remove
        model.imageToolBegan(at: CGPoint(x: 600, y: 400), exclude: false)
        model.imageToolMoved(to: CGPoint(x: 620, y: 400))
        model.imageToolEnded()
        let patch = try XCTUnwrap(model.parameters.heals.first)
        XCTAssertEqual(patch.mode, .remove)
        XCTAssertEqual(patch.source, patch.target, "no source")
        XCTAssertEqual(model.selectedHealIndex, 0)
        XCTAssertGreaterThan(model.outputNormalized(patch.target).x * Float(model.sensorSize.width), 0)

        // A drag on it moves the patch; there is no source to grab.
        let before = patch.target
        let screen = model.viewport.screenPoint(
            forSensorPoint: model.frame.canvasPoint(fromSensorPoint: CGPoint(
                x: CGFloat(model.outputNormalized(before).x) * model.sensorSize.width,
                y: CGFloat(model.outputNormalized(before).y) * model.sensorSize.height)),
            drawableSize: model.drawableSize)
        model.imageToolBegan(at: screen, exclude: false)
        model.imageToolMoved(to: CGPoint(x: screen.x, y: screen.y + 30))
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, 1)
        XCTAssertGreaterThan(model.parameters.heals[0].target.y, before.y)
        XCTAssertEqual(model.parameters.heals[0].source, model.parameters.heals[0].target)

        // Switching the patch to Heal gives it a source beside it; back to
        // Remove drops it again.
        model.activeHealMode = .heal
        let healed = model.parameters.heals[0]
        XCTAssertEqual(healed.mode, .heal)
        XCTAssertGreaterThan(simd_length(healed.source - healed.target), healed.radius)
        model.activeHealMode = .remove
        XCTAssertEqual(model.parameters.heals[0].source, model.parameters.heals[0].target)
    }

    func testRemoveBrushMakesAStrokeAndTooLargeIsRefused() async throws {
        let model = try await openModel(try TestAssets.d750URL())
        model.removeDetectsObjects = false
        model.healToolActive = true
        model.healMode = .remove
        model.healShape = .brush
        model.healRadius = 0.005
        model.imageToolBegan(at: CGPoint(x: 500, y: 400), exclude: false)
        for x in stride(from: 510, through: 600, by: 10) { model.imageToolMoved(to: CGPoint(x: CGFloat(x), y: 400)) }
        model.imageToolEnded()
        let stroke = try XCTUnwrap(model.parameters.heals.first)
        XCTAssertTrue(stroke.isStroke)
        XCTAssertEqual(stroke.mode, .remove)
        XCTAssertEqual(stroke.source, stroke.target)

        // A stroke across most of the view is more than Remove takes.
        model.imageToolBegan(at: CGPoint(x: 100, y: 300), exclude: false)
        for x in stride(from: 110, through: 1100, by: 10) { model.imageToolMoved(to: CGPoint(x: CGFloat(x), y: 300)) }
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, 1)
        XCTAssertTrue(model.status.contains("Remove covers at most"))
    }

    /// Detect Objects on the squirrel: a rough stroke across it ends as an
    /// outline round the squirrel, and Use Brush takes it off again.
    func testDetectObjectsFindsTheSquirrel() async throws {
        let path = TestAssets.path("HSB_2639.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "squirrel raw not in TestAssets")
        try XCTSkipUnless(SAM2Models.isAvailable, "SAM2 packages not bundled")
        let model = try await openModel(URL(fileURLWithPath: path))
        // The squirrel sits at roughly (0.48, 0.55) of the unrotated frame.
        var patch = HealPatch(target: [0.47, 0.55], source: [0.47, 0.55], radius: 0.01, mode: .remove,
                              stroke: [.zero, [0.02, 0.0]])
        patch.id = UUID()
        model.parameters.heals = [patch]
        model.selectedHealIndex = 0
        model.detectObjectForSelectedPatch()
        XCTAssertTrue(model.detectingObjectIDs.contains(patch.id))
        for _ in 0..<600 where !model.detectingObjectIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let outline = try XCTUnwrap(model.parameters.heals[0].objectMask, model.status)
        let box = model.parameters.heals[0].targetBounds(sensorSize: model.sensorSize)
        let short = min(model.sensorSize.width, model.sensorSize.height)
        print("detect objects: \(model.status), box \(box), coverage \(outline.coverage)")
        XCTAssertTrue(box.contains(CGPoint(x: 0.48 * model.sensorSize.width, y: 0.55 * model.sensorSize.height)))
        XCTAssertLessThan(max(box.width, box.height), 0.35 * short, "the squirrel, not the scene")
        XCTAssertTrue((0.1...0.95).contains(outline.coverage))

        model.useBrushForSelectedPatch()
        XCTAssertNil(model.parameters.heals[0].objectMask)
    }
}
