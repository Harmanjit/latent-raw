import XCTest
import PixelEngine
@testable import Catalog
@testable import latent_app

@MainActor
final class ExportExtrasTests: XCTestCase {
    /// Presets saved before the watermark existed export exactly as before.
    func testOlderPresetsHaveNoWatermark() throws {
        let old = Data(#"{"format":"jpeg","quality":0.8,"resize":true,"maxLongEdge":2048}"#.utf8)
        let preset = try JSONDecoder().decode(ExportPreset.self, from: old)
        XCTAssertFalse(preset.watermarkEnabled)
        XCTAssertNil(preset.settings.watermark)
        XCTAssertNil(ExportPreset().settings.watermark)
        XCTAssertTrue(ExportPresetStore.builtIns.allSatisfy { $0.preset.settings.watermark == nil })
        // A broken watermark entry doesn't lose the rest of the preset.
        let broken = Data(#"{"format":"heic","watermarkEnabled":true,"watermark":"nonsense"}"#.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: broken)
        XCTAssertEqual(decoded.format, .heic)
        XCTAssertEqual(decoded.watermark, ExportWatermark())
    }

    func testWatermarkReachesTheSettingsOnlyWhenOnWithText() throws {
        var preset = ExportPreset()
        preset.watermark = ExportWatermark(text: "© {year} Ana", corner: .topLeft)
        XCTAssertNil(preset.settings.watermark, "off keeps the text but stamps nothing")
        preset.watermarkEnabled = true
        XCTAssertEqual(preset.settings.watermark?.corner, .topLeft)
        preset.watermark.text = "   "
        XCTAssertNil(preset.settings.watermark)

        preset.watermark.text = "x"
        let round = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(round, preset)
    }

    /// The queue, the estimate and the comparison share one request builder.
    func testWorkerRequestFollowsThePreset() {
        var preset = ExportPreset()
        preset.resize = true; preset.maxLongEdge = 1600; preset.colorSpaceIsP3 = true
        preset.includeMetadata = false; preset.includeLocation = true; preset.collision = .replace
        preset.watermarkEnabled = true
        let record = ImageRecord(id: 7, relPath: "A/DSC_1.NEF", preservedName: nil, size: 1, mtime: 0,
                                 xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil,
                                 iso: nil, shutter: nil, aperture: nil, focal: nil, width: 6000, height: 4000,
                                 orientation: nil, rating: 4, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil,
                                 userRotation: 3)
        let request = preset.workerRequest(for: record, root: URL(fileURLWithPath: "/cat"),
                                           destination: URL(fileURLWithPath: "/out/x.jpg"),
                                           editStackJSON: "{}", keywords: ["k"])
        XCTAssertEqual(request.sourceURL.path, "/cat/A/DSC_1.NEF")
        XCTAssertEqual(request.maxLongEdge, 1600)
        XCTAssertEqual(request.colorSpace, .displayP3)
        XCTAssertEqual(request.userRotation, 3)
        XCTAssertEqual(request.keywords, [], "no metadata, no keywords")
        XCTAssertEqual(request.rating, 0)
        XCTAssertFalse(request.includeLocation)
        XCTAssertTrue(request.replacesExisting)
        XCTAssertNotNil(request.settings.watermark)
    }

    /// Export Open Image stamps the sheet's watermark only when its own
    /// switch is on.
    func testOpenImageUsesTheSheetsWatermarkWhenSwitchedOn() throws {
        let suite = "latent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preset = ExportPreset()
        preset.watermark = ExportWatermark(text: "© Ana", corner: .topRight, opacity: 0.5)
        defaults.set(try JSONEncoder().encode(preset), forKey: ExportPreset.defaultsKey)
        XCTAssertNil(OpenImageExportOptions.load(from: defaults).watermark)
        defaults.set(true, forKey: OpenImageExportOptions.includeWatermarkKey)
        XCTAssertEqual(OpenImageExportOptions.load(from: defaults).watermark, preset.watermark)
        preset.watermark.text = ""
        defaults.set(try JSONEncoder().encode(preset), forKey: ExportPreset.defaultsKey)
        XCTAssertNil(OpenImageExportOptions.load(from: defaults).watermark)
    }

    func testExportActivityHoldsOffSystemSleepOnly() {
        XCTAssertTrue(ExportActivity.options.contains(.idleSystemSleepDisabled))
        XCTAssertTrue(ExportActivity.options.contains(.userInitiated))
        XCTAssertFalse(ExportActivity.options.contains(.idleDisplaySleepDisabled))
        let activity = ExportActivity(reason: "test")
        XCTAssertTrue(activity.isActive)
        activity.end()
        activity.end()
        XCTAssertFalse(activity.isActive)
    }

    func testEstimateText() {
        XCTAssertTrue(ExportEstimateModel.text(bytes: 12_400_000, images: 1).hasPrefix("About "))
        XCTAssertTrue(ExportEstimateModel.text(bytes: 140_000_000, images: 12).hasSuffix(" for 12 images"))
    }
}
