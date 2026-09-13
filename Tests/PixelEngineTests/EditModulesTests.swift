import XCTest
import ColorKit
@testable import PixelEngine

final class EditModulesTests: XCTestCase {
    func testMergeTakesOnlyChosenGroups() throws {
        var a = EditParameters(); a.exposureEV = 1; a.sharpenAmount = 1
        a.locals = [LocalAdjustment(name: "x", shape: .whole, exposureEV: 0.5)]
        var b = EditParameters(); b.exposureEV = -1; b.contrast = 2; b.hsl.saturation[0] = 0.5
        let merged = EditStack(parameters: a).merged(with: EditStack(parameters: b), groups: [.tone, .colour])
        let p = merged.parameters()
        XCTAssertEqual(p.exposureEV, -1, "tone came from b")
        XCTAssertEqual(p.contrast, 2)
        XCTAssertEqual(p.hsl.saturation[0], 0.5, "colour came from b")
        XCTAssertEqual(p.sharpenAmount, 1, "detail kept from a")
        XCTAssertEqual(p.locals.count, 1, "locals kept from a")
    }

    func testRestrictedStackCarriesOnlyItsGroups() throws {
        var p = EditParameters(); p.exposureEV = 1; p.sharpenAmount = 1
        p.locals = [LocalAdjustment(name: "x", shape: .whole)]
        let look = EditStack(parameters: p).restricted(to: EditGroup.lookGroups)
        XCTAssertTrue(look.presentGroups.contains(.tone))
        XCTAssertTrue(look.presentGroups.contains(.detail))
        XCTAssertFalse(look.presentGroups.contains(.locals))
        XCTAssertNil(look.modules.lens)
        // Applying it to a fresh image leaves the image's own locals alone.
        var target = EditParameters()
        target.locals = [LocalAdjustment(name: "keep", shape: .whole)]
        let applied = EditStack(parameters: target).merged(with: look, groups: look.presentGroups).parameters()
        XCTAssertEqual(applied.exposureEV, 1)
        XCTAssertEqual(applied.locals.first?.name, "keep")
    }

    func testPresetsRoundTripThroughDisk() throws {
        var p = EditParameters(); p.contrast = 1.9
        let preset = Preset(name: "Test Preset \(UUID().uuidString.prefix(6))", groups: [.tone], stack: EditStack(parameters: p))
        try PresetStore.save(preset)
        defer { try? PresetStore.delete(named: preset.name) }
        let loaded = PresetStore.load()
        XCTAssertGreaterThanOrEqual(loaded.filter(\.isBuiltIn).count, 4)
        let back = try XCTUnwrap(loaded.first { $0.name == preset.name })
        XCTAssertEqual(back.groups, [.tone])
        XCTAssertEqual(back.stack.parameters().contrast, 1.9)
        XCTAssertNil(back.stack.modules.hsl, "restricted to its groups")
    }

    func testBuiltInBlackAndWhiteDesaturates() {
        let bw = try! XCTUnwrap(Preset.builtIns.first { $0.name == "Black & White" })
        let p = EditStack().merged(with: bw.stack, groups: bw.groups).parameters()
        XCTAssertEqual(p.hsl.saturation, Array(repeating: -1, count: 8))
    }
}
