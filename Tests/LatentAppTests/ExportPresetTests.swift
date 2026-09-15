import XCTest
@testable import latent_app

final class ExportPresetTests: XCTestCase {
    /// Presets saved before "Include location" existed were agreed to as
    /// camera metadata, keywords and rating: they must not start writing
    /// where the photo was taken.
    func testOlderPresetsDecodeWithoutLocation() throws {
        let old = Data(#"{"format":"jpeg","includeMetadata":true,"resize":true,"maxLongEdge":2048}"#.utf8)
        let preset = try JSONDecoder().decode(ExportPreset.self, from: old)
        XCTAssertTrue(preset.includeMetadata)
        XCTAssertFalse(preset.includeLocation)
        XCTAssertFalse(ExportPreset().includeLocation)
        XCTAssertTrue(ExportPresetStore.builtIns.allSatisfy { !$0.preset.includeLocation })

        var chosen = ExportPreset()
        chosen.includeLocation = true
        let roundTrip = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(chosen))
        XCTAssertTrue(roundTrip.includeLocation)
    }

    /// Export Open Image's switches: metadata on and location off until the
    /// user changes them, then remembered.
    func testOpenImageExportOptionsDefaultsAndMemory() throws {
        let suite = "latent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(OpenImageExportOptions.load(from: defaults),
                       OpenImageExportOptions(includeMetadata: true, includeLocation: false))
        defaults.set(false, forKey: OpenImageExportOptions.includeMetadataKey)
        defaults.set(true, forKey: OpenImageExportOptions.includeLocationKey)
        XCTAssertEqual(OpenImageExportOptions.load(from: defaults),
                       OpenImageExportOptions(includeMetadata: false, includeLocation: true))
    }
}
