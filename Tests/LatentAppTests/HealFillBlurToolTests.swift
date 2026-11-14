import XCTest
import simd
import PixelEngine
@testable import latent_app

/// The Remove tool's Fill and Blur modes in the editor: a click places a
/// patch with no source, carrying the mode's settings; the panel's
/// controls edit the selected patch; switching back to Heal clears them.
@MainActor
final class HealFillBlurToolTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: try TestAssets.d750URL(), catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    func testFillAndBlurPatchesHaveNoSourceAndCarryTheirSettings() async throws {
        let model = try await openModel()
        model.healToolActive = true
        model.healMode = .fill
        model.imageToolBegan(at: CGPoint(x: 600, y: 400), exclude: false)
        model.imageToolEnded()
        let fill = try XCTUnwrap(model.parameters.heals.first)
        XCTAssertEqual(fill.mode, .fill)
        XCTAssertEqual(fill.source, fill.target)
        XCTAssertNotNil(fill.fillColour)
        XCTAssertNil(fill.blurRadius)

        model.activeFillBrightness = 1.5
        XCTAssertEqual(model.parameters.heals[0].fillBrightness, 1.5)
        model.activeFillColour = SIMD3(0.5, 0.25, 0.1)
        XCTAssertEqual(model.parameters.heals[0].fillColour, SIMD3(0.5, 0.25, 0.1))

        // To Blur: Fill's settings go, Blur's come; to Heal, none stay and
        // a source is placed beside it.
        model.activeHealMode = .blur
        XCTAssertNil(model.parameters.heals[0].fillColour)
        XCTAssertNotNil(model.parameters.heals[0].blurRadius)
        XCTAssertEqual(model.parameters.heals[0].source, model.parameters.heals[0].target)
        model.activeHealMode = .heal
        let heal = model.parameters.heals[0]
        XCTAssertNil(heal.blurRadius)
        XCTAssertNil(heal.fillColour)
        XCTAssertNotEqual(heal.source, heal.target)
    }
}
