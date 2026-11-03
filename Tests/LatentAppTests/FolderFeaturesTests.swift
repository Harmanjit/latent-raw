import XCTest
import Catalog
import PixelEngine
@testable import latent_app

/// Refresh Folder, Add Parent Folder and the watched-folder import.
@MainActor
final class FolderFeaturesTests: XCTestCase {
    // MARK: Refresh Folder

    func testRefreshTakesCommandRAndNeedsAFolder() {
        let shortcut = Shortcuts.shortcut(for: .refreshFolder)
        XCTAssertEqual(shortcut?.glyphs, "⌘R")
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.refreshFolder))
        state.hasFolder = true
        XCTAssertTrue(state.isEnabled(.refreshFolder))
        state.mode = .develop
        XCTAssertTrue(state.isEnabled(.refreshFolder), "in every view")
    }

    // MARK: Add Parent Folder

    private func favourite(_ path: String) -> FavouriteFolder {
        FavouriteFolder(url: URL(fileURLWithPath: path, isDirectory: true), bookmark: Data(), isAvailable: true)
    }

    func testAParentTakesThePlaceOfTheFavouritesInsideIt() {
        let list = [favourite("/Photos/2025"), favourite("/Work"), favourite("/Photos/2026/March")]
        let result = FavouriteFolders.adoptingParent(favourite("/Photos"), in: list)
        XCTAssertEqual(result.map(\.url.path), ["/Photos", "/Work"])
    }

    func testAParentHoldingNoFavouriteIsAddedAtTheEnd() {
        let list = [favourite("/Photos/2025"), favourite("/Work")]
        XCTAssertEqual(FavouriteFolders.adoptingParent(favourite("/Archive"), in: list).map(\.url.path),
                       ["/Photos/2025", "/Work", "/Archive"])
        XCTAssertEqual(FavouriteFolders.adoptingParent(favourite("/Work"), in: list).map(\.url.path),
                       ["/Photos/2025", "/Work"], "already a favourite")
        XCTAssertEqual(FavouriteFolders.adoptingParent(favourite("/Phot"), in: list).count, 3,
                       "/Phot is not the parent of /Photos/2025")
    }

    // MARK: Auto Import

    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-autoimport-app-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Incoming", isDirectory: true)
        destination = root.appendingPathComponent("Shoot", isDirectory: true)
        for folder in [source!, destination!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        suite = "latent-autoimport-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        defaults?.removePersistentDomain(forName: suite)
    }

    private func controller() -> AutoImportController {
        let controller = AutoImportController(defaults: defaults, settle: .milliseconds(50))
        controller.presets = { [Preset(name: "Bright", groups: [.tone], stack: EditStack(parameters: {
            var p = EditParameters(); p.exposureEV = 0.7; return p
        }()))] }
        return controller
    }

    private func drop(_ name: String) throws {
        try Data("raw bytes of \(name)".utf8).write(to: source.appendingPathComponent(name))
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != Catalog.containerName }.sorted()
    }

    func testMovingEmptiesTheWatchedFolderAndAppliesThePreset() async throws {
        try drop("A.NEF")
        try drop("B.CR3")
        try drop("notes.txt")
        let auto = controller()
        auto.mode = .move
        auto.presetName = "Bright"
        auto.setFoldersForTesting(source: source, destination: destination, library: nil)
        auto.isEnabled = true
        await auto.waitForRound()
        XCTAssertEqual(names(in: destination), ["A.NEF", "B.CR3"])
        XCTAssertEqual(names(in: source), ["notes.txt"], "only raw files are imported")
        let sidecar = destination.appendingPathComponent("_latent/xmp/A.NEF.xmp")
        let fields = try XMPSidecar.read(from: sidecar)
        let stack = try EditStack.decode(json: fields.editStackJSON)
        XCTAssertEqual(stack.parameters().exposureEV, 0.7, accuracy: 1e-6)
        XCTAssertTrue(auto.status.hasPrefix("Imported 2 photos"), auto.status)
    }

    func testCopyingImportsEachPhotoOnce() async throws {
        try drop("A.NEF")
        let auto = controller()
        auto.mode = .copy
        auto.setFoldersForTesting(source: source, destination: destination, library: nil)
        auto.isEnabled = true
        await auto.waitForRound()
        XCTAssertEqual(names(in: destination), ["A.NEF"])
        XCTAssertEqual(names(in: source), ["A.NEF"], "the original stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("_latent/xmp/A.NEF.xmp").path),
                       "no preset, no sidecar")

        auto.importWaiting()
        await auto.waitForRound()
        XCTAssertEqual(names(in: destination), ["A.NEF"], "not copied again")

        try drop("B.NEF")
        auto.importWaiting()
        await auto.waitForRound()
        XCTAssertEqual(names(in: destination), ["A.NEF", "B.NEF"])
    }

    func testNothingHappensWhileOffOrWhenTheFoldersOverlap() async throws {
        try drop("A.NEF")
        let auto = controller()
        auto.setFoldersForTesting(source: source, destination: destination, library: nil)
        await auto.waitForRound()
        XCTAssertEqual(names(in: source), ["A.NEF"], "off by default")
        XCTAssertEqual(auto.status, "Off.")

        auto.setFoldersForTesting(source: source, destination: source.appendingPathComponent("Sub"), library: nil)
        auto.isEnabled = true
        await auto.waitForRound()
        XCTAssertEqual(names(in: source), ["A.NEF"])
        XCTAssertEqual(auto.status, "The destination is inside the watched folder.")
    }

    func testAMissingPresetIsReportedAndThePhotoStillImported() async throws {
        try drop("A.NEF")
        let auto = controller()
        auto.presetName = "Gone"
        auto.setFoldersForTesting(source: source, destination: destination, library: nil)
        auto.isEnabled = true
        await auto.waitForRound()
        XCTAssertEqual(names(in: destination), ["A.NEF"])
        XCTAssertTrue(auto.status.contains("no longer exists"), auto.status)
    }
}
