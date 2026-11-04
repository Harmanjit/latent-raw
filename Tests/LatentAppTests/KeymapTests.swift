import XCTest
@testable import latent_app

@MainActor
final class KeymapTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "KeymapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func same(_ a: Shortcut?, _ b: Shortcut?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.command == b.command && a.key == b.key && a.modifiers == b.modifiers && a.scope == b.scope
    }

    private func info(_ command: KeyCommand) throws -> ShortcutCommandInfo {
        try XCTUnwrap(Keymap.info(for: command), "\(command)")
    }

    /// With nothing changed the keys in effect are the default table, in
    /// its order, so lookups behave exactly as before customisation.
    func testNoOverridesIsTheDefaultTable() {
        let table = Keymap.effective(overrides: [:])
        XCTAssertEqual(table.count, Shortcuts.all.count)
        for (a, b) in zip(table, Shortcuts.all) {
            XCTAssertTrue(same(a, b), "\(a.command) vs \(b.command)")
        }
    }

    /// Every default has a titled row; ids and commands are unique, since
    /// saved keymaps are keyed by id.
    func testEveryCommandIsListedOnceWithATitle() {
        for shortcut in Shortcuts.all {
            let rows = Keymap.commands.filter { $0.command == shortcut.command }
            XCTAssertEqual(rows.count, 1, "\(shortcut.command)")
            XCTAssertNotEqual(rows.first?.group, "Other", "\(shortcut.command) needs an entry in Keymap.catalog")
        }
        XCTAssertEqual(Set(Keymap.commands.map(\.id)).count, Keymap.commands.count)
        XCTAssertTrue(Keymap.commands.contains { $0.command == .moveToFolder }, "menu commands without keys are listed")
        XCTAssertTrue(Keymap.groups.contains("Photo Merge"))
    }

    func testOverridesChangeAndRemoveKeys() throws {
        let export = try info(.export), pick = try info(.pick), move = try info(.moveToFolder)
        let table = Keymap.effective(overrides: [
            export.id: .keys(.character("k"), [.command]),
            pick.id: .unbound,
            move.id: .keys(.character("m"), [.option, .command]),
        ])
        XCTAssertEqual(table.first { $0.command == .export }?.glyphs, "⌘K")
        XCTAssertNil(table.first { $0.command == .pick })
        XCTAssertEqual(table.first { $0.command == .moveToFolder }?.glyphs, "⌥⌘M")
        XCTAssertNil(Shortcuts.command(for: BareKeyPress(.character("p")), in: table))
        // A rebound command keeps its scope.
        let toolSize = try info(.toolSize(1))
        let resized = Keymap.effective(overrides: [toolSize.id: .keys(.character("."), [])])
        XCTAssertEqual(resized.first { $0.command == .toolSize(1) }?.scope, .develop)
        XCTAssertEqual(Shortcuts.command(for: BareKeyPress(.character(".")), in: resized), .toolSize(1))
    }

    func testNormalisingDropsNoOpsAndUnknownCommands() throws {
        let pick = try info(.pick), move = try info(.moveToFolder)
        let kept = Keymap.normalised([
            pick.id: .keys(.character("p"), []),   // its default
            move.id: .unbound,                       // has no keys anyway
            "noSuchCommand": .keys(.character("q"), []),
        ])
        XCTAssertTrue(kept.isEmpty)
    }

    func testProblems() throws {
        let table = Keymap.effective(overrides: [:])
        let pick = try info(.pick)
        XCTAssertEqual(Keymap.problem(giving: .character("q"), .command, to: pick, in: table), .system("Quit"))
        XCTAssertEqual(Keymap.problem(giving: .character("x"), [], to: pick, in: table), .taken(by: try info(.reject)))
        XCTAssertNil(Keymap.problem(giving: .character("p"), [], to: pick, in: table), "its own keys are no clash")
        XCTAssertNil(Keymap.problem(giving: .character("k"), [], to: pick, in: table))
        let pan = try info(.panImage(.up))
        XCTAssertEqual(Keymap.problem(giving: .character("k"), .command, to: pan, in: table), .needsSingleKey)
        XCTAssertNil(Keymap.problem(giving: .character("k"), .shift, to: pan, in: table))
    }

    func testKeymapFileRoundTrip() throws {
        let overrides: [String: ShortcutOverride] = [
            "export": .keys(.character("k"), [.shift, .command]),
            "pick": .unbound,
            "previousImage": .keys(.leftArrow, [.control]),
            "toggleLoupe": .keys(.character(" "), [.shift]),
        ]
        let data = try KeymapFile(overrides: overrides).encoded()
        XCTAssertEqual(try KeymapFile.decode(data).overrides, overrides)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"key\" : null"), text)
        XCTAssertTrue(text.contains("\"space\""), text)
    }

    func testKeymapFileSkipsWhatItCantRead() throws {
        let json = """
        {"format": "latent-keymap", "version": 1, "shortcuts": {
          "export": {"key": "k", "modifiers": ["command"]},
          "pick": {"key": "f19"},
          "reject": {"key": "x", "modifiers": ["hyper"]}
        }}
        """
        let file = try KeymapFile.decode(Data(json.utf8))
        XCTAssertEqual(file.overrides, ["export": .keys(.character("k"), .command)])
        XCTAssertThrowsError(try KeymapFile.decode(Data(#"{"shortcuts": {}}"#.utf8)))
    }

    func testRecordedKeys() throws {
        let e = try XCTUnwrap(Keymap.recordedKeys(charactersIgnoringModifiers: "E", shift: true, command: true,
                                                  option: false, control: false))
        XCTAssertEqual(e.0, .character("e"))
        XCTAssertEqual(e.1, [.shift, .command])
        XCTAssertNil(Keymap.recordedKeys(charactersIgnoringModifiers: "\t", shift: false, command: false,
                                         option: false, control: false), "Tab")
        XCTAssertNil(Keymap.recordedKeys(charactersIgnoringModifiers: "\u{F706}", shift: false, command: false,
                                         option: false, control: false), "F3")
        XCTAssertEqual(Keymap.recordedKeys(charactersIgnoringModifiers: "\u{F705}", shift: false, command: false,
                                           option: false, control: false)?.0, .f2)
        XCTAssertEqual(Keymap.recordedKeys(charactersIgnoringModifiers: " ", shift: false, command: false,
                                           option: false, control: false)?.0, .character(" "))
    }

    func testSettingsReassignResetAndPersist() throws {
        let settings = KeyboardSettings(keymap: Keymap(defaults: defaults))
        let pick = try info(.pick), reject = try info(.reject)
        settings.assign(.character("x"), [], to: pick, takingFrom: reject)
        XCTAssertEqual(settings.shortcut(for: pick)?.glyphs, "X")
        XCTAssertNil(settings.shortcut(for: reject))
        XCTAssertNil(settings.clash(for: pick))

        // A fresh keymap reads the same back from UserDefaults.
        let reloaded = KeyboardSettings(keymap: Keymap(defaults: defaults))
        XCTAssertEqual(reloaded.shortcut(for: pick)?.glyphs, "X")
        XCTAssertTrue(reloaded.isCustomised(reject))

        // Reject's default is Pick's now: resetting it asks first.
        XCTAssertEqual(reloaded.resetProblem(for: reject), .taken(by: pick))
        reloaded.reset(reject, takingFrom: pick)
        XCTAssertEqual(reloaded.shortcut(for: reject)?.glyphs, "X")
        XCTAssertNil(reloaded.shortcut(for: pick))

        reloaded.resetAll()
        XCTAssertFalse(reloaded.hasCustomisations)
        XCTAssertNil(defaults.data(forKey: Keymap.defaultsKey))
        XCTAssertEqual(reloaded.shortcut(for: pick)?.glyphs, "P")
    }

    func testImportRefusesClashesAndKeepsTheKeys() throws {
        let settings = KeyboardSettings(keymap: Keymap(defaults: defaults))
        let clashing = try KeymapFile(overrides: ["pick": .keys(.character("x"), [])]).encoded()
        XCTAssertThrowsError(try settings.importData(clashing))
        let system = try KeymapFile(overrides: ["pick": .keys(.character("q"), .command)]).encoded()
        XCTAssertThrowsError(try settings.importData(system))
        XCTAssertFalse(settings.hasCustomisations)

        let good = try KeymapFile(overrides: ["pick": .keys(.character("k"), []), "reject": .unbound]).encoded()
        try settings.importData(good)
        XCTAssertEqual(settings.shortcut(for: try info(.pick))?.glyphs, "K")
        XCTAssertEqual(try KeymapFile.decode(settings.exportData()).overrides,
                       ["pick": .keys(.character("k"), []), "reject": .unbound])
    }

    /// The generated page documents the defaults whatever this Mac's keys.
    func testPageUsesDefaults() {
        XCTAssertTrue(Shortcuts.pageMarkdown().contains("Settings › Keyboard"))
        XCTAssertEqual(Shortcuts.defaultShortcut(for: .pick)?.glyphs, "P")
    }
}
