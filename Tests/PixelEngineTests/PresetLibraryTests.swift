import XCTest
import ColorKit
import CoreGraphics
@testable import PixelEngine

/// Preset folders, names, the note, files, store management and the style
/// applied on output (PresetLibrary.swift), and the extra rendering intents.
final class PresetLibraryTests: XCTestCase {
    private func look(_ name: String, contrast: Float = 1.6) -> Preset {
        var p = EditParameters(); p.contrast = contrast
        return Preset(name: name, groups: [.tone], stack: EditStack(parameters: p))
    }

    func testFoldersAndNames() {
        XCTAssertEqual(Preset.pathComponents(of: "Film|Portra 400"), ["Film", "Portra 400"])
        XCTAssertEqual(Preset.pathComponents(of: " Film || Portra "), ["Film", "Portra"])
        XCTAssertEqual(Preset.pathComponents(of: "Plain"), ["Plain"])
        XCTAssertEqual(look("Film|Colour|Ektar").folders, ["Film", "Colour"])
        XCTAssertEqual(look("Film|Colour|Ektar").leafName, "Ektar")
        XCTAssertEqual(look("Punchy").folders, [])
        XCTAssertEqual(Preset.normalisedName("  Film | Portra  "), "Film|Portra")
        XCTAssertNil(Preset.normalisedName(" | "))
        XCTAssertEqual(Preset.uniqueName("Portra", avoiding: ["portra", "Portra 2"]), "Portra 3")
        XCTAssertEqual(Preset.uniqueName("New", avoiding: ["Old"]), "New")
    }

    /// The note is absent when empty, so a preset without one encodes
    /// byte for byte as it did before the field existed.
    func testDescriptionIsAbsentWhenEmptyAndDecodesLeniently() throws {
        let plain = look("Plain")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(json.contains("description"))
        var noted = plain
        noted.details = "For overcast days"
        let back = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(noted))
        XCTAssertEqual(back.details, "For overcast days")
        // A note of the wrong type loses the note, not the preset.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        object["description"] = 42
        let odd = try JSONDecoder().decode(Preset.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(odd.details)
        XCTAssertEqual(odd.name, "Plain")
    }

    func testExportedFilesReadBackAsUserPresets() throws {
        let builtIn = try XCTUnwrap(Preset.builtIns.first)
        let one = try PresetStore.decodeFile(PresetStore.exportData([builtIn]))
        XCTAssertEqual(one.map(\.name), [builtIn.name])
        XCTAssertFalse(one[0].isBuiltIn, "an imported preset is always the user's")
        let many = try PresetStore.decodeFile(PresetStore.exportData([look("A"), look("Film|B")]))
        XCTAssertEqual(many.map(\.name), ["A", "Film|B"])
        XCTAssertThrowsError(try PresetStore.decodeFile(Data("{\"format\":\"latent-keymap\"}".utf8)))
        XCTAssertThrowsError(try PresetStore.decodeFile(Data("[]".utf8)))
    }

    func testAvailabilityIgnoresCaseAndBuiltIns() {
        let presets = Preset.builtIns + [look("Mine")]
        XCTAssertFalse(PresetStore.isAvailable("mine", among: presets))
        XCTAssertFalse(PresetStore.isAvailable("PUNCHY", among: presets))
        XCTAssertTrue(PresetStore.isAvailable("mine", among: presets, ignoring: "Mine"))
        XCTAssertTrue(PresetStore.isAvailable("Other", among: presets))
        // Two names for one file clash too.
        XCTAssertFalse(PresetStore.isAvailable("Mi:ne", among: presets + [look("Mi/ne")]))
    }

    /// Rename, duplicate, restrict and import against the real store, with
    /// names no one else uses, removed afterwards.
    func testManagingTheStore() throws {
        let tag = UUID().uuidString.prefix(6)
        var preset = look("Test \(tag)")
        preset.details = "note"
        var full = EditParameters(); full.contrast = 1.4; full.vibrance = 0.3
        preset = Preset(name: "Test \(tag)", groups: [.tone, .colour], stack: EditStack(parameters: full))
        try PresetStore.save(preset)
        var cleanup = [preset.name]
        defer { for name in cleanup { try? PresetStore.delete(named: name) } }

        let renamed = try PresetStore.rename(preset, to: "Tests \(tag)|Renamed", among: PresetStore.load())
        cleanup.append(renamed.name)
        let afterRename = PresetStore.load()
        XCTAssertNil(afterRename.first { $0.name == preset.name })
        XCTAssertEqual(afterRename.first { $0.name == renamed.name }?.groups, [.tone, .colour])
        XCTAssertThrowsError(try PresetStore.rename(Preset.builtIns[0], to: "x", among: afterRename))

        let copy = try PresetStore.duplicate(renamed, among: afterRename)
        cleanup.append(copy.name)
        XCTAssertEqual(copy.name, "Tests \(tag)|Renamed copy")
        XCTAssertFalse(copy.isBuiltIn)

        let narrowed = try PresetStore.restrict(copy, to: [.colour, .crop])
        XCTAssertEqual(narrowed.groups, [.colour], "never widened")
        XCTAssertNil(narrowed.stack.modules.tone)
        XCTAssertNotNil(narrowed.stack.modules.vibrance)

        let names = try PresetStore.importFile(PresetStore.exportData([renamed]), existing: PresetStore.load())
        cleanup += names
        XCTAssertEqual(names, ["Tests \(tag)|Renamed 2"])
        XCTAssertEqual(PresetStore.preset(named: names[0])?.stack.parameters().contrast, 1.4)
    }

