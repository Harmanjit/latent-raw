import XCTest
import AppKit
import PixelEngine
import Catalog
@testable import latent_app

/// Snapshots compared as the Before, the draggable split, and the batch
/// edit commands (LibraryBatchEdits.swift, SelectiveSettingsSheet.swift).
@MainActor
final class HistoryBatchEditsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "HistoryBatchEditsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Split

    func testTheSplitMovesWithItsFraction() {
        XCTAssertEqual(BeforeAfterLayout.leftRightSplit.afterFraction(split: 0.5),
                       BeforeAfterLayout.leftRightSplit.afterFraction, "the middle is the split as it always was")
        XCTAssertEqual(BeforeAfterLayout.topBottomSplit.afterFraction(split: 0.5),
                       BeforeAfterLayout.topBottomSplit.afterFraction)
        XCTAssertEqual(BeforeAfterLayout.leftRightSplit.afterFraction(split: 0.25), CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        XCTAssertEqual(BeforeAfterLayout.topBottomSplit.afterFraction(split: 0.75), CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
        XCTAssertNil(BeforeAfterLayout.leftRight.afterFraction(split: 0.3))
        XCTAssertEqual(BeforeAfterLayout.leftRightSplit.afterFraction(split: 2)?.minX, 0.95, "kept inside the view")
        XCTAssertEqual(BeforeAfterSplit.clamped(-1), 0.05)
        XCTAssertEqual(BeforeAfterSplit.clamped(.nan), 0.5)
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(BeforeAfterSplit.fraction(at: CGPoint(x: 100, y: 150), in: size, stacked: false), 0.25)
        XCTAssertEqual(BeforeAfterSplit.fraction(at: CGPoint(x: 100, y: 150), in: size, stacked: true), 0.75)
        XCTAssertEqual(BeforeAfterSplit.fraction(at: .zero, in: .zero, stacked: false), 0.5)
    }

    func testTheViewStateKeepsTheSplitInRange() {
        let state = DevelopViewState(defaults: defaults)
        XCTAssertEqual(state.splitFraction, 0.5)
        state.splitFraction = 0.01
        XCTAssertEqual(state.splitFraction, 0.05)
        state.splitFraction = 0.7
        XCTAssertEqual(state.splitFraction, 0.7)
    }

    func testABeforeFromCopyAfterToBeforeHasNoSnapshotName() {
        let override = BeforeOverride(url: URL(fileURLWithPath: "/a.NEF"), stack: EditStack())
        XCTAssertNil(override.snapshotName)
        let model = EditorModel()
        XCTAssertEqual(model.beforeLabel, "Before", "with no image, the plain label")
        XCTAssertNil(model.beforeSnapshotName)
    }

    // MARK: Commands

    func testCommandsAreEnabledWhereTheyApply() {
        var state = CommandState()
        state.mode = .library
        for command in HistoryCommand.allCases {
            XCTAssertFalse(state.isEnabled(.history(command)), "\(command) with nothing selected")
        }
        state.hasSelection = true
        state.selectionCount = 1
        XCTAssertTrue(state.isEnabled(.history(.resetEdits)))
        XCTAssertTrue(state.isEnabled(.history(.pasteOverwrite)))
        XCTAssertTrue(state.isEnabled(.history(.copySelective)))
        XCTAssertTrue(state.isEnabled(.history(.loadSettingsFromFile)))
        XCTAssertTrue(state.isEnabled(.history(.newBlankCopy)))
        XCTAssertFalse(state.isEnabled(.history(.syncLastChange)), "nothing to sync to")
        state.selectionCount = 3
        XCTAssertTrue(state.isEnabled(.history(.syncLastChange)))
        state.fileOperationRunning = true
        XCTAssertFalse(state.isEnabled(.history(.newBlankCopy)))
        state.mode = .survey
        XCTAssertFalse(state.isEnabled(.history(.syncLastChange)))
    }

    func testTheNewCommandsHaveNoDefaultKeysButCanBeGivenOne() {
        for command in HistoryCommand.allCases {
            XCTAssertNil(Shortcuts.defaultShortcut(for: .history(command)), "\(command) is menu only")
            XCTAssertTrue(Keymap.commands.contains { $0.command == .history(command) }, "\(command) in Settings › Keyboard")
        }
    }

    // MARK: Overwrite and sync

    func testOverwriteResetsWhatIsNotPasted() {
        var source = EditParameters()
        source.exposureEV = 1
        source.contrast = 1.3
        let pasted = EditorModel.overwriteStack(EditStack(parameters: source), groups: [.tone])
        var target = EditParameters()
        target.vibrance = 0.5
        // Applied to any photo, the result no longer depends on its edit.
        let result = EditStack(parameters: target).merged(with: pasted, groups: Set(EditGroup.allCases)).parameters()
        XCTAssertEqual(result.exposureEV, 1)
        XCTAssertEqual(result.vibrance, EditParameters().vibrance, "the colour group, not pasted, is back at its default")
        XCTAssertEqual(EditorModel.overwriteStack(EditStack(parameters: source), groups: []), EditStack(),
                       "Reset Edits: nothing pasted over the defaults")
    }

    func testSyncWritesOnlyTheChangedGroupsAndLeavesTheLeadAlone() throws {
        var lead = EditParameters()
        lead.exposureEV = 0.8
        lead.vibrance = 0.2
        let leadStack = EditStack(parameters: lead)
        let leadJSON = try leadStack.encodeJSON()
        XCTAssertEqual(try HistoryCommands.synced(leadJSON, from: leadStack, groups: [.tone]), leadJSON,
                       "the lead is in step already, so its stored edit is returned as it was")

        var other = EditParameters()
        other.vibrance = -0.4
        let otherJSON = try EditStack(parameters: other).encodeJSON()
        let synced = try XCTUnwrap(try HistoryCommands.synced(otherJSON, from: leadStack, groups: [.tone]))
        let result = try EditStack.decode(json: synced).parameters()
        XCTAssertEqual(result.exposureEV, 0.8)
        XCTAssertEqual(result.vibrance, -0.4)
        XCTAssertNil(try HistoryCommands.synced(nil, from: EditStack(), groups: [.tone]), "default stays no edit")
    }

    func testTheLastStoredStepIsTheOneIntoTheStoredEdit() {
        var p = EditParameters()
        let s0 = EditStack(parameters: p)
        p.exposureEV = 1
        let s1 = EditStack(parameters: p)
        p.vibrance = 0.3
        let s2 = EditStack(parameters: p)
        XCTAssertEqual(HistoryCommands.lastChangedGroups(steps: [s0, s1, s2], current: s2), [.colour])
        XCTAssertEqual(HistoryCommands.lastChangedGroups(steps: [s0, s1, s2], current: s1), [.tone],
                       "an undone step after it doesn't count")
        XCTAssertEqual(HistoryCommands.lastChangedGroups(steps: [s0], current: s0), [])
    }

    // MARK: Selective sheet

    func testTheSheetRemembersEachPurposesChoice() {
        XCTAssertEqual(SelectiveSettingsMemory.groups(for: .copy, defaults: defaults), EditGroup.lookGroups)
        XCTAssertEqual(SelectiveSettingsMemory.groups(for: .load("a.xmp"), defaults: defaults), Set(EditGroup.allCases))
        SelectiveSettingsMemory.remember([.crop, .tone], for: .paste, defaults: defaults)
        XCTAssertEqual(SelectiveSettingsMemory.groups(for: .paste, defaults: defaults), [.crop, .tone])
        XCTAssertEqual(SelectiveSettingsMemory.groups(for: .copy, defaults: defaults), EditGroup.lookGroups)
        SelectiveSettingsMemory.remember([.lens], for: .load("a.xmp"), defaults: defaults)
        XCTAssertEqual(SelectiveSettingsMemory.groups(for: .load("b.xmp"), defaults: defaults), [.lens],
                       "every file shares one choice")
    }

    // MARK: Settings files

    func testASidecarsEditLoads() throws {
        var p = EditParameters()
        p.exposureEV = -1.5
        let json = try EditStack(parameters: p).encodeJSON()
        let url = directory.appendingPathComponent("DSC_0001.NEF.xmp")
        try XMPSidecar.write(XMPSidecar.Fields(sourceHash: "xxh64:0", editStackJSON: json), to: url)
        XCTAssertEqual(try SettingsFile.editStack(at: url).parameters().exposureEV, -1.5)

        let empty = directory.appendingPathComponent("empty.xmp")
        try XMPSidecar.write(XMPSidecar.Fields(sourceHash: "xxh64:0"), to: empty)
        XCTAssertThrowsError(try SettingsFile.editStack(at: empty)) { error in
            XCTAssertEqual(error as? SettingsFile.Failure, .noSettings)
        }
    }

    func testTheEditIsFoundAnywhereInAnXMPPacket() {
        let element = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"/>
            <rdf:Description rdf:about="" xmlns:latent="https://github.com/Harmanjit/latent-raw/ns/1.0/">
            <latent:EditStack>{"exposure":0.5}</latent:EditStack></rdf:Description></rdf:RDF></x:xmpmeta>
            """
        XCTAssertEqual(SettingsFile.editStackJSON(inXMP: element), #"{"exposure":0.5}"#,
                       "in a second Description, as ImageIO may write it")
        let attribute = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:latent="https://github.com/Harmanjit/latent-raw/ns/1.0/"
             latent:EditStack="{&quot;exposure&quot;:1}"/></rdf:RDF></x:xmpmeta>
            """
        XCTAssertEqual(SettingsFile.editStackJSON(inXMP: attribute), #"{"exposure":1}"#)
        XCTAssertNil(SettingsFile.editStackJSON(inXMP: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>"))
        XCTAssertNil(SettingsFile.editStackJSON(inXMP: "not xml"))
    }

    func testAnImageWithoutLatentsEditSaysSo() throws {
        let url = directory.appendingPathComponent("plain.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        try XCTUnwrap(rep?.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertThrowsError(try SettingsFile.editStack(at: url)) { error in
            XCTAssertEqual(error as? SettingsFile.Failure, .noSettings)
        }
    }
}
