import XCTest
@testable import Catalog

final class LaunchArgumentsTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!
    nonisolated(unsafe) var file: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-args-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("A.NEF")
        try Data([0]).write(to: file)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testDefaultsOverridesAreSkippedWithTheirValues() {
        let args = ["-AppleLanguages", "(en)", file.path]
        XCTAssertEqual(LaunchArguments.paths(from: args), [file.path])
    }

    func testFoldersAndFilesAreKeptInOrder() {
        let args = [folder.path, "-NSDocumentRevisionsDebugMode", "YES", file.path]
        XCTAssertEqual(LaunchArguments.paths(from: args), [folder.path, file.path])
    }

    func testMissingPathsAndATrailingFlagAreIgnored() {
        let missing = folder.appendingPathComponent("gone.NEF").path
        XCTAssertEqual(LaunchArguments.paths(from: [missing, "(en)", "-verbose"]), [])
        XCTAssertEqual(LaunchArguments.paths(from: []), [])
    }

    /// A defaults value that happens to be an existing path is still a value.
    func testAFlagValueIsNeverTakenForAPath() {
        XCTAssertEqual(LaunchArguments.paths(from: ["-lastFolder", folder.path]), [])
    }

    // MARK: - Launch targets

    func testTargetIsTheFirstExistingPathAsAFolderOrAFile() {
        let missing = folder.appendingPathComponent("gone.NEF").path
        XCTAssertEqual(LaunchArguments.target(forPaths: [missing, file.path, folder.path]),
                       .file(file.standardizedFileURL))
        XCTAssertEqual(LaunchArguments.target(forPaths: [folder.path]),
                       .folder(URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL))
        XCTAssertNil(LaunchArguments.target(forPaths: [missing]))
    }

    func testOpenEventURLsIgnoreAnythingButFiles() {
        let web = URL(string: "https://example.com/A.NEF")!
        XCTAssertEqual(LaunchArguments.target(for: [web, file]), .file(file.standardizedFileURL))
        XCTAssertNil(LaunchArguments.target(for: [web]))
    }

    /// An event that arrived during launch wins over the command line,
    /// which is otherwise used (AppKit sends a command-line path as an
    /// event too, so usually both name the same file).
    func testLaunchTargetPrefersThePendingEvent() {
        let event = LaunchArguments.Target.folder(folder)
        XCTAssertEqual(LaunchArguments.launchTarget(pendingEvent: event, arguments: [file.path]), event)
        XCTAssertEqual(LaunchArguments.launchTarget(pendingEvent: nil, arguments: ["-AppleLanguages", "(en)", file.path]),
                       .file(file.standardizedFileURL))
        XCTAssertNil(LaunchArguments.launchTarget(pendingEvent: nil, arguments: []))
    }
}
