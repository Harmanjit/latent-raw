import XCTest
import AppKit
import ColorKit
import PixelEngine
import MLKit
@testable import latent_app

/// Soft proof options, the monitor gamut warning, proof copies, HDR Limit
/// in the editor, and the rendering intent prints are converted with.
@MainActor
final class SoftProofAppTests: XCTestCase {
    static let cmykURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")

    private func openModel(catalogImageID: Int64? = nil, editStackJSON: String? = nil) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: catalogImageID, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    // MARK: - Proofing

    func testOptionsStoreRemembersAndToleratesNothingStored() throws {
        let suite = "latent.test.softproof.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SoftProofOptionsStore(defaults: defaults)
        XCTAssertEqual(store.options, SoftProofOptions())
        store.options = SoftProofOptions(intent: .relativeColorimetric, simulatePaperAndInk: true)
        XCTAssertEqual(SoftProofOptionsStore(defaults: defaults).options.intent, .relativeColorimetric)
        XCTAssertTrue(SoftProofOptionsStore(defaults: defaults).options.simulatePaperAndInk)
    }

    func testWarningsReachTheViewportOnlyWhileProofing() async throws {
        let model = try await openModel()
        model.monitorGamutWarning = true
        XCTAssertNotNil(model.monitorGamutLUT)
        XCTAssertNil(model.displayOutput.proof)
        model.proofEnabled = true
        XCTAssertNotNil(model.displayOutput.proof)
        XCTAssertNotNil(model.displayOutput.monitorGamut)
        XCTAssertEqual(model.displayOutput.headroom, 1, "proofing is SDR")
        model.monitorGamutWarning = false
        XCTAssertNil(model.displayOutput.monitorGamut)
        XCTAssertNil(model.monitorGamutLUT)
        // A screen's profile becomes a target of its own.
        if let screen = NSScreen.main, screen.colorSpace?.cgColorSpace?.copyICCData() != nil {
            XCTAssertTrue(EditorModel.monitorTarget(screen: screen).isICC)
        }
        XCTAssertEqual(EditorModel.monitorTarget(screen: nil), .displayP3)
    }

    func testIntentChangeRebuildsTheProof() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        let model = try await openModel()
        let saved = model.proofOptions
        defer { model.proofOptions = saved }
        model.proofTarget = .icc(Self.cmykURL)
        model.proofEnabled = true
        let first = try XCTUnwrap(model.proofLUT)
        model.proofOptions.simulatePaperAndInk = !saved.simulatePaperAndInk
        let second = try XCTUnwrap(model.proofLUT)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.options.simulatePaperAndInk, !saved.simulatePaperAndInk)
    }

    func testProofCopyIsANamedSnapshotOfTheEdit() async throws {
        let model = try await openModel()
        model.createProofCopy()
        XCTAssertTrue(model.snapshots.isEmpty, "only while proofing")
        model.proofEnabled = true
        model.parameters.exposureEV = 0.6
        XCTAssertFalse(model.hasProofCopy)
        model.createProofCopy()
        XCTAssertEqual(model.snapshots.map(\.name), ["Proof — sRGB"])
        XCTAssertTrue(model.hasProofCopy)
        XCTAssertEqual(model.snapshots.first?.stack.parameters().exposureEV, 0.6)
        // Again for the same target: replaced, not duplicated.
        model.parameters.exposureEV = 0.2
        model.createProofCopy()
        XCTAssertEqual(model.snapshots.count, 1)
        XCTAssertEqual(model.snapshots.first?.stack.parameters().exposureEV, 0.2)
        model.proofTarget = .displayP3
        XCTAssertFalse(model.hasProofCopy)
    }

    // MARK: - HDR Limit

    func testHDRLimitIsAnUndoableEditThatSurvivesReopening() async throws {
        let model = try await openModel(catalogImageID: 1)
        model.displayHeadroomDidChange(to: 16)
        model.hdrDisplayEnabled = true
        XCTAssertEqual(model.displayOutput.headroom, 4)
        model.parameters.hdrLimitStops = 1
        XCTAssertEqual(model.displayOutput.headroom, 2)
        model.flushPendingSave()
        XCTAssertEqual(model.history.steps.last?.label, "HDR Limit")
        let json = try EditStack(parameters: model.parameters).encodeJSON()
        model.undo()
        XCTAssertEqual(model.parameters.hdrLimitStops, HDRLimit.defaultStops)
        model.redo()
        XCTAssertEqual(model.parameters.hdrLimitStops, 1)

        let reopened = try await openModel(editStackJSON: json)
        XCTAssertEqual(reopened.parameters.hdrLimitStops, 1)
    }

    // MARK: - Printing

    func testPrintSettingsCarryTheIntentIntoTheProfile() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        // Settings stored before the intent existed read as perceptual.
        let old = #"{"imagesPerPage":2,"color":"proofProfile"}"#
        let decoded = try JSONDecoder().decode(PrintLayoutSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.intent, .perceptual)
        XCTAssertEqual(decoded.imagesPerPage, 2)

        let proof = try XCTUnwrap(SheetProfile(url: Self.cmykURL))
        var settings = PrintLayoutSettings()
        settings.intent = .relativeColorimetric
        XCTAssertEqual(settings.profile(proof: proof)?.intent, .relativeColorimetric)
        XCTAssertFalse(try XCTUnwrap(settings.profile(proof: proof)).rendersLike(proof), "another intent renders differently")
        settings.color = .displayP3
        XCTAssertNil(settings.profile(proof: proof))
        let back = try JSONDecoder().decode(PrintLayoutSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.intent, .relativeColorimetric)

        var summary = PrintAccessoryController.summary(PrintLayoutSettings(), proofProfileName: "Paper")
        XCTAssertEqual(summary.last?.name, "Rendering Intent")
        XCTAssertEqual(summary.last?.value, "Perceptual")
        summary = PrintAccessoryController.summary(PrintLayoutSettings(), proofProfileName: nil)
        XCTAssertEqual(summary.last?.name, "Colour")
    }

    func testAPrintStartsFromTheProofsIntent() throws {
        let suite = "latent.test.printintent.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = PrintSession(items: FakeRenders.items(["red"]), thumbnails: FakeRenders.thumbnails,
                                   makeRenderer: { _ in FakeRenders().renderer() }, previewRenderer: nil,
                                   proofProfile: nil, intent: .relativeColorimetric,
                                   store: PrintLayoutStore(defaults: defaults), printInfo: NSPrintInfo(),
                                   jobs: OutputJobs())
        XCTAssertEqual(session.job.currentSettings.intent, .relativeColorimetric)
        session.finish(success: false)
    }

    func testSheetConversionUsesTheIntent() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.cmykURL.path))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        var pixels: [UInt8] = [20, 20, 20, 255, 240, 30, 30, 255]
        let image = try XCTUnwrap(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
        let profile = try XCTUnwrap(SheetProfile(url: Self.cmykURL))
        let a = try XCTUnwrap(SheetColorConversion.convert(image, to: profile.colorSpace, intent: .perceptual))
        let b = try XCTUnwrap(SheetColorConversion.convert(image, to: profile.colorSpace, intent: .relativeColorimetric))
        XCTAssertEqual(a.colorSpace?.model, .cmyk)
        XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
    }
}
