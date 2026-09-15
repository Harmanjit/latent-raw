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
    private static func asset(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets").appendingPathComponent(name)
    }

    private func openModel() async throws -> EditorModel {
        let url = Self.asset("nikon_d750_sample.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url, catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
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
}