    // MARK: Style on output

    func testStyleAppendsOrReplacesWithoutTouchingTheStoredEdit() throws {
        var mine = EditParameters(); mine.exposureEV = 1; mine.contrast = 1.2
        let stored = try EditStack(parameters: mine).restricted(to: [.tone]).encodeJSON()
        var bw = EditParameters(); bw.colour.blackAndWhite = BlackAndWhite(enabled: true)
        let preset = Preset(name: "BW", groups: [.colour], stack: EditStack(parameters: bw))

        let appended = try XCTUnwrap(PresetStyle(presetName: "BW").applied(to: stored, preset: preset))
        let a = try EditStack.decode(json: appended).parameters()
        XCTAssertEqual(a.exposureEV, 1, "the photo's own edit stays")
        XCTAssertTrue(a.colour.blackAndWhite.enabled)

        let replaced = try XCTUnwrap(PresetStyle(presetName: "BW", mode: .replace).applied(to: stored, preset: preset))
        let r = try EditStack.decode(json: replaced).parameters()
        XCTAssertEqual(r.exposureEV, EditParameters().exposureEV, "Replace starts from no edit")
        XCTAssertTrue(r.colour.blackAndWhite.enabled)

        // Amount blends as the Presets panel's does.
        let contrasty = look("C", contrast: 2.0)
        let half = try XCTUnwrap(PresetStyle(presetName: "C", amount: 0.5).applied(to: stored, preset: contrasty))
        XCTAssertEqual(try EditStack.decode(json: half).parameters().contrast, 1.6, accuracy: 0.0001)

        // A missing preset or an unreadable edit leaves the JSON alone.
        XCTAssertEqual(PresetStyle(presetName: "gone").applied(to: stored, lookup: { _ in nil }), stored)
        XCTAssertEqual(PresetStyle(presetName: "BW").applied(to: "not json", lookup: { _ in preset }), "not json")
        XCTAssertNotNil(PresetStyle(presetName: "BW").applied(to: nil, lookup: { _ in preset }))
    }

    func testStyleDecodesLeniently() throws {
        let style = try JSONDecoder().decode(PresetStyle.self,
                                             from: Data(#"{"presetName":"X","mode":"sideways","amount":9}"#.utf8))
        XCTAssertEqual(style, PresetStyle(presetName: "X", mode: .append, amount: 2))
        let round = try JSONDecoder().decode(PresetStyle.self, from: JSONEncoder().encode(
            PresetStyle(presetName: "Film|Y", mode: .replace, amount: 0.4)))
        XCTAssertEqual(round, PresetStyle(presetName: "Film|Y", mode: .replace, amount: 0.4))
    }

    // MARK: Rendering intents

    func testAllFourIntentsDecodeAndConvert() throws {
        for (raw, intent) in [("perceptual", RenderingIntent.perceptual), ("relativeColorimetric", .relativeColorimetric),
                              ("saturation", .saturation), ("absoluteColorimetric", .absoluteColorimetric)] {
            XCTAssertEqual(try JSONDecoder().decode(RenderingIntent.self, from: Data("\"\(raw)\"".utf8)), intent)
        }
        XCTAssertEqual(RenderingIntent.allCases.prefix(2), [.perceptual, .relativeColorimetric],
                       "the two usual intents stay first")
        XCTAssertFalse(RenderingIntent.saturation.usesBlackPointCompensation)
        XCTAssertFalse(RenderingIntent.absoluteColorimetric.usesBlackPointCompensation)
        let working = try XCTUnwrap(ICCProfile.linearRec2020)
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB).flatMap { ICCProfile(colorSpace: $0) })
        for intent in RenderingIntent.allCases {
            let out = try ICCTransform.convert([0.5, 0.2, 0.1], from: working, to: srgb, intent: ICCTransform.Intent(intent))
            XCTAssertEqual(out.count, 3, "\(intent)")
            XCTAssertTrue(out.allSatisfy { $0.isFinite }, "\(intent)")
        }
    }
}
