import XCTest
import AppKit
import ColorKit
import PixelEngine
@testable import latent_app

/// The proof target and warning colours remembered between launches, the
/// profiles added to Soft Proof's menu, Before while proofing, and S.
@MainActor
final class SoftProofSettingsTests: XCTestCase {
    static let cmykURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "latent.test.softproofsettings.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSettingsStoreRemembersColoursAndBefore() {
        let store = SoftProofSettingsStore(defaults: defaults)
        XCTAssertEqual(store.warningColours, .standard)
        XCTAssertTrue(store.beforeShowsUnproofed, "on unless turned off")
        store.warningColours = GamutWarningColours(destination: SIMD3(0, 1, 0), monitor: SIMD3(1, 0, 1))
        store.beforeShowsUnproofed = false
        let again = SoftProofSettingsStore(defaults: defaults)
        XCTAssertEqual(again.warningColours.destination, SIMD3(0, 1, 0))
        XCTAssertEqual(again.warningColours.monitor, SIMD3(1, 0, 1))
        XCTAssertFalse(again.beforeShowsUnproofed)
    }

    func testTargetStoreRestoresTheLastTarget() throws {
        let store = SoftProofTargetStore(defaults: defaults)
        XCTAssertEqual(store.restored(), .sRGB, "nothing stored")
        store.save(.displayP3)
        XCTAssertEqual(store.restored(), .displayP3)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        store.save(.icc(Self.cmykURL))
        guard case .icc(let url) = SoftProofTargetStore(defaults: defaults).restored() else {
            return XCTFail("the profile should come back")
        }
        XCTAssertEqual(url.standardizedFileURL.path, Self.cmykURL.path)
        // A profile that has gone falls back to sRGB.
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID()).icc")
        try FileManager.default.copyItem(at: Self.cmykURL, to: gone)
        store.save(.icc(gone))
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(store.restored(), .sRGB)
    }

    func testAddedProfilesAreRememberedAndRemoved() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paper = folder.appendingPathComponent("Glossy Paper.icc")
        try FileManager.default.copyItem(at: Self.cmykURL, to: paper)
        let notAProfile = folder.appendingPathComponent("notes.icc")
        try Data("not a profile".utf8).write(to: notAProfile)

        let library = ProofProfileLibrary(defaults: defaults)
        XCTAssertTrue(library.added.isEmpty)
        XCTAssertFalse(library.add(notAProfile))
        XCTAssertTrue(library.add(paper))
        XCTAssertTrue(library.add(paper), "adding twice keeps one")
        XCTAssertEqual(library.added.map(\.name), ["Glossy Paper"])

        let relaunched = ProofProfileLibrary(defaults: defaults)
        XCTAssertEqual(relaunched.added.map(\.name), ["Glossy Paper"])
        relaunched.remove(relaunched.added[0])
        XCTAssertTrue(relaunched.added.isEmpty)
        XCTAssertTrue(ProofProfileLibrary(defaults: defaults).added.isEmpty)
    }

    func testInstalledProfilesIncludePrinterProfilesButNotTheMenusOwn() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        let names = ProofProfileLibrary.installedProfiles().map(\.name)
        XCTAssertTrue(names.contains("Generic CMYK Profile"))
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("sRGB") })
    }

    func testBeforeWhileProofingShowsTheUnproofedEdit() async throws {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: try TestAssets.d750URL())
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let saved = model.proofBeforeShowsUnproofed
        defer { model.proofBeforeShowsUnproofed = saved }
        model.proofBeforeShowsUnproofed = true
        model.parameters.exposureEV = 0.5
        model.proofEnabled = true
        model.showingBefore = true
        XCTAssertTrue(model.showsUnproofedBefore)
        XCTAssertNil(model.displayOutput.proof, "Before is the edit without the proof")
        XCTAssertEqual(model.displayOutput.headroom, 1, "and still SDR, to compare like with like")
        XCTAssertEqual(model.renderParameters, model.parameters)
        model.proofBeforeShowsUnproofed = false
        XCTAssertNotNil(model.displayOutput.proof)
        XCTAssertNotEqual(model.renderParameters, model.parameters, "Before is the photo before editing")
        model.showingBefore = false
        model.proofBeforeShowsUnproofed = true
        XCTAssertFalse(model.showsUnproofedBefore)
        XCTAssertNotNil(model.displayOutput.proof)
    }

    func testWarningColoursReachTheViewport() async throws {
        _ = try await GPUContext.shared()
        let model = EditorModel()
        let saved = model.gamutWarningColours
        defer { model.gamutWarningColours = saved }
        model.gamutWarningColours.destination = SIMD3(0, 1, 0)
        XCTAssertEqual(model.displayOutput.gamutWarningColours.destination, SIMD3(0, 1, 0))
    }

    func testSoftProofKeyInDevelop() {
        let shortcut = Shortcuts.shortcut(for: .toggleSoftProof)
        XCTAssertEqual(shortcut?.key, .character("s"))
        XCTAssertEqual(shortcut?.scope, .develop)
        var state = CommandState()
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(.toggleSoftProof))
        state.hasImage = true
        XCTAssertTrue(state.isEnabled(.toggleSoftProof))
        state.mode = .library
        XCTAssertFalse(state.isEnabled(.toggleSoftProof))
    }
}
