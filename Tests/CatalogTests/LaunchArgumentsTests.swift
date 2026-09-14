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
}
