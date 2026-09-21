import XCTest
@testable import MLKit

/// What is left of the dormant download path (docs/Retouch.md §2 A): the
/// one row the editor still names, and the denoiser's preference.
final class OptionalModelTests: XCTestCase {
    @available(*, deprecated)
    func testCatalogEntryIsWellFormed() {
        let m = OptionalModel.nafnetWidth64
        XCTAssertEqual(m.url.host, "github.com")
        XCTAssertEqual(m.sha256.count, 64)
        XCTAssertTrue(m.installedURL.path.hasSuffix("latent/models/NAFNet_SIDD_width64.mlpackage"))
        XCTAssertEqual(m.installedURL.deletingLastPathComponent(), CoreMLStore.externalModelsDirectory)
    }

    /// Nothing downloads: the app has no network entitlement, and the
    /// call says so instead of trying.
    @available(*, deprecated)
    func testInstallRefuses() async {
        do {
            try await ModelDownloader.install(.nafnetWidth64)
            XCTFail("installed")
        } catch let error as ModelDownloadError {
            XCTAssertTrue(String(describing: error).contains("never downloads"))
        } catch {
            XCTFail("\(error)")
        }
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
