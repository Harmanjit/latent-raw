import XCTest
import CoreGraphics
@testable import MLKit
@testable import PixelEngine
@testable import RawCore

/// Select Objects: a box prompt (SAM's corner labels 2 and 3) selects what
/// is inside it, as a click does.
extension AIMaskTests {
    func testPromptLabelsForClicksAndBoxCorners() {
        XCTAssertEqual(PromptPoint(x: 0, y: 0, foreground: true).label, 1)
        XCTAssertEqual(PromptPoint(x: 0, y: 0, foreground: false).label, 0)
        XCTAssertEqual(PromptPoint(MaskPromptPoint(x: 0.1, y: 0.2, corner: 1)).label, 2)
        XCTAssertEqual(PromptPoint(MaskPromptPoint(x: 0.3, y: 0.4, corner: 2)).label, 3)
        let stored = PromptPoint(MaskPromptPoint(x: 0.3, y: 0.4, foreground: false))
        XCTAssertEqual(stored.x, 0.3); XCTAssertEqual(stored.y, 0.4); XCTAssertFalse(stored.foreground)
    }

    func testSAM2BoxSelectsTheSquirrel() async throws {
        try XCTSkipUnless(SAM2Models.isAvailable, "SAM2 packages not bundled")
        let models = try await SAM2Models.load()
        let image = try smallImage("HSB_2639.NEF")
        let session = try SAM2Session(models: models, image: image)
        // A box around the squirrel, which spans about x 0.41-0.51, y 0.52-0.63.
        let box = [PromptPoint(MaskPromptPoint(x: 0.39, y: 0.49, corner: 1)),
                   PromptPoint(MaskPromptPoint(x: 0.54, y: 0.66, corner: 2))]
        let m = try session.predict(points: box).mask
        // The same squirrel a click finds: the two masks mostly agree.
        let click = try session.predict(points: [PromptPoint(x: 0.48, y: 0.55, foreground: true)]).mask
        var both = 0, either = 0
        for i in m.data.indices {
            let a = m.data[i] > 127, b = click.data[i] > 127
            if a && b { both += 1 }
            if a || b { either += 1 }
        }
        let overlap = Double(both) / Double(max(either, 1))
        print(String(format: "SAM2 box: coverage %.1f%%, overlap with the click's mask %.2f", m.coverage * 100, overlap))
        XCTAssertGreaterThan(overlap, 0.5, "the box finds the squirrel the click does")
        XCTAssertLessThan(coverage(m, x: 0...0.25, y: 0...1), 0.02, "outside the box is not")
        XCTAssertLessThan(coverage(m, x: 0.75...1, y: 0...1), 0.02)
    }

    /// Export makes the pixels of a component's model mask as it does a
    /// local's own, under the component's id.
    func testExportRegeneratesComponentModelMasks() async throws {
        let path = Self.assetPath("HSB_2639.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        var local = LocalAdjustment(name: "Brush", shape: .brush(strokes: []))
        let component = MaskComponent(mode: .add, source: .shape(.ai(kind: "subject", modelVersion: "vision.foregroundInstance@1")))
        local.components = [component]
        let made = try await ExportWorker.regenerateMasks([local], session: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu)
        XCTAssertEqual(made.count, 1)
        XCTAssertTrue(session.hasAIMask(forLocal: component.id))
        XCTAssertFalse(session.hasAIMask(forLocal: local.id))
    }
}
