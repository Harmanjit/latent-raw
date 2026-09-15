import Foundation
import XCTest

/// Where tests find their sample files: the repo's TestAssets folder (see
/// TestAssets/README.md). Test targets can't share source files, so each
/// target that reads sample files has its own copy of this one; keep them
/// the same.
///
/// CI has one file there, the public-domain raw that
/// scripts/fetch_test_assets.sh downloads. Setting LATENT_CI_ASSETS_ONLY=1
/// hides every other file, so a local run skips what CI skips:
///
///     LATENT_CI_ASSETS_ONLY=1 swift test
enum TestAssets {
    /// The public-domain Nikon D750 raw, the one file CI has.
    static let goldenName = "golden_nikon_d750_cc0.nef"
    /// Harman's own D750 raw, which most tests were first written against.
    static let privateSampleName = "nikon_d750_sample.nef"

    static var folder: URL {
        URL(fileURLWithPath: #filePath)   // Tests/<target>/Support/TestAssets.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets", isDirectory: true)
    }

    /// True when the run should see only what CI has.
    static var ciAssetsOnly: Bool {
        ProcessInfo.processInfo.environment["LATENT_CI_ASSETS_ONLY"] == "1"
    }

    /// The file's path. With LATENT_CI_ASSETS_ONLY=1, any name but the
    /// golden raw's gets a path in a folder that doesn't exist, so the
    /// test's own "is it there?" check says no.
    static func url(_ name: String) -> URL {
        guard ciAssetsOnly, name != goldenName else { return folder.appendingPathComponent(name) }
        return folder.appendingPathComponent("hidden-by-LATENT_CI_ASSETS_ONLY", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func path(_ name: String) -> String { url(name).path }

    /// A Nikon D750 raw, for a test that needs a real one but not a
    /// particular one: the private sample when it's there, else the golden
    /// raw, so the test runs on CI too. Its assertions must hold for both
    /// files. Skips when neither is there.
    static func d750URL() throws -> URL {
        for name in [privateSampleName, goldenName] where FileManager.default.fileExists(atPath: path(name)) {
            return url(name)
        }
        throw XCTSkip("No D750 raw in TestAssets/: run scripts/fetch_test_assets.sh")
    }

    static func d750Path() throws -> String { try d750URL().path }

    /// Copies the D750 raw to `destination`. A catalog knows a file by the
    /// hash of its bytes, so copies of one raw are the same image to it;
    /// a nonzero `variant` appends a few bytes after the raw's own data
    /// (which readers never look at) to make a copy a different image.
    static func copyD750(to destination: URL, variant: Int = 0) throws {
        try FileManager.default.copyItem(at: try d750URL(), to: destination)
        guard variant != 0 else { return }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("latent test variant \(variant)".utf8))
    }
}
