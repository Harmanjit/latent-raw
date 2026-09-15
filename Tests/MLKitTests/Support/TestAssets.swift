import Foundation

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
}
