import XCTest
@testable import latent_app
import MLKit

/// HDR Output's Maximize Compatibility and the DNG contents in saved
/// presets: older presets keep doing what they did.
final class ExportHDRAndDNGPresetTests: XCTestCase {
    func testOlderPresetsKeepAGainMapAndSceneReferredDNG() throws {
        let old = Data(#"{"format":"heic","hdrGainMap":true,"fileKind":"image"}"#.utf8)
        let preset = try JSONDecoder().decode(ExportPreset.self, from: old)
        XCTAssertTrue(preset.hdrMaximizeCompatibility)
        XCTAssertEqual(preset.dngContent, .sceneReferred)
        XCTAssertTrue(preset.settings.writesGainMap)
        XCTAssertFalse(preset.settings.writesFullHDR)

        var chosen = preset
        chosen.hdrMaximizeCompatibility = false
        chosen.dngContent = .fullLook
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(chosen))
        XCTAssertFalse(back.hdrMaximizeCompatibility)
        XCTAssertEqual(back.dngContent, .fullLook)
        XCTAssertTrue(back.settings.writesFullHDR)
        XCTAssertFalse(back.settings.writesGainMap)
    }

    func testOriginalAsDNGCopiesOnlyDNGs() {
        XCTAssertTrue(DNGExportContent.isDNG(URL(fileURLWithPath: "/a/IMG_1.DNG")))
        XCTAssertFalse(DNGExportContent.isDNG(URL(fileURLWithPath: "/a/DSC_0107.NEF")))
    }
}
