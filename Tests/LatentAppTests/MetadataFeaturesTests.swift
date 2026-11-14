import XCTest
@testable import Catalog
import PixelEngine
@testable import latent_app

/// Metadata presets, the info line under the image, tokens in the
/// watermark, the More fields in exports and the import command's enabling.
@MainActor
final class MetadataFeaturesTests: XCTestCase {
    private func record() -> ImageRecord {
        var r = ImageRecord(id: 1, relPath: "DSC_0042.NEF", preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                            xxhash: Data(count: 8), captureTime: 1_789_321_260, camera: "Nikon D750",
                            lens: "24-70mm f/2.8", lensId: nil, iso: 400, shutter: 0.004, aperture: 2.8, focal: 50,
                            width: 6016, height: 4016, orientation: nil, rating: 3, label: nil, flag: 0,
                            sidecarMtime: nil, thumbKey: nil)
        r.title = "Dusk"
        return r
    }

    func testPresetsKeepOnlySharedFieldsAndRoundTrip() throws {
        var a = record(), b = record()
        a.creator = "Ann"; b.creator = "Ann"
        a.city = "Oslo"; b.city = "Bergen"
        let values = MetadataPreset.values(sharedBy: [a, b])
        XCTAssertEqual(values, [.title: "Dusk", .creator: "Ann"], "Oslo/Bergen differ, so the city is left out")

        let suite = "MetadataFeaturesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        MetadataPresetStore.save([MetadataPreset(name: "Me", values: values)], to: defaults)
        let loaded = MetadataPresetStore.load(from: defaults)
        XCTAssertEqual(loaded.map(\.name), ["Me"])
        XCTAssertEqual(loaded.first?.fields, values)
        // A field from a later build is ignored, not fatal.
        var future = loaded[0]
        future.values["notAField"] = "x"
        XCTAssertEqual(future.fields, values)
    }

    func testCaptionTemplateDefaultIsTheStandardCaption() {
        XCTAssertTrue(ImageCaptionTemplate.isStandard(ImageCaptionTemplate.defaultTemplate))
        XCTAssertTrue(ImageCaptionTemplate.isStandard(""))
        XCTAssertFalse(ImageCaptionTemplate.isStandard("{title}"))
        XCTAssertEqual(ImageCaptionTemplate.text("{file} · {exposure} · {title:upper} · {city|no place}", for: record()),
                       "DSC_0042.NEF · 1/250 s · ƒ/2.8 · ISO 400 · 50 mm · DUSK · no place")
        XCTAssertEqual(ImageCaptionTemplate.unknownTokens(in: "{file}{exposure}{lens}{nope}"), ["{nope}"])
    }

    func testWatermarkTokensAreFilledPerPhotoAndYearAndNameStayForTheWorker() {
        var mark = ExportWatermark(text: "© {year} {creator|Me} · {name} · {lens} · {iso}")
        var r = record()
        r.creator = "Ann"
        let filled = ExportPreset.watermark(mark, filledFor: r, keywords: [], catalogName: "Shoot")
        XCTAssertEqual(filled.text, "© {year} Ann · {name} · 24-70mm f/2.8 · 400")
        let resolved = filled.resolved(fileName: "DSC_0042", captureDate: Date(timeIntervalSince1970: 1_789_321_260),
                                       timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(resolved.text, "© 2026 Ann · DSC_0042 · 24-70mm f/2.8 · 400")
        // Plain text, and a graphic, are left exactly as they were.
        mark.text = "© 2026 Ann"
        XCTAssertEqual(ExportPreset.watermark(mark, filledFor: r, keywords: [], catalogName: ""), mark)
    }

    func testMoreFieldsGoIntoTheExportDescriptionAndFollowTheLevels() {
        var r = record()
        r.city = "Oslo"; r.headline = "Fjord"; r.creatorEmail = "ann@example.com"
        let description = r.exportDescription
        XCTAssertEqual(description.more.city, "Oslo")
        XCTAssertEqual(description.more.headline, "Fjord")
        XCTAssertFalse(description.isEmpty)
        XCTAssertEqual(description.limited(to: .copyrightAndContact).more,
                       ExportDescription.More(creatorEmail: "ann@example.com"))
        XCTAssertTrue(description.limited(to: .copyrightOnly).more.isEmpty)
        XCTAssertNil(description.withoutPlaces.more.city)
        XCTAssertEqual(description.withoutPlaces.more.headline, "Fjord")
        // A photo with none of them exports exactly as before.
        XCTAssertTrue(ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
            .exportDescription.isEmpty)
    }

    func testImportCommandNeedsAFolderWithPhotosInTheGrid() {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.importForeignSidecars))
        state.hasFolder = true
        state.mode = .library
        state.hasVisibleImages = true
        XCTAssertTrue(state.isEnabled(.importForeignSidecars))
        state.mode = .develop
        XCTAssertFalse(state.isEnabled(.importForeignSidecars))
        XCTAssertEqual(ForeignSidecarImportCommand.message(changed: 0, of: 1),
                       "No other app’s sidecar had anything to add to the photo")
        XCTAssertEqual(ForeignSidecarImportCommand.message(changed: 3, of: 9), "Filled in 3 photos from other apps’ sidecars")
    }

    func testExportPresetCopiesMetadataByDefaultAndRemembersIt() throws {
        XCTAssertTrue(ExportPreset().copyMetadataToCatalog)
        let old = try JSONDecoder().decode(ExportPreset.self, from: Data("{}".utf8))
        XCTAssertTrue(old.copyMetadataToCatalog, "presets saved before the switch copy")
        var preset = ExportPreset()
        preset.copyMetadataToCatalog = false
        preset.addToCatalog = true
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertFalse(back.copyMetadataToCatalog)
        let file = back.exportedFile(URL(fileURLWithPath: "/tmp/x.jpg"), from: record())
        XCTAssertEqual(file?.copiesMetadata, false)
    }
}
