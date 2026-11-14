import XCTest
import PixelEngine
@testable import latent_app

/// Preset folders and favourites in menus, presets as bindable commands,
/// panel presets, apply modes, a preset at export, and the print panel's
/// preset, sharpening, profile and margins.
@MainActor
final class PresetManagementTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "PresetManagementTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func preset(_ name: String, _ groups: Set<EditGroup> = [.tone], contrast: Float = 1.5) -> Preset {
        var p = EditParameters(); p.contrast = contrast
        return Preset(name: name, groups: groups, stack: EditStack(parameters: p))
    }

    private func titles(_ nodes: [PresetMenuNode]) -> [String] {
        nodes.map { node in
            switch node.kind {
            case .preset(let preset): preset.leafName
            case .folder(let name, let children): "\(name)[\(titles(children).joined(separator: ","))]"
            }
        }
    }

    func testFoldersBecomeNestedMenusInOrder() {
        let nodes = PresetMenuTree.nodes([preset("Alpha"), preset("Film|Portra"), preset("Beta"),
                                          preset("Film|Colour|Ektar"), preset("Film|Tri-X")])
        XCTAssertEqual(titles(nodes), ["Alpha", "Film[Portra,Colour[Ektar],Tri-X]", "Beta"])
        XCTAssertEqual(PresetMenuTree.favouriteTitle(preset("Film|Portra")), "Film › Portra")
    }

    func testFavouritesFollowRenamesAndDeletes() {
        let catalog = PresetCatalog(defaults: defaults, presets: [preset("A"), preset("B")])
        catalog.toggleFavourite(preset("B"))
        XCTAssertEqual(catalog.favouritePresets.map(\.name), ["B"])
        catalog.renamed(from: "B", to: "Film|B")
        XCTAssertEqual(defaults.stringArray(forKey: PresetCatalog.favouritesKey), ["Film|B"])
        catalog.update([preset("A")])
        XCTAssertTrue(catalog.favourites.isEmpty, "a deleted preset's star goes")
        XCTAssertNil(defaults.stringArray(forKey: PresetCatalog.favouritesKey))
        catalog.update(PresetStore.load())
    }

    // MARK: Presets as commands

    func testPresetsAreBindableCommandsAndMissingOnesShowAsMissing() throws {
        let before = PresetShortcuts.currentNames
        defer { PresetShortcuts.setNames(before) }
        PresetShortcuts.setNames(["Film|Portra"])
        let id = PresetShortcuts.id(for: "Film|Portra"), goneID = PresetShortcuts.id(for: "Gone")
        let overrides: [String: ShortcutOverride] = [id: .keys(.character("p"), [.control, .option]),
                                                     goneID: .keys(.character("g"), [.control, .option])]
        let rows = PresetShortcuts.infos(overrides: overrides)
        XCTAssertEqual(rows.map(\.title), ["Apply Preset: Film|Portra", "Apply Preset: Gone (missing)"])
        XCTAssertEqual(rows.first?.command, .applyPreset("Film|Portra"))
        XCTAssertTrue(PresetShortcuts.isMissing(.applyPreset("Gone")))
        XCTAssertFalse(PresetShortcuts.isMissing(.applyPreset("Film|Portra")))

        // Kept while missing, so they come back with the preset; no unbinding.
        let kept = Keymap.normalised(overrides.merging([PresetShortcuts.id(for: "X"): .unbound]) { a, _ in a })
        XCTAssertEqual(Set(kept.keys), [id, goneID])
        let table = Keymap.effective(overrides: overrides)
        XCTAssertEqual(table.first { $0.command == .applyPreset("Film|Portra") }?.glyphs, "⌃⌥P")
        XCTAssertNotNil(table.first { $0.command == .applyPreset("Gone") })
        XCTAssertEqual(Keymap.effective(overrides: [:]).count, Shortcuts.all.count, "no keys by default")
        // A key a preset has is taken, as any command's is.
        let export = try XCTUnwrap(Keymap.info(for: .export))
        XCTAssertEqual(Keymap.problem(giving: .character("p"), [.control, .option], to: export, in: table),
                       .taken(by: rows[0]))

        let file = KeymapFile(overrides: overrides)
        XCTAssertEqual(try KeymapFile.decode(file.encoded()).overrides, overrides)
    }

    func testRenamingAPresetMovesItsKeys() {
        let keymap = Keymap(defaults: defaults)
        let settings = KeyboardSettings(keymap: keymap)
        keymap.setOverrides([PresetShortcuts.id(for: "Old"): .keys(.character("o"), [.control, .option])])
        settings.presetRenamed(from: "Old", to: "Film|New")
        XCTAssertEqual(keymap.overrides, [PresetShortcuts.id(for: "Film|New"): .keys(.character("o"), [.control, .option])])
    }

    func testApplyPresetIsEnabledWithSomethingToApplyTo() {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.applyPreset("A")))
        state.selectionCount = 2
        XCTAssertTrue(state.isEnabled(.applyPreset("A")))
    }

    // MARK: Panels, modes and the manager

    func testPanelMenusListPresetsOfExactlyThatPanel() {
        let all = [preset("Curve", [.toneCurve]), preset("Mixed", [.toneCurve, .tone]), preset("Tone", [.tone])]
        XCTAssertEqual(PanelPresetsMenu.presets(all, for: [.toneCurve]).map(\.name), ["Curve"])
        XCTAssertEqual(PanelPresetsMenu.presets(all, for: [.tone]).map(\.name), ["Tone"])
    }

    func testOverwriteStartsFromTheDefaultEdit() {
        var look = EditParameters(); look.contrast = 2
        let stack = PresetApplier.overwritten(with: EditStack(parameters: look).restricted(to: [.tone]),
                                              groups: [.tone], amount: 1)
        XCTAssertEqual(stack.presentGroups, [.tone])
        XCTAssertEqual(stack.parameters().contrast, 2)
        let half = PresetApplier.overwritten(with: EditStack(parameters: look).restricted(to: [.tone]),
                                             groups: [.tone], amount: 0.5)
        XCTAssertEqual(half.parameters().contrast, (EditParameters().contrast + 2) / 2, accuracy: 0.0001)
    }

    func testManagerGroupsByFolder() {
        let sections = PresetManagerSheet.sections(Preset.builtIns + [preset("Zeta|A"), preset("Loose"), preset("alpha|B")])
        XCTAssertEqual(sections.map(\.title), ["Built-in", "My Presets", "alpha", "Zeta"])
        XCTAssertEqual(sections.last?.presets.map(\.name), ["Zeta|A"])
    }

    // MARK: Export

    func testExportPresetStyleIsOptionalAndAppliedToCopies() throws {
        let old = try JSONDecoder().decode(ExportPreset.self, from: Data("{}".utf8))
        XCTAssertNil(old.presetStyle)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(ExportPreset()), as: UTF8.self).contains("presetStyle"))

        var styled = ExportPreset()
        styled.presetStyle = PresetStyle(presetName: "Strong", mode: .append, amount: 1)
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(styled))
        XCTAssertEqual(back.presetStyle, styled.presetStyle)

        var mine = EditParameters(); mine.exposureEV = 0.5
        let json = try EditStack(parameters: mine).restricted(to: [.tone]).encodeJSON()
        var clear = EditParameters(); clear.clarity = 0.4
        let strong = Preset(name: "Strong", groups: [.presence], stack: EditStack(parameters: clear))
        let lookup: (String) -> Preset? = { $0 == "Strong" ? strong : nil }
        XCTAssertEqual(ExportPreset().styledEditStackJSON(json, lookup: lookup), json, "none by default")
        let out = try XCTUnwrap(styled.styledEditStackJSON(json, lookup: lookup))
        XCTAssertNotEqual(out, json)
        XCTAssertEqual(try EditStack.decode(json: out).parameters().exposureEV, 0.5)
        XCTAssertEqual(try EditStack.decode(json: out).parameters().clarity, 0.4, accuracy: 0.0001)
        var dng = styled
        dng.fileKind = .dng
        XCTAssertEqual(dng.styledEditStackJSON(json, lookup: lookup), json, "not for a DNG")
        XCTAssertEqual(styled.presetStyleSummary, "Strong (Append, 100%)")
    }

    // MARK: Print

    func testOldSingleMarginDecodesIntoAllFourSides() throws {
        let old = try JSONDecoder().decode(PrintLayoutSettings.self, from: Data(#"{"margin":24}"#.utf8))
        XCTAssertEqual(old.margins, LayoutInsets(all: 24))
        XCTAssertTrue(old.marginsLocked)
        XCTAssertNil(old.presetStyle)
        XCTAssertNil(old.sharpening)
        XCTAssertEqual(old.color, .proofProfile, "Use soft-proof profile stays the default")
        let plain = String(decoding: try JSONEncoder().encode(PrintLayoutSettings()), as: UTF8.self)
        for key in ["customMargins", "presetStyle", "sharpening", "printProfileBookmark", "marginUnit"] {
            XCTAssertFalse(plain.contains(key), key)
        }
    }

    func testFourMarginsLayOutEachSide() throws {
        let letter = PrintPaper(size: CGSize(width: 612, height: 792),
                                imageableBounds: CGRect(x: 18, y: 18, width: 576, height: 756), dotsPerInch: 300)
        var settings = PrintLayoutSettings()
        settings.customMargins = LayoutInsets(top: 72, left: 9, bottom: 36, right: 500)
        settings = settings.validated
        XCTAssertEqual(settings.customMargins?.right, PrintLayoutSettings.marginRange.upperBound)
        let layout = letter.layout(for: settings, imageCount: 1)
        XCTAssertEqual(layout.margins, LayoutInsets(top: 72, left: 18, bottom: 36, right: 72),
                       "never inside the printer's own edge")
        let back = try JSONDecoder().decode(PrintLayoutSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back, settings)
        XCTAssertEqual(PrintMarginUnit.millimetres.text(points: 72, locale: Locale(identifier: "en_GB")), "25.4 mm")
        XCTAssertEqual(PrintMarginUnit.points.text(points: 18, locale: Locale(identifier: "en_GB")), "18 pt")
    }

    func testPrintRendersAgainOnlyWhenPresetOrSharpeningChanges() {
        let letter = PrintPaper(size: CGSize(width: 612, height: 792), dotsPerInch: 300)
        let made = OptionsLog()
        let job = PrintJob(items: FakeRenders.items(["red"]), settings: PrintLayoutSettings(), paper: letter,
                           proofProfile: nil,
                           makeOptionsRenderer: { options in made.append(options); return FakeRenders().renderer() },
                           makePreview: { _ in SheetPreviewImages(renderer: nil, thumbnail: FakeRenders.thumbnails, onReady: {}) })
        var settings = PrintLayoutSettings()
        settings.margin = 30
        job.update(settings: settings)
        XCTAssertEqual(made.count, 1, "layout changes reuse the renders")
        settings.presetStyle = PresetStyle(presetName: "Punchy")
        job.update(settings: settings)
        settings.sharpening = OutputSharpening(medium: .matte, strength: .high)
        job.update(settings: settings)
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(made.last?.presetStyle?.presetName, "Punchy")
        XCTAssertEqual(made.last?.ppi, 300)
        // A new printer resolution changes the sharpening.
        job.update(paper: PrintPaper(size: CGSize(width: 612, height: 792), dotsPerInch: 180))
        XCTAssertEqual(made.count, 4)
        XCTAssertEqual(made.last?.ppi, 180)
        // Screen sharpening is for files.
        settings.sharpening = OutputSharpening(medium: .screen)
        XCTAssertNil(settings.validated.sharpening)
        XCTAssertEqual(PrintExtrasSection.summary(job.currentSettings).map(\.name), ["Preset", "Sharpening"])
    }

    func testIntentAppliesToTheChosenProfile() {
        var settings = PrintLayoutSettings()
        XCTAssertFalse(settings.usesIntent(proofProfileName: nil))
        XCTAssertTrue(settings.usesIntent(proofProfileName: "Paper"))
        settings.color = .icc
        XCTAssertFalse(settings.usesIntent(proofProfileName: "Paper"), "no print profile chosen yet")
        XCTAssertNil(settings.profile(proof: nil))
        settings.printProfileBookmark = Data([1, 2, 3])
        settings.printProfileName = "Glossy"
        XCTAssertTrue(settings.usesIntent(proofProfileName: nil))
        XCTAssertNil(settings.profile(proof: nil), "a bookmark that doesn't resolve prints in Display P3")
        XCTAssertEqual(settings.colourDescription(proofProfileName: nil), "Printer profile: Glossy")
    }
}

/// The options each renderer was made for.
final class OptionsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrintRenderOptions] = []

    func append(_ options: PrintRenderOptions) { lock.withLock { values.append(options) } }
    var count: Int { lock.withLock { values.count } }
    var last: PrintRenderOptions? { lock.withLock { values.last } }
}
