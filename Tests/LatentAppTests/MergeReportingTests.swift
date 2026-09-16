import XCTest
import Foundation
import MergeKit
@testable import latent_app

/// What Photo Merge tells the user once the merge is over: failures in
/// sentences, a merged photo's recipe in the panel, and a running job's
/// progress where a folded-away section can't hide it.
@MainActor
final class MergeReportingTests: XCTestCase {
    // MARK: - Errors in sentences

    /// The file system's errors are `POSIXError` and `CocoaError`, bridged
    /// from `NSError`. Describing one prints its domain and code; the status
    /// bar must show the sentence instead.
    func testFileSystemErrorsAreSentences() {
        for error in [POSIXError(.ENOSPC), POSIXError(.EACCES), POSIXError(.EIO)] {
            let said = PhotoMergeQueue.describe(error)
            XCTAssertFalse(said.contains("Domain="), said)
            XCTAssertFalse(said.contains("Code="), said)
            XCTAssertFalse(said.isEmpty)
        }
        let full = PhotoMergeQueue.describe(POSIXError(.ENOSPC))
        XCTAssertTrue(full.lowercased().contains("no space left on device"), full)
        let noPermission = PhotoMergeQueue.describe(CocoaError(.fileWriteNoPermission))
        XCTAssertFalse(noPermission.contains("NSCocoaErrorDomain"), noPermission)
        XCTAssertTrue(noPermission.lowercased().contains("permission"), noPermission)
        let outOfSpace = PhotoMergeQueue.describe(CocoaError(.fileWriteOutOfSpace))
        XCTAssertFalse(outOfSpace.contains("Code=640"), outOfSpace)
    }

    /// Our own errors still say what they always said.
    func testOurOwnErrorsKeepTheirWords() {
        struct Localised: Error, LocalizedError { var errorDescription: String? { "the folder went away" } }
        struct Described: Error, CustomStringConvertible { var description: String { "tile 4 is short" } }
        XCTAssertEqual(PhotoMergeQueue.describe(Localised()), "the folder went away")
        XCTAssertEqual(PhotoMergeQueue.describe(Described()), "tile 4 is short")
        XCTAssertEqual(PhotoMergeQueue.describe(PanoramaError.tooFewPhotos),
                       PanoramaError.tooFewPhotos.errorDescription)
    }

    /// The test `describe` leans on: Foundation's made-up description for a
    /// Swift error names the type, a real one doesn't.
    func testAMadeUpDescriptionIsRecognised() {
        enum Plain: Error { case bad }
        XCTAssertTrue(PhotoMergeQueue.saysNothing(Plain.bad as NSError))
        XCTAssertFalse(PhotoMergeQueue.saysNothing(POSIXError(.ENOSPC) as NSError))
        XCTAssertFalse(PhotoMergeQueue.saysNothing(CocoaError(.fileWriteOutOfSpace) as NSError))
    }

    // MARK: - The first edit's name

    /// Only the options that are on are named: a message that names Auto
    /// Settings when it was switched off sends the user looking for a
    /// setting that was never applied.
    func testTheFirstEditIsNamedFromTheOptions() {
        func name(crop: Bool, settings: Bool) -> String {
            PhotoMergeQueue.panoramaFirstEditName(
                PanoramaMergeOptions(projection: .automatic, autoCrop: crop, autoSettings: settings))
        }
        XCTAssertEqual(name(crop: true, settings: true), "Auto Crop and Auto Settings")
        XCTAssertEqual(name(crop: true, settings: false), "Auto Crop")
        XCTAssertEqual(name(crop: false, settings: true), "Auto Settings")
    }

    // MARK: - A merged photo's recipe

    private func recipe(kind: MergeRecipe.Kind, options: [String: JSONValue], names: [String]) -> MergeRecipe {
        MergeRecipe(kind: kind, clipLevel: 1, lensApplied: true, reference: 0, options: options,
                    sources: names.map { MergeRecipe.Source(path: $0, hash: "00", captureTime: 0) })
    }

    /// "Why was this photo left out" is answerable a day later: the panel
    /// reads the recipe the merge stored.
    func testAnHDRRecipeSaysWhatWentInAndWhatDidNot() {
        let summary = MergeRecipeSummary(recipe(kind: .hdr,
                                                options: ["deghost": .string("medium"), "autoAlign": .bool(true),
                                                          "leftOut": .array([.number(2)])],
                                                names: ["DSC_0106.NEF", "DSC_0107.NEF", "DSC_0108.NEF"]))
        XCTAssertEqual(summary.rows.map(\.label), ["Merged", "From 3", "Left out", "Deghost", "Auto Align"])
        XCTAssertEqual(summary.rows.map(\.value),
                       ["HDR", "DSC_0106.NEF, DSC_0107.NEF, DSC_0108.NEF", "DSC_0108.NEF", "Medium", "On"])
        XCTAssertTrue(summary.spoken.contains("Left out: DSC_0108.NEF"), summary.spoken)
    }

    /// A panorama records its own settings, and its sources can sit in
    /// another folder.
    func testAPanoramaRecipeNamesTheProjectionAndTheFilesOnly() {
        let summary = MergeRecipeSummary(recipe(kind: .panorama,
                                                options: ["projection": .string("cylindrical"),
                                                          "autoCrop": .bool(true)],
                                                names: ["../Day 3/A.NEF", "../Day 3/B.NEF"]))
        XCTAssertEqual(summary.rows.map(\.label), ["Merged", "From 2", "Projection", "Auto Crop"])
        XCTAssertEqual(summary.rows.map(\.value), ["Panorama", "A.NEF, B.NEF", "Cylindrical", "On"])
    }

