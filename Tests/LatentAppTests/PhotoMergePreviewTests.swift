import XCTest
import AppKit
@testable import Catalog
import MergeKit
import PixelEngine
@testable import latent_app

// Photo Merge Phase 7 in the app: the dialog's live preview, picking the
// reference, Auto Settings, and HDR Merge Without Dialog (⌃⇧H), against
// the fake engine of PhotoMergeTests.swift.

// MARK: - The dialog

@MainActor
final class HDRMergeSheetPreviewTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Photos/Bracket", isDirectory: true)
    private let names = ["DSC_0106.NEF", "DSC_0107.NEF", "DSC_0108.NEF"]

    private func analysis() -> HDRMergeAnalysis {
        let frames = names.enumerated().map { index, name in
            HDRMergeFrame(url: root.appendingPathComponent(name), exposureSeconds: [1.0 / 15, 1.0 / 60, 1.0 / 250][index],
                          iso: 100, aperture: 8, relativeEV: Double(-2 * index), exifRelativeEV: Double(-2 * index),
                          clippedFraction: 0)
        }
        return HDRMergeAnalysis(frames: frames, referenceIndex: 1, width: 6016, height: 4016, exposureRangeStops: 4,
                                warnings: [], estimatedOutputBytes: 145_000_000)
    }

    nonisolated(unsafe) private var defaultsSuite = "latent-photo-merge-preview-tests-\(UUID().uuidString)"

    override func tearDown() async throws {
        let suite = defaultsSuite
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }

    final class Recorder { var names: [String] = [] }

    private func model(_ engine: FakeHDREngine) -> (HDRMergeSheetModel, Recorder) {
        let records = names.enumerated().map { index, name in
            ImageRecord(id: Int64(index + 1), relPath: name, preservedName: nil, size: 1, mtime: 1,
                        xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil,
                        shutter: nil, aperture: nil, focal: nil, width: nil, height: nil, orientation: nil, rating: 0,
                        label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
        }
        let asked = Recorder()
        let model = HDRMergeSheetModel(records: records, urls: records.map { root.appendingPathComponent($0.relPath) },
                                       engine: engine, defaults: defaults) { reference in
            asked.names.append(reference.fileName)
            return (reference.fileName as NSString).deletingPathExtension + "-HDR.dng"
        }
        return (model, asked)
    }

    /// The first preview comes as soon as the photos are measured, with the
    /// dialog's options and size.
    func testThePreviewFollowsTheAnalysis() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (model, _) = model(engine)
        model.previewLongEdge = 900
        XCTAssertNil(model.preview)
        model.start()
        await waitUntil("the preview") { model.preview != nil }
        XCTAssertFalse(model.isUpdatingPreview)
        XCTAssertNil(model.previewProblem)
        XCTAssertEqual(engine.previews.map(\.options), [model.options])
        XCTAssertEqual(engine.previews.map(\.longEdge), [900])
        XCTAssertEqual(engine.previews.map(\.overlay), [false])
        XCTAssertEqual(model.spokenPreview, "up to date")
    }

    /// Clicking through Deghost's levels makes one preview, for the last;
    /// the overlay needs a level; a newer change cancels the preview under way.
    func testOptionChangesPreviewAgainOnceTheyStop() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the first preview") { model.preview != nil }

        model.showDeghostOverlay = true
        XCTAssertFalse(model.isUpdatingPreview, "no overlay to show without a Deghost level")
        model.deghost = .low
        model.deghost = .medium
        model.deghost = .high
        XCTAssertTrue(model.isUpdatingPreview)
        await model.waitForPreview()
        XCTAssertEqual(engine.previews.count, 2, "one preview for the three clicks")
        XCTAssertEqual(engine.previews.last?.options.deghost, .high)
        XCTAssertEqual(engine.previews.last?.overlay, true)
        XCTAssertTrue(model.spokenPreview.contains("deghost overlay"), model.spokenPreview)

        model.showDeghostOverlay = false
        await model.waitForPreview()
        XCTAssertEqual(engine.previews.map(\.overlay), [false, true, false])
        XCTAssertFalse(model.isUpdatingPreview)
    }

    /// Clicking a photo makes it the reference: the list, the stops, the
    /// result's name, the merge's options and the preview all follow.
    /// Clicking the engine's own choice again goes back to "automatic".
    func testClickingAPhotoMakesItTheReference() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (model, asked) = model(engine)
        model.start()
        await waitUntil("the first preview") { model.preview != nil }
        XCTAssertEqual(model.destinationName, "DSC_0107-HDR.dng")

        model.useAsReference(0)
        XCTAssertEqual(model.rows.map(\.isReference), [true, false, false])
        XCTAssertEqual(model.rows.map(\.ev), ["0 EV", "-2 EV", "-4 EV"])
        XCTAssertEqual(model.rows[0].spoken, "DSC_0106.NEF, 1/15 s, ƒ/8, ISO 100, reference")
        XCTAssertEqual(model.options.referenceIndex, 0)
        XCTAssertEqual(model.referenceRecord?.fileName, "DSC_0106.NEF")
        await waitUntil("the new name") { model.destinationName == "DSC_0106-HDR.dng" }
        await model.waitForPreview()
        XCTAssertEqual(engine.previews.last?.options.referenceIndex, 0)
        XCTAssertEqual(asked.names, ["DSC_0107.NEF", "DSC_0106.NEF"])

        model.useAsReference(1)
        XCTAssertNil(model.options.referenceIndex, "the engine's own choice")
        XCTAssertEqual(model.rows.map(\.isReference), [false, true, false])
    }

    /// With the overlay on, each photo says its colour.
    func testRowsNameTheirOverlayColour() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        model.deghost = .medium
        XCTAssertEqual(model.rows.map(\.showsOverlayColour), [false, false, false])
        model.showDeghostOverlay = true
        XCTAssertEqual(model.rows.map(\.showsOverlayColour), [true, true, true])
        XCTAssertTrue(model.rows[0].spoken.hasSuffix("overlay colour orange"), model.rows[0].spoken)
        XCTAssertTrue(model.rows[1].spoken.hasSuffix("overlay colour sky blue"), model.rows[1].spoken)
    }

    /// Closing the dialog (Cancel, Merge, or the window going) stops the
    /// preview and lets the engine free what it kept.
    func testClosingReleasesThePreviews() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the first preview") { model.preview != nil }
        model.deghost = .medium
        XCTAssertTrue(model.isUpdatingPreview)
        model.cancel()
        XCTAssertEqual(engine.releases, 1)
        XCTAssertFalse(model.isUpdatingPreview)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(engine.previews.count, 1, "the cancelled preview never finished")
    }

    func testAFailedPreviewSaysSo() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        engine.failPreviews(with: HDRMergeError.gpuUnavailable(reason: "out of memory"))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the problem") { model.previewProblem != nil }
        XCTAssertEqual(model.previewProblem,
                       "The preview couldn’t be made. The graphics processor couldn't run the merge: out of memory")
        XCTAssertFalse(model.isUpdatingPreview)
        XCTAssertNotNil(model.analysisResult, "Merge still works")
    }

    /// Auto Settings starts off, then as it was last left.
    func testAutoSettingsIsRemembered() {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (first, _) = model(engine)
        XCTAssertFalse(first.autoSettings)
        first.autoSettings = true
        let (second, _) = model(engine)
        XCTAssertTrue(second.autoSettings)
        XCTAssertTrue(HDRMergePreferences(defaults: defaults).autoSettings)
    }
}

