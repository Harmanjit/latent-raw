import XCTest
import PixelEngine
import MergeKit
@testable import Catalog
@testable import latent_app

/// The export sheet's new settings as a preset holds them: older presets
/// load unchanged, every option reaches the worker, multi-batch and
/// Export with Previous plan their batches, and originals copy with a sidecar.
@MainActor
final class ExportOutputPresetTests: XCTestCase {
    private func record(_ relPath: String = "A/DSC_1.NEF") -> ImageRecord {
        ImageRecord(id: 7, relPath: relPath, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: 6000, height: 4000, orientation: nil, rating: 4, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    /// A preset saved before these options exists exports exactly as it did.
    func testOlderPresetsKeepTheirBehaviour() throws {
        let old = Data(#"{"format":"tiff","quality":0.8,"resize":true,"maxLongEdge":2048,"colorSpaceIsP3":true}"#.utf8)
        let preset = try JSONDecoder().decode(ExportPreset.self, from: old)
        XCTAssertEqual(preset.fileKind, .image)
        XCTAssertNil(preset.profile)
        XCTAssertEqual(preset.location, .chosenFolder)
        XCTAssertEqual(preset.metadataLevel, .all)
        XCTAssertNil(preset.sizing, "a plain long edge stays a plain long edge")
        let settings = preset.settings
        XCTAssertNil(settings.colorProfile)
        XCTAssertNil(settings.ppi)
        XCTAssertNil(settings.outputSharpening)
        XCTAssertEqual(settings.bitsPerComponent, 16)
        XCTAssertEqual(settings.tiffCompression, .none)
        XCTAssertFalse(settings.enlarges)
        XCTAssertEqual(preset.colorSpaceName, "Display P3")
        let request = preset.workerRequest(for: record(), root: URL(fileURLWithPath: "/cat"),
                                           destination: URL(fileURLWithPath: "/out/x.tif"), editStackJSON: nil,
                                           keywords: [])
        XCTAssertNil(request.sizing)
        XCTAssertNil(request.sizeLimitBytes)
        XCTAssertEqual(request.metadataLevel, .all)
        XCTAssertEqual(request.maxLongEdge, 2048)
    }

    func testEveryNewOptionRoundTripsAndReachesTheWorker() throws {
        var preset = ExportPreset()
        preset.profile = .proPhoto
        preset.ppiEnabled = true; preset.ppi = 360
        preset.resize = true; preset.sizingMode = .megapixels; preset.megapixels = 8; preset.dontEnlarge = false
        preset.sharpenEnabled = true; preset.sharpenMedium = .glossy; preset.sharpenStrength = .low
        preset.sizeLimitEnabled = true; preset.sizeLimitKB = 300
        preset.format = .jpeg
        preset.location = .sameAsOriginal; preset.subfolder = "Lab"
        preset.metadataLevel = .copyrightAndContact
        preset.openInApp = true; preset.openInAppPath = "/Applications/Preview.app"
        preset.watermark.style = .graphic; preset.watermark.rotation = 90
        let back = try JSONDecoder().decode(ExportPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(back, preset)

        let settings = preset.settings
        XCTAssertEqual(settings.colorProfile, .proPhoto)
        XCTAssertEqual(settings.ppi, 360)
        XCTAssertEqual(settings.outputSharpening, OutputSharpening(medium: .glossy, strength: .low))
        XCTAssertEqual(preset.colorSpaceName, "ProPhoto RGB")
        let request = preset.workerRequest(for: record(), root: URL(fileURLWithPath: "/cat"),
                                           destination: URL(fileURLWithPath: "/out/x.jpg"), editStackJSON: nil,
                                           keywords: ["k"])
        XCTAssertEqual(request.sizing?.mode, .megapixels)
        XCTAssertEqual(request.sizing?.dontEnlarge, false)
        XCTAssertEqual(request.sizeLimitBytes, 300 * 1024)
        XCTAssertEqual(request.metadataLevel, .copyrightAndContact)
        let options = preset.planOptions(catalogName: "Shoot")
        XCTAssertTrue(options.originalFolders)
        XCTAssertEqual(options.subfolder, "Lab")
        // The size limit is for formats with a quality to lower.
        preset.format = .png
        XCTAssertNil(preset.sizeLimitBytes)
    }

    func testDNGAndOriginalExportsNameTheirFiles() {
        var preset = ExportPreset()
        preset.fileKind = .dng
        XCTAssertEqual(preset.fileExtension, "dng")
        XCTAssertFalse(preset.rendersImage)
        preset.fileKind = .original
        XCTAssertTrue(preset.planOptions(catalogName: "").keepsOriginalExtension)
        XCTAssertEqual(ExportFileJob.sidecarURL(for: URL(fileURLWithPath: "/out/DSC_1.NEF")).path, "/out/DSC_1.xmp")
    }

    /// An ICC profile that can't be read fails the export rather than
    /// quietly writing sRGB.
    func testAnUnreadableProfileIsNotQuietlySRGB() {
        var preset = ExportPreset()
        preset.profile = ExportProfileChoice(kind: .icc, name: "Gone", path: "/nowhere/gone.icc")
        let profile = preset.settings.colorProfile
        XCTAssertEqual(profile?.kind, .icc)
        XCTAssertNil(profile?.cgColorSpace)
    }

    func testMultiBatchPlansAFolderPerPreset() throws {
        var web = ExportPreset(); web.location = .chosenFolder
        var lab = ExportPreset(); lab.location = .chooseLater
        var beside = ExportPreset(); beside.location = .sameAsOriginal
        let presets = [NamedExportPreset(name: "Web: 2048", preset: web),
                       NamedExportPreset(name: "Lab", preset: lab),
                       NamedExportPreset(name: "Beside", preset: beside)]
        let all = Set(presets.map(\.id))
        let out = URL(fileURLWithPath: "/out", isDirectory: true)
        var asked: [String] = []
        let batches = try XCTUnwrap(ExportMultiBatchSection.batches(for: presets, chosen: all, destination: out) {
            asked.append($0); return URL(fileURLWithPath: "/lab")
        })
        XCTAssertEqual(batches.map(\.destination.path), ["/out/Web- 2048", "/lab", "/out"])
        XCTAssertEqual(batches.map(\.name), ["Web: 2048", "Lab", "Beside"])
        XCTAssertEqual(asked, ["Lab"])
        XCTAssertNil(ExportMultiBatchSection.batches(for: presets, chosen: all, destination: nil) { _ in URL(fileURLWithPath: "/x") },
                     "a chosen-folder preset with no folder")
        XCTAssertNil(ExportMultiBatchSection.batches(for: presets, chosen: all, destination: out) { _ in nil },
                     "a cancelled Choose later stops the run")
    }

    func testExportWithPreviousRemembersTheBatches() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "latent.test.\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory
        var later = ExportPreset(); later.location = .chooseLater; later.quality = 0.5
        ExportPrevious.save([ExportBatch(preset: ExportPreset(), destination: folder, name: nil),
                             ExportBatch(preset: later, destination: folder, name: "Later")], defaults: defaults)
        let loaded = ExportPrevious.load(defaults: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].folder?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertNil(loaded[1].folder, "Choose later asks again")
        XCTAssertEqual(loaded[1].preset.quality, 0.5)
        XCTAssertEqual(loaded[1].name, "Later")
    }

    func testOriginalIsCopiedWithItsSidecar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-orig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("DSC_1.NEF")
        try Data("raw bytes".utf8).write(to: source)
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let target = out.appendingPathComponent("DSC_1.NEF")
        let fields = XMPSidecar.Fields(rating: 4, label: "Red", keywords: ["kept"], sourceHash: "xxh64:00",
                                       editStackJSON: #"{"exposure":1}"#)
        try ExportFileJob.copyOriginal(source, to: target, sidecar: fields, replacingExisting: false)
        XCTAssertEqual(try Data(contentsOf: target), Data("raw bytes".utf8))
        let sidecar = try XMPSidecar.read(from: out.appendingPathComponent("DSC_1.xmp"))
        XCTAssertEqual(sidecar.rating, 4)
        XCTAssertEqual(sidecar.keywords, ["kept"])
        XCTAssertEqual(sidecar.editStackJSON, #"{"exposure":1}"#)
        // Never replaces unless asked.
        XCTAssertThrowsError(try ExportFileJob.copyOriginal(source, to: target, sidecar: nil, replacingExisting: false))
    }

    func testExportWithPreviousHasLightroomsKey() throws {
        let shortcut = try XCTUnwrap(Shortcuts.shortcut(for: .exportWithPrevious))
        XCTAssertEqual(shortcut.glyphs, "⌥⇧⌘E")
    }
}