    /// Nothing to say is said in as few rows: one photo, no options, no
    /// left-out row.
    func testARecipeWithNothingExtraIsOneRow() {
        let summary = MergeRecipeSummary(recipe(kind: .hdrPanorama, options: [:], names: ["A.NEF"]))
        XCTAssertEqual(summary.rows.map(\.label), ["Merged", "From"])
        XCTAssertEqual(summary.rows[0].value, "HDR panorama")
    }

    /// An HDR panorama's stitch joins positions, each a bracket of several
    /// photos, so its `leftOut` counts positions. Reading it as photos
    /// would name the wrong files; the photos come from `brackets`.
    func testAnHDRPanoramaNamesThePhotosOfThePositionsItLeftOut() {
        let options: [String: JSONValue] = [
            "hdrPanorama": .bool(true),
            // Six photos, three positions of two. The stitch left position 2
            // out, which is photos 4 and 5 — not photo 2.
            "leftOut": .array([.number(2)]),
            "positionsLeftOut": .array([.number(2)]),
            "brackets": .array([
                .object(["frames": .array([.number(0), .number(1)]), "reference": .number(0)]),
                .object(["frames": .array([.number(2), .number(3)]), "reference": .number(2)]),
                .object(["frames": .array([.number(4), .number(5)]), "reference": .number(4)]),
            ]),
        ]
        let names = ["A.NEF", "B.NEF", "C.NEF", "D.NEF", "E.NEF", "F.NEF"]
        let summary = MergeRecipeSummary(recipe(kind: .hdrPanorama, options: options, names: names))
        let row = try? XCTUnwrap(summary.rows.first { $0.label.hasSuffix("left out") })
        XCTAssertEqual(row?.value, "E.NEF, F.NEF")
        // Photo 2 is C.NEF; reading the position index as a photo index
        // would have named it.
        XCTAssertFalse(row?.value.contains("C.NEF") ?? true, "the position index is not a photo index")
    }

    /// Without the brackets it says nothing rather than something wrong.
    func testAnHDRPanoramaWithNoBracketsSaysNothingAboutLeftOutPhotos() {
        let summary = MergeRecipeSummary(recipe(kind: .hdrPanorama,
                                                options: ["leftOut": .array([.number(1)])],
                                                names: ["A.NEF", "B.NEF"]))
        XCTAssertFalse(summary.rows.contains { $0.label.contains("left out") || $0.label == "Left out" })
    }

    /// A recipe written by some newer Latent, or a file someone edited by
    /// hand, shows nothing rather than half a panel.
    func testAnUnreadableRecipeShowsNothing() {
        XCTAssertNil(MergeRecipeSummary(json: "not json"))
        XCTAssertNil(MergeRecipeSummary(json: "{}"))
        XCTAssertNil(MergeRecipeSummary(json: ""))
    }

    /// An index out of range in the stored `leftOut` is ignored, not
    /// crashed on.
    func testAnOutOfRangeLeftOutIndexIsIgnored() {
        let summary = MergeRecipeSummary(recipe(kind: .hdr, options: ["leftOut": .array([.number(9), .number(0)])],
                                                names: ["A.NEF", "B.NEF"]))
        XCTAssertEqual(summary.rows.first { $0.label == "Left out" }?.value, "A.NEF")
    }

    /// The written recipe reads back through the real JSON, so the panel
    /// and the merge can't drift apart.
    func testTheStoredJSONRoundTrips() throws {
        let written = recipe(kind: .panorama, options: ["projection": .string("spherical"), "autoCrop": .bool(false)],
                             names: ["A.NEF", "B.NEF"])
        let json = String(decoding: try written.jsonData(), as: UTF8.self)
        let summary = try XCTUnwrap(MergeRecipeSummary(json: json))
        XCTAssertEqual(summary.rows.map(\.value), ["Panorama", "A.NEF, B.NEF", "Spherical", "Off"])
    }

    // MARK: - Where a running job shows

    /// A merge's progress and its only Cancel button must not sit inside
    /// the Export disclosure group: the user can fold that away, and then
    /// nothing on screen says why Export and Photo Merge are greyed out,
    /// and there is no way to stop the job but to quit.
    ///
    /// Checked in the source, because a collapsed `DisclosureGroup` is
    /// exactly what a hosted view test can't reach: `exportExpanded` is the
    /// view's own state.
    func testAJobsProgressAndCancelAreOutsideTheDisclosureGroup() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/latent-app/LibraryPanel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let body = try XCTUnwrap(text.range(of: "DisclosureGroup(isExpanded: $exportExpanded)"))
        let above = text[..<body.lowerBound]
        XCTAssertTrue(above.contains("runningJob"), "the running job's block must be rendered above the section")
        XCTAssertTrue(above.contains("mergeNotes"), "and what it had to say when it ended")
        // There is one Cancel for a merge in the whole panel, and it lives
        // in `runningJob`, not in the disclosure group's body.
        XCTAssertEqual(text.components(separatedBy: "photoMerge.cancel()").count - 1, 1)
        let declaration = try XCTUnwrap(text.range(of: "private var runningJob: some View"))
        let cancel = try XCTUnwrap(text.range(of: "photoMerge.cancel()"))
        XCTAssertTrue(cancel.lowerBound > declaration.lowerBound,
                      "the merge's Cancel must be inside `runningJob`")
    }
}
