import XCTest
@testable import MLKit

/// The denoiser's variant preference. (The dormant download path this
/// file once covered went with docs/Retouch.md §2 A: models come from
/// disk through `ModelImporter`.)
final class DenoisePreferenceTests: XCTestCase {
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
