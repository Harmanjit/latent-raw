import XCTest
import AppKit
import simd
import PixelEngine
@testable import latent_app

/// Reordering masks and components, and linked mask components, from the
/// editor's side (EditorModel+MaskComponents.swift, MaskReorder.swift).
@MainActor
final class MaskOrderAndLinkTests: XCTestCase {
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

    func testMasksReorderAndUndo() async throws {
        let model = try await openModel()
        model.addLocal(.radial)
        model.addLocal(.linear)
        model.addLocal(.brush)
        let ids = model.parameters.locals.map(\.id)
        model.selectedLocalIndex = 0
        model.flushPendingSave()

        model.moveLocal(from: 0, to: 2)
        XCTAssertEqual(model.parameters.locals.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(model.selectedLocalIndex, 2, "the selection follows its mask")
        model.moveLocal(from: 0, to: -1)
        XCTAssertEqual(model.parameters.locals.map(\.id), [ids[1], ids[2], ids[0]], "out of range does nothing")

        model.flushPendingSave()
        model.undo()
        XCTAssertEqual(model.parameters.locals.map(\.id), ids, "one undoable step")
    }

    func testComponentsReorder() async throws {
        let model = try await openModel()
        model.addLocal(.radial)
        model.addMaskComponent(.luminanceRange, mode: .add)
        model.addMaskComponent(.colourRange, mode: .subtract)
        let components = model.parameters.locals[0].components.map(\.id)
        model.moveMaskComponent(components[1], to: 0)
        XCTAssertEqual(model.parameters.locals[0].components.map(\.id), [components[1], components[0]])
        model.moveMaskComponent(components[1], to: 5)
        XCTAssertEqual(model.parameters.locals[0].components.map(\.id), [components[1], components[0]],
                       "past the end does nothing")
    }

    func testLinkedComponent() async throws {
        let model = try await openModel()
        model.addLocal(.radial)
        model.addLocal(.linear)
        let target = model.parameters.locals[0].id
        model.selectedLocalIndex = 1
        model.addLinkedMaskComponent(target, mode: .intersect)
        let link = try XCTUnwrap(model.parameters.locals[1].components.first)
        XCTAssertEqual(link.linkedMaskID, target)
        XCTAssertEqual(model.selectedMaskComponentID, link.id)
        XCTAssertEqual(model.parameters.packedComponentCount(ofLocal: 1), 1)

        // The used mask can't take links of its own, nor link back.
        model.selectedLocalIndex = 0
        model.addLinkedMaskComponent(model.parameters.locals[1].id, mode: .add)
        XCTAssertTrue(model.parameters.locals[0].components.isEmpty)
    }
}
