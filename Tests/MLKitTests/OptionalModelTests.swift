import XCTest
@testable import MLKit

final class OptionalModelTests: XCTestCase {
    func testCatalogEntryIsWellFormed() {
        let m = OptionalModel.nafnetWidth64
        XCTAssertEqual(m.url.host, "github.com")
        XCTAssertEqual(m.sha256.count, 64)
        XCTAssertTrue(m.installedURL.path.hasSuffix("latent/models/NAFNet_SIDD_width64.mlpackage"))
        XCTAssertEqual(m.installedURL.deletingLastPathComponent(), CoreMLStore.externalModelsDirectory)
    }

    /// Unpacking replaces an existing copy and lands the package where the
    /// store looks for it. Uses a throwaway package zipped with ditto.
    func testUnzipInstallsAndReplaces() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("latent-model-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src/Fake.mlpackage")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "new".write(to: src.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let zip = root.appendingPathComponent("Fake.mlpackage.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let dest = root.appendingPathComponent("models")
        let target = dest.appendingPathComponent("Fake.mlpackage")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        try ModelDownloader.unzip(zip, into: dest, replacing: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8), "new")
    }

    /// The preference falls back to the bundled model when the chosen one
    /// isn't installed, so a stale setting can never break denoising.
    func testPreferredVariantFallsBack() {
        let key = AIDenoiser.preferenceKey
        let before = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.set("high", forKey: key)
        let v = AIDenoiser.preferredVariant
        XCTAssertEqual(v, AIDenoiser.Variant.high.isAvailable ? .high : .standard)
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(AIDenoiser.preferredVariant, .standard)
    }
}