// MARK: - Auto Settings and HDR Merge Without Dialog

@MainActor
final class PhotoMergeWithoutDialogTests: XCTestCase {
    nonisolated(unsafe) var folder: BracketFolder?
    nonisolated(unsafe) private var defaultsSuite = "latent-photo-merge-headless-tests-\(UUID().uuidString)"

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
        let suite = defaultsSuite
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func bracket() async throws -> BracketFolder {
        let made = try await BracketFolder.make()
        folder = made
        return made
    }

    private func queue() -> PhotoMergeQueue {
        let queue = PhotoMergeQueue(gpuSlot: ExportQueue(), jobs: OutputJobs())
        queue.removeStrayResult = { try FileManager.default.removeItem(at: $0) }
        return queue
    }

    /// An edit Auto Adjust might make.
    private func autoEdit() throws -> String {
        var parameters = EditParameters()
        parameters.exposureEV = 0.7
        parameters.contrast = 1.8
        return try EditStack(parameters: parameters).encodeJSON()
    }

    /// Auto Settings' edit is the result's first edit, stored through the
    /// catalog: in its row and in its sidecar beside the recipe.
    func testAutoSettingsStoresTheResultsFirstEdit() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()))
        let queue = queue()
        let json = try autoEdit()
        let asked = URLRecorder()
        XCTAssertTrue(queue.start(bracket.analysis(), records: bracket.records, library: bracket.library,
                                  engine: engine, autoSettings: { url in
                                      asked.add(url)
                                      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "after the DNG")
                                      return json
                                  }))
        await queue.waitUntilDone()
        await bracket.library.waitForPendingWork()
        XCTAssertEqual(asked.urls.map(\.lastPathComponent), ["DSC_0107-HDR.dng"])
        let result = try XCTUnwrap(bracket.library.images.first { $0.fileName == "DSC_0107-HDR.dng" })
        let stored = try await bracket.library.editStack(for: result)
        XCTAssertEqual(stored, json)
        XCTAssertTrue(bracket.library.editedImageIDs.contains(result.id!))
        let sidecar = try XMPSidecar.read(from: bracket.sidecar("DSC_0107-HDR.dng"))
        XCTAssertEqual(sidecar.editStackJSON, json)
        XCTAssertFalse(sidecar.mergeJSON.isEmpty, "beside the recipe")
        XCTAssertEqual(bracket.library.selectedImageID, result.id)
        XCTAssertNil(bracket.library.lastError)
    }

    /// Auto Settings that can't be worked out leave the merge as it is, and say so.
    func testAutoSettingsThatFailLeaveTheMergeUnedited() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()))
        let queue = queue()
        struct Broken: Error, LocalizedError { var errorDescription: String? { "no colour profile" } }
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine,
                    autoSettings: { _ in throw Broken() })
        await queue.waitUntilDone()
        let result = try XCTUnwrap(bracket.library.images.first { $0.fileName == "DSC_0107-HDR.dng" })
        let stored = try await bracket.library.editStack(for: result)
        XCTAssertNil(stored)
        // The photo is there, so this is a note beside the panel's summary,
        // not a red error in the status bar.
        XCTAssertNil(bracket.library.lastError)
        XCTAssertEqual(queue.notes, ["Auto Settings couldn’t be worked out: no colour profile"])
    }

    /// Without the dialog: the photos are measured and merged with the
    /// options it was last left with, and the result is named after the
    /// engine's reference, whatever order the grid selected them in.
    func testWithoutTheDialogUsesTheRememberedOptions() async throws {
        let bracket = try await bracket()
        let preferences = HDRMergePreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)
        preferences.autoAlign = false
        preferences.deghost = .high
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()))
        let queue = queue()
        let records = bracket.records.reversed() as [ImageRecord]
        let urls = records.map { bracket.root.appendingPathComponent($0.relPath) }
        XCTAssertTrue(queue.startWithoutDialog(records: records, urls: urls, options: preferences.options,
                                               library: bracket.library, engine: engine))
        XCTAssertTrue(queue.isRunning)
        XCTAssertFalse(queue.startWithoutDialog(records: records, urls: urls, options: preferences.options,
                                                library: bracket.library, engine: engine), "one at a time")
        await queue.waitUntilDone()
        let expected = HDRMergeOptions(deghost: .high, autoAlign: false)
        XCTAssertEqual(engine.analyseOptions, [expected])
        XCTAssertEqual(engine.mergeOptions, [expected])
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0107-HDR.dng"])
        XCTAssertEqual(engine.sources.first?.map(\.path), BracketFolder.names, "in the analysis's order")
        XCTAssertEqual(bracket.library.selectedImage?.fileName, "DSC_0107-HDR.dng")
        XCTAssertNil(bracket.library.lastError, "no warnings, nothing to say")
        XCTAssertFalse(queue.gpuSlot.isGPUBusy)
    }

    /// The warnings the dialog would have shown are said once the merge is done.
    func testWithoutTheDialogWarningsAreReportedWhenDone() async throws {
        let bracket = try await bracket()
        let warnings: [HDRMergeWarning] = [.frameCouldNotBeAligned(frameIndex: 2, leftOut: true),
                                           .framesLookMisaligned(maximumShiftPixels: 3.4)]
        let engine = FakeHDREngine(analysis: .success(bracket.analysis(warnings: warnings)), script: .waitForCancel)
        let queue = queue()
        queue.startWithoutDialog(records: bracket.records, urls: bracket.urls, options: HDRMergeOptions(),
                                 library: bracket.library, engine: engine)
        await waitUntil("the sidecar") { FakeHDREngine.exists(bracket.sidecar("DSC_0107-HDR.dng")) }
        XCTAssertNil(bracket.library.lastError, "nothing said while it merges")
        queue.cancel()
        await queue.waitUntilDone()
        XCTAssertNil(bracket.library.lastError, "nor when cancelled")

        let finishing = FakeHDREngine(analysis: .success(bracket.analysis(warnings: warnings)))
        queue.startWithoutDialog(records: bracket.records, urls: bracket.urls, options: HDRMergeOptions(),
                                 library: bracket.library, engine: finishing)
        await queue.waitUntilDone()
        // Warnings from a merge that worked are notes, one per line, where
        // they can be read whole: the status bar is red, announced as an
        // error, and clipped to one line.
        XCTAssertNil(bracket.library.lastError, "a merge that worked is not an error")
        XCTAssertEqual(queue.notes,
                       ["Photo Merge couldn’t align DSC_0108.dng, so it’s left out of the merge.",
                        "These photos don’t line up exactly (up to 3 px apart), so edges may look doubled. "
                        + "Turn on Auto Align to line them up."])
        XCTAssertTrue(queue.summary.hasPrefix("Merged DSC_0107-HDR.dng"))
    }

    /// Notes belong to the merge that made them: the next one starts clean.
    func testNotesAreClearedByTheNextMerge() async throws {
        let bracket = try await bracket()
        let warnings: [HDRMergeWarning] = [.smallExposureRange(stops: 0.7)]
        let queue = queue()
        queue.startWithoutDialog(records: bracket.records, urls: bracket.urls, options: HDRMergeOptions(),
                                 library: bracket.library,
                                 engine: FakeHDREngine(analysis: .success(bracket.analysis(warnings: warnings))))
        await queue.waitUntilDone()
        XCTAssertEqual(queue.notes.count, 1)
        queue.startWithoutDialog(records: bracket.records, urls: bracket.urls, options: HDRMergeOptions(),
                                 library: bracket.library,
                                 engine: FakeHDREngine(analysis: .success(bracket.analysis())))
        XCTAssertEqual(queue.notes, [], "cleared as soon as the next merge starts")
        await queue.waitUntilDone()
        XCTAssertEqual(queue.notes, [])
    }

    /// Photos that can't be merged: the reason in the status bar, nothing written.
    func testWithoutTheDialogAnAnalysisErrorShowsInTheStatusBar() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .failure(HDRMergeError.sameExposure))
        let queue = queue()
        queue.startWithoutDialog(records: bracket.records, urls: bracket.urls, options: HDRMergeOptions(),
                                 library: bracket.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(bracket.library.lastError, "HDR merge failed: \(HDRMergeError.sameExposure.errorDescription!)")
        XCTAssertEqual(try bracket.files(), BracketFolder.names)
        XCTAssertEqual(engine.mergeOptions, [])
        XCTAssertFalse(queue.gpuSlot.isGPUBusy)
        XCTAssertFalse(queue.isRunning)
    }

    /// Lightroom's key: Shift with the dialog's; enabled as the dialog is.
    func testTheShortcutIsShiftControlH() throws {
        let shortcut = try XCTUnwrap(Shortcuts.shortcut(for: .photoMergeHDRWithoutDialog))
        XCTAssertEqual(shortcut.key, .character("h"))
        XCTAssertEqual(shortcut.modifiers, [.shift, .control])
        XCTAssertFalse(shortcut.isBare)
        XCTAssertEqual(shortcut.glyphs, "⌃⇧H")
        let clashes = Shortcuts.all.filter { $0.key == shortcut.key && $0.modifiers == shortcut.modifiers }
        XCTAssertEqual(clashes.count, 1, "no other command has ⌃⇧H")
        XCTAssertFalse(Shortcuts.system.contains { $0.key == shortcut.key && $0.modifiers == shortcut.modifiers })

        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 3
        state.editorReady = true
        XCTAssertTrue(state.isEnabled(.photoMergeHDRWithoutDialog))
        state.photoMergeRunning = true
        XCTAssertFalse(state.isEnabled(.photoMergeHDRWithoutDialog))
        state.photoMergeRunning = false
        state.selectionCount = 1
        XCTAssertFalse(state.isEnabled(.photoMergeHDRWithoutDialog))
    }

    final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func add(_ url: URL) { lock.withLock { _urls.append(url) } }
    }
}
