import XCTest
import PixelEngine
@testable import Catalog
@testable import latent_app

/// The export sheet and its saved presets at the edges: numbers typed far
/// too large clamp instead of trapping, and one unreadable preset never
/// costs the others.
@MainActor
final class ExportRobustnessTests: XCTestCase {
    /// Centimetres or inches typed far too large come to the most pixels a
    /// side may have, not an Int overflow.
    func testHugePhysicalSizesClamp() {
        XCTAssertEqual(ExportSizeUnit.centimetres.pixels(value: 1e20, ppi: 300), 1_000_000)
        XCTAssertEqual(ExportSizeUnit.inches.pixels(value: 1e300, ppi: 9999), 1_000_000)
        XCTAssertEqual(ExportSizeUnit.inches.pixels(value: -1e20, ppi: 300), 1)
        XCTAssertEqual(ExportSizeUnit.inches.pixels(value: 10, ppi: 300), 3000)
    }

    /// A size limit typed far too large gives a byte count, not a trap, and
    /// the preview's total for a batch doesn't overflow either.
    func testHugeSizeLimitDoesNotTrap() throws {
        var preset = ExportPreset()
        preset.sizeLimitEnabled = true
        preset.sizeLimitKB = 10_000_000_000_000_000
        let bytes = try XCTUnwrap(preset.sizeLimitBytes)
        XCTAssertGreaterThan(bytes, 0)
        preset.sizeLimitKB = .max
        XCTAssertNotNil(preset.sizeLimitBytes)
        XCTAssertEqual(ExportSizeEstimate.cappedTotal(1_000, limit: .max, images: 3), 1_000)
        XCTAssertEqual(ExportSizeEstimate.cappedTotal(9_000, limit: 1_000, images: 3), 3_000)
        XCTAssertEqual(ExportSizeEstimate.cappedTotal(9_000, limit: nil, images: 3), 9_000)
        preset.sizeLimitKB = 500
        XCTAssertEqual(preset.sizeLimitBytes, 512_000)
    }

    /// One preset whose format or collision this build doesn't know (one
    /// saved by a newer build, or hand-edited) loads with defaults, and the
    /// rest of the list loads with it.
    func testUnknownFormatKeepsTheWholePresetList() throws {
        var web = ExportPreset(); web.maxLongEdge = 1234
        var tiff = ExportPreset(); tiff.format = .tiff
        let list = [NamedExportPreset(name: "Future", preset: web), NamedExportPreset(name: "Print", preset: tiff)]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [[String: Any]])
        var future = try XCTUnwrap(json[0]["preset"] as? [String: Any])
        future["format"] = "future"
        future["collision"] = "somethingNew"
        json[0]["preset"] = future
        json.append(["not": "a preset"])
        let data = try JSONSerialization.data(withJSONObject: json)

        let key = ExportPresetStore.key
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(data, forKey: key)

        let loaded = ExportPresetStore.load()
        XCTAssertEqual(loaded.map(\.name), ["Future", "Print"])
        XCTAssertEqual(loaded.first?.preset.format, .jpeg)
        XCTAssertEqual(loaded.first?.preset.maxLongEdge, 1234)
        XCTAssertEqual(loaded.first?.preset.collision, ExportPreset().collision)
        XCTAssertEqual(loaded.last?.preset.format, .tiff)
    }

    /// A list that can't be read at all is kept aside before the built-ins
    /// stand in for it, so the next save doesn't destroy it.
    func testUnreadableListIsKeptBeforeItIsReplaced() throws {
        let key = ExportPresetStore.key, backup = ExportPresetStore.unreadableKey
        let saved = UserDefaults.standard.data(forKey: key), savedBackup = UserDefaults.standard.data(forKey: backup)
        defer { UserDefaults.standard.set(saved, forKey: key); UserDefaults.standard.set(savedBackup, forKey: backup) }
        let garbage = Data(#"{"presets": 3}"#.utf8)
        UserDefaults.standard.set(garbage, forKey: key)
        UserDefaults.standard.removeObject(forKey: backup)
        XCTAssertEqual(ExportPresetStore.load().map(\.name), ExportPresetStore.builtIns.map(\.name))
        XCTAssertEqual(UserDefaults.standard.data(forKey: backup), garbage)
    }
}
