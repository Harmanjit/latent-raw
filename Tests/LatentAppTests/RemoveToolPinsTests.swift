import XCTest
import simd
import PixelEngine
@testable import latent_app

/// The Remove tool's Opacity, Tool Overlay and pin management: selecting
/// several, Select All, deleting, and the Option-drag marquee.
@MainActor
final class RemoveToolPinsTests: XCTestCase {
    private func openModel() async throws -> EditorModel {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: try TestAssets.d750URL(), catalogImageID: nil)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        model.removeDetectsObjects = false
        model.healToolActive = true
        return model
    }

    private func click(_ model: EditorModel, _ p: CGPoint, option: Bool = false) {
        model.imageToolBegan(at: p, exclude: option)
        model.imageToolEnded()
    }

    func testOverlayModesChooseWhichPinsAreDrawn() {
        XCTAssertEqual(HealToolOverlay.always.visibleIndices(count: 3, selected: [1], pointerOverImage: false), [0, 1, 2])
        XCTAssertEqual(HealToolOverlay.auto.visibleIndices(count: 3, selected: [1], pointerOverImage: true), [0, 1, 2])
        XCTAssertEqual(HealToolOverlay.auto.visibleIndices(count: 3, selected: [1], pointerOverImage: false), [])
        XCTAssertEqual(HealToolOverlay.selected.visibleIndices(count: 3, selected: [2, 0, 7], pointerOverImage: true), [0, 2])
        XCTAssertEqual(HealToolOverlay.never.visibleIndices(count: 3, selected: [1], pointerOverImage: true), [])
    }

    func testOpacityStampsNewPatchesAndSetsTheSelectedOnes() async throws {
        let model = try await openModel()
        model.healMode = .clone
        click(model, CGPoint(x: 400, y: 400))
        XCTAssertNil(model.parameters.heals[0].opacity, "fully opaque stores nothing")

        model.selectedHealIndex = nil
        model.activeHealOpacity = 0.4
        click(model, CGPoint(x: 700, y: 300))
        XCTAssertEqual(model.parameters.heals[1].opacity, 0.4)
        XCTAssertNil(model.parameters.heals[0].opacity, "only the selected patch changes")

        // Brush strokes take it too.
        model.healShape = .brush
        model.imageToolBegan(at: CGPoint(x: 300, y: 600), exclude: false)
        for x in stride(from: 310, through: 420, by: 10) { model.imageToolMoved(to: CGPoint(x: CGFloat(x), y: 600)) }
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, 3)
        XCTAssertEqual(model.parameters.heals[2].opacity, 0.4)

        // Select All: Opacity sets every patch; back to 100% stores nothing.
        model.selectAllHeals()
        XCTAssertEqual(model.selectedHealIndices, [0, 1, 2])
        model.activeHealOpacity = 1
        XCTAssertTrue(model.parameters.heals.allSatisfy { $0.opacity == nil })
    }

    func testSelectingSeveralAndDeleting() async throws {
        let model = try await openModel()
        model.healMode = .clone
        for x in [300, 500, 700, 900] { click(model, CGPoint(x: x, y: 200)) }
        XCTAssertEqual(model.parameters.heals.count, 4)
        let ids = model.parameters.heals.map(\.id)

        model.selectHealPin(0, extending: false)
        model.selectHealPin(2, extending: true)
        XCTAssertEqual(model.selectedHealIndices, [0, 2])
        XCTAssertEqual(model.selectedHealIndex, 2, "the sliders edit the pin just added")
        model.selectHealPin(2, extending: true)
        XCTAssertEqual(model.selectedHealIndices, [0])
        model.selectHealPin(3, extending: true)
        model.deleteSelectedHeal()
        XCTAssertEqual(model.parameters.heals.map(\.id), [ids[1], ids[2]])
        XCTAssertTrue(model.selectedHealIndices.isEmpty)

        model.deleteHeal(at: 0)
        XCTAssertEqual(model.parameters.heals.map(\.id), [ids[2]])
        model.selectAllHeals()
        model.deleteSelectedHeal()
        XCTAssertTrue(model.parameters.heals.isEmpty)
    }

    func testOptionMarqueeAndOptionClickDelete() async throws {
        let model = try await openModel()
        model.healMode = .heal
        for x in [300, 500, 900] { click(model, CGPoint(x: x, y: 300)) }
        XCTAssertEqual(model.parameters.heals.count, 3)
        let pins = model.parameters.heals.map { model.healScreenPoint($0.target) }
        XCTAssertEqual(pins[0].x, 300, accuracy: 2)

        // A marquee around the first two pins.
        model.imageToolBegan(at: CGPoint(x: 250, y: 250), exclude: true)
        model.imageToolMoved(to: CGPoint(x: 600, y: 350))
        XCTAssertNotNil(model.healMarquee)
        model.imageToolEnded()
        XCTAssertNil(model.healMarquee)
        XCTAssertEqual(model.parameters.heals.count, 1)
        XCTAssertEqual(model.healScreenPoint(model.parameters.heals[0].target).x, 900, accuracy: 2)

        // An Option-click on the last one deletes it; on nothing, nothing.
        click(model, CGPoint(x: 100, y: 700), option: true)
        XCTAssertEqual(model.parameters.heals.count, 1)
        click(model, pins[2], option: true)
        XCTAssertTrue(model.parameters.heals.isEmpty)
    }
}
