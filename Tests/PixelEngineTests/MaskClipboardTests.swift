import XCTest
import simd
@testable import PixelEngine

/// Copy Mask / Paste Mask's logic (MaskClipboard.swift): which components
/// travel, fresh ids per paste, and that a paste only ever adds a mask.
final class MaskClipboardTests: XCTestCase {
    private let linkedID = UUID()

    private func sampleMask() -> LocalAdjustment {
        var local = LocalAdjustment(name: "Sky", shape: .linear(start: SIMD2(0.5, 0), end: SIMD2(0.5, 0.4)),
                                    exposureEV: -0.7, saturation: 0.2)
        local.dehaze = 0.3
        local.hidden = true
        local.components = [
            MaskComponent(mode: .add, source: .shape(.brush(strokes: [
                BrushStroke(points: [SIMD2(0.2, 0.2), SIMD2(0.3, 0.25)], radius: 0.05, feather: 0.5, flow: 1, erase: false),
            ]))),
            MaskComponent(mode: .intersect, source: .shape(.ai(kind: "subject", modelVersion: "test-1"))),
            MaskComponent(mode: .intersect, source: .luminance(LuminanceRange(low: 0.5, high: 1, feather: 0.1))),
            MaskComponent(mode: .subtract, source: .mask(id: linkedID)),
        ]
        return local
    }

    // MARK: - Copy

    func testCopyKeepsGeometryModelMasksAndSlidersButDropsLinks() {
        let source = sampleMask()
        let copied = CopiedMask(source)
        XCTAssertEqual(copied.mask.components.map(\.source), Array(source.components.prefix(3)).map(\.source),
                       "brush strokes, the subject and the range travel as they are; the link is left out")
        XCTAssertEqual(copied.skipped.map(\.reason), [.linkedMask])
        XCTAssertEqual(copied.mask.shape, source.shape, "normalised geometry is copied as is")
        XCTAssertEqual(copied.mask.exposureEV, -0.7)
        XCTAssertEqual(copied.mask.saturation, 0.2)
        XCTAssertEqual(copied.mask.dehaze, 0.3)
        XCTAssertEqual(copied.mask.name, "Sky", "pasted under its own name")
        XCTAssertFalse(copied.mask.hidden, "pasted shown")
        XCTAssertTrue(copied.hasModelMask)
    }

    func testAMaskWithNothingToDropSkipsNothing() {
        let copied = CopiedMask(LocalAdjustment(name: "Glow", shape: .whole, exposureEV: 0.5))
        XCTAssertTrue(copied.skipped.isEmpty)
        XCTAssertFalse(copied.hasModelMask)
        XCTAssertEqual(copied.pasteMessage(added: 1, full: 0), "Pasted mask “Glow”")
    }

    func testEveryInstanceHasFreshIds() {
        let source = sampleMask()
        let copied = CopiedMask(source)
        let a = copied.instance(), b = copied.instance()
        XCTAssertNotEqual(a.id, source.id)
        XCTAssertNotEqual(a.id, b.id)
        let sourceIDs = Set(source.components.map(\.id))
        XCTAssertTrue(Set(a.components.map(\.id)).isDisjoint(with: sourceIDs))
        XCTAssertTrue(Set(a.components.map(\.id)).isDisjoint(with: Set(b.components.map(\.id))))
        XCTAssertEqual(a.components.map(\.source), b.components.map(\.source))
        XCTAssertEqual(a.name, "Sky")
    }

    // MARK: - Adding, not replacing

    func testAddingAppendsAndKeepsExistingMasks() throws {
        let existing = [LocalAdjustment(name: "A", shape: .whole), LocalAdjustment(name: "B", shape: .whole)]
        let pasted = CopiedMask(sampleMask()).instance()
        let result = try XCTUnwrap(CopiedMask.adding(pasted, to: existing))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Array(result.prefix(2)), existing)
        XCTAssertEqual(result.last, pasted)
    }

    func testAddingRefusesAFullPhoto() {
        let full = (0..<LocalAdjustment.maximumCount).map { LocalAdjustment(name: "\($0)", shape: .whole) }
        XCTAssertNil(CopiedMask.adding(CopiedMask(sampleMask()).instance(), to: full))
    }

    func testPastingOntoAStoredEditOnlyAddsAMask() throws {
        var p = EditParameters()
        p.sharpenAmount = 1
        p.locals = [LocalAdjustment(name: "Existing", shape: .radial(centre: SIMD2(0.5, 0.5),
                                                                       radii: SIMD2(0.2, 0.2), feather: 0.5))]
        let json = try EditStack(parameters: p).encodeJSON()
        let before = try EditStack.decode(json: json).parameters()
        let pasted = CopiedMask(sampleMask()).instance()
        guard case .added(let out) = try CopiedMask.pasted(pasted, ontoStored: json) else {
            return XCTFail("there is room")
        }
        let after = try EditStack.decode(json: out).parameters()
        XCTAssertEqual(after.locals.count, 2)
        XCTAssertEqual(after.locals[0], before.locals[0], "the existing mask is untouched")
        XCTAssertEqual(after.locals[1], pasted)
        var rest = after; rest.locals = before.locals
        XCTAssertEqual(rest, before, "nothing else in the edit changes")
    }

    func testPastingOntoAPhotoWithNoEdit() throws {
        let copied = CopiedMask(sampleMask())
        guard case .added(let out) = try copied.pasted(ontoStored: nil) else { return XCTFail("there is room") }
        let after = try EditStack.decode(json: out).parameters()
        XCTAssertEqual(after.locals.count, 1)
        XCTAssertEqual(after.locals[0].components.count, 3)
    }

    func testPastingOntoAFullStoredEditLeavesItAlone() throws {
        var p = EditParameters()
        p.locals = (0..<LocalAdjustment.maximumCount).map { LocalAdjustment(name: "\($0)", shape: .whole) }
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertEqual(try CopiedMask(sampleMask()).pasted(ontoStored: json), .full)
    }

    func testAnUnreadableEditThrowsRatherThanBeingReplaced() {
        XCTAssertThrowsError(try CopiedMask(sampleMask()).pasted(ontoStored: "{not json"))
    }

    func testPasteMessageSaysWhatWasLeftOutAndRemade() {
        let message = CopiedMask(sampleMask()).pasteMessage(added: 3, full: 1, skippedUnreadable: ["x.NEF"])
        XCTAssertTrue(message.contains("to 3 photos"))
        XCTAssertTrue(message.contains("1 already had \(LocalAdjustment.maximumCount) masks"))
        XCTAssertTrue(message.contains("x.NEF"))
        XCTAssertTrue(message.contains("left out Linked Mask"), message)
        XCTAssertTrue(message.contains("made again from each photo"))
    }
}
