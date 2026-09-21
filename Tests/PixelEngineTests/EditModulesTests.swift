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

    /// The two retouch groups (docs/Retouch.md contract D): named, never
    /// part of the look, taken and left like the other geometry groups.
    func testDustAndTouchUpGroups() throws {
        XCTAssertTrue(EditGroup.allCases.contains(.dust))
        XCTAssertTrue(EditGroup.allCases.contains(.touchUp))
        XCTAssertEqual(EditGroup.dust.rawValue, "dust")
        XCTAssertEqual(EditGroup.touchUp.rawValue, "touchUp")
        XCTAssertTrue(EditGroup.lookGroups.isDisjoint(with: [.dust, .touchUp]))
        XCTAssertEqual(EditGroup.dust.displayName, "Sensor Dust")
        XCTAssertEqual(EditGroup.touchUp.displayName, "Touch-up (skin, teeth, eyes, blemishes)")

        var a = EditParameters(); a.exposureEV = 1
        a.dust = [HealPatch(target: [0.1, 0.1], source: [0.11, 0.1], radius: 0.002)]
        a.touchUp.faces = [TouchUpFace(boundingBox: SIMD4(0.4, 0.2, 0.1, 0.15))]
        a.touchUp.skinSmoothing = 40
        var b = EditParameters(); b.contrast = 2
        b.dust = [HealPatch(target: [0.5, 0.5], source: [0.51, 0.5], radius: 0.002)]
        b.touchUp.eyes = 20
        let stackA = EditStack(parameters: a), stackB = EditStack(parameters: b)
        XCTAssertEqual(stackA.presentGroups, [.whiteBalance, .tone, .toneCurve, .colour, .splitToning, .detail, .lens, .dust, .touchUp])

        let merged = stackA.merged(with: stackB, groups: [.dust, .touchUp])
        XCTAssertEqual(merged.modules.dust, b.dust, "dust replaces")
        XCTAssertEqual(merged.modules.touchup?.eyes, 20)
        XCTAssertEqual(merged.modules.touchup?.skinSmoothing, 0)
        XCTAssertEqual(merged.modules.touchup?.faces, a.touchUp.faces, "faces stay")
        XCTAssertEqual(merged.parameters().exposureEV, 1)
        XCTAssertEqual(merged.frame, EditStack.activeAreaFrame)

        let restricted = stackA.restricted(to: [.dust])
        XCTAssertEqual(restricted.presentGroups, [.dust])
        XCTAssertEqual(restricted.frame, EditStack.activeAreaFrame)
        XCTAssertEqual(stackA.restricted(to: [.tone]).presentGroups, [.tone])
        XCTAssertNil(stackA.restricted(to: [.tone]).frame)
        // A touch-up copied without its faces carries no geometry.
        XCTAssertNil(stackA.restricted(to: [.touchUp]).frame)
        XCTAssertEqual(stackA.restricted(to: [.touchUp]).modules.touchup?.faces, [])
    }

    /// A preset saved by a later build may name a group this one lacks;
    /// the preset still loads, without that group.
    func testPresetGroupsDecodeLeniently() throws {
        let json = #"{"name":"Later","groups":["tone","glow","touchUp"],"stack":{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}}"#
        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.name, "Later")
        XCTAssertEqual(preset.groups, [.tone, .touchUp])
        XCTAssertFalse(preset.isBuiltIn)
        XCTAssertEqual(preset.stack.parameters().exposureEV, 0.5)
        // And a preset of this build round-trips whole.
        var p = EditParameters(); p.contrast = 1.9; p.touchUp.skinSmoothing = 30
        let saved = Preset(name: "Mine", groups: [.tone, .touchUp], stack: EditStack(parameters: p), isBuiltIn: true)
        let back = try JSONDecoder().decode(Preset.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(back, saved)
        XCTAssertTrue(back.isBuiltIn)
    }

    func testBuiltInBlackAndWhiteDesaturates() {
        let bw = try! XCTUnwrap(Preset.builtIns.first { $0.name == "Black & White" })
        let p = EditStack().merged(with: bw.stack, groups: bw.groups).parameters()
        XCTAssertEqual(p.hsl.saturation, Array(repeating: -1, count: 8))
    }
}
