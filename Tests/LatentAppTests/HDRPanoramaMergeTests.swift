import XCTest
import AppKit
@testable import Catalog
import MergeKit
import PixelEngine
import simd
@testable import latent_app

// Photo › Photo Merge › HDR Panorama… (docs/PhotoMerge.md phase 9,
// experimental), against a fake engine: the real one lives in MergeKit and
// is tested there. No HDR panorama exists to test with, so the photos are
// the tiny float DNGs the HDR tests make, which the catalog opens like any
// raw, and what is checked here is the command, the dialog and the job.

/// A stand-in HDR panorama engine that follows a script and records what it saw.
final class FakeHDRPanoramaEngine: HDRPanoramaMerging, @unchecked Sendable {
    enum Script: Sendable {
        /// Writes the sidecar, then a real DNG.
        case write
        /// Writes the sidecar, then throws.
        case fail(HDRPanoramaError)
        /// Writes the sidecar, then waits to be cancelled.
        case waitForCancel
    }

    private let lock = NSLock()
    private var _analysis: Result<HDRPanoramaAnalysis, Error>
    private var _gateOpen = true
    private var _log: [String] = []
    private var _recipes: [MergeRecipe] = []
    private var _sources: [[MergeRecipe.Source]] = []
    private var _mergeOptions: [HDRPanoramaOptions] = []
    private var _analyseOptions: [HDRPanoramaOptions] = []
    private var _releases = 0
    let script: Script
    let reports: [HDRPanoramaProgress]

    init(analysis: Result<HDRPanoramaAnalysis, Error>, script: Script = .write,
         reports: [HDRPanoramaProgress] = []) {
        _analysis = analysis
        self.script = script
        self.reports = reports
    }

    var log: [String] { lock.withLock { _log } }
    var recipes: [MergeRecipe] { lock.withLock { _recipes } }
    var sources: [[MergeRecipe.Source]] { lock.withLock { _sources } }
    var mergeOptions: [HDRPanoramaOptions] { lock.withLock { _mergeOptions } }
    var analyseOptions: [HDRPanoramaOptions] { lock.withLock { _analyseOptions } }
    var releases: Int { lock.withLock { _releases } }

    func closeGate() { lock.withLock { _gateOpen = false } }
    func openGate() { lock.withLock { _gateOpen = true } }
    func setAnalysis(_ analysis: HDRPanoramaAnalysis) { lock.withLock { _analysis = .success(analysis) } }

    private func note(_ line: String) { lock.withLock { _log.append(line) } }

    func analyse(_ urls: [URL], options: HDRPanoramaOptions) async throws -> HDRPanoramaAnalysis {
        note("analyse \(urls.count) \(options.panorama.projection.rawValue) "
             + "\(options.hdr.autoAlign) \(options.hdr.deghost.rawValue)")
        lock.withLock { _analyseOptions.append(options) }
        while !lock.withLock({ _gateOpen }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        return try lock.withLock { _analysis }.get()
    }

    func merge(_ analysis: HDRPanoramaAnalysis, options: HDRPanoramaOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (HDRPanoramaProgress) -> Void) async throws -> MergeDNGWriteResult {
        lock.withLock {
            _sources.append(sources)
            _mergeOptions.append(options)
        }
        let reports = reports
        await Task.detached { for report in reports { progress(report) } }.value
        let recipe = MergeRecipe(kind: .hdrPanorama, clipLevel: 4, lensApplied: true, reference: 0,
                                 options: ["hdrPanorama": .bool(true)], sources: sources)
        let sidecar = FakeHDREngine.sidecar(for: destination)
        note("before sidecar: sidecar \(FakeHDREngine.exists(sidecar)), dng \(FakeHDREngine.exists(destination))")
        try await prepareSidecar(recipe)
        lock.withLock { _recipes.append(recipe) }
        note("after sidecar: sidecar \(FakeHDREngine.exists(sidecar)), dng \(FakeHDREngine.exists(destination))")
        switch script {
        case .write:
            break
        case .fail(let error):
            throw error
        case .waitForCancel:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(50))
        let result = try BracketFolder.writeDNG(to: destination, recipe: recipe, brightness: 1)
        note("wrote \(destination.lastPathComponent)")
        return result
    }

    func releasePreviews() async { lock.withLock { _releases += 1 } }
}

/// What an engine would say of a bracketed sweep.
enum HDRPanoramaFixtures {
    /// `positions` positions of `exposures` photos each, in capture order,
    /// from the files given (which must be positions x exposures of them).
    static func analysis(urls: [URL], positions: Int, exposures: Int,
                         outputSize: PanoramaOutputSize = PanoramaFixtures.fits,
                         evidence: HDRPanoramaGrouping.Evidence = .exposurePatternAndTiming,
                         leftOut: Set<Int> = [],
                         warnings: [HDRPanoramaWarning] = []) -> HDRPanoramaAnalysis {
        let photos = urls.enumerated().map { index, url in
            HDRPanoramaPhoto(url: url, captureTime: Date(timeIntervalSince1970: 1_789_498_800 + Double(index)),
                             exposureSeconds: pow(2, Double(index % max(exposures, 1)) * 2 - 2) / 250,
                             iso: 200, aperture: 5.6)
        }
        let groups = (0..<positions).map { position in
            let frames = (0..<exposures).map { position * exposures + $0 }
            return HDRPanoramaGrouping.Position(frames: frames, reference: frames[(frames.count - 1) / 2])
        }
        let grouping = HDRPanoramaGrouping(positions: groups, evidence: evidence)
        // The panorama's own analysis: one frame per position, named by the
        // position's reference photo, as the engine lays it out.
        let referenceURLs = groups.map { urls[$0.reference] }
        let panorama = PanoramaFixtures.analysis(urls: referenceURLs, leftOut: leftOut, outputSize: outputSize)
        var all = warnings
        all += panorama.warnings.map { .panorama($0) }
        return HDRPanoramaAnalysis(photos: photos, grouping: grouping, panorama: panorama, warnings: all,
                                   estimatedOutputBytes: 245_000_000, estimatedScratchBytes: 435_000_000)
    }
}

// MARK: - The command

@MainActor
final class HDRPanoramaCommandTests: XCTestCase {
    private func state(_ change: (inout CommandState) -> Void = { _ in }) -> CommandState {
        var state = CommandState()
        state.mode = .library
        state.hasVisibleImages = true
        state.hasSelection = true
        state.selectionCount = 2
        state.editorReady = true
        change(&state)
        return state
    }

    func testTheCommandNeedsTwoOrMoreSelectedPhotosAndTheGPU() {
        XCTAssertTrue(state().isEnabled(.photoMergeHDRPanorama))
        XCTAssertTrue(state { $0.selectionCount = 15 }.isEnabled(.photoMergeHDRPanorama))
        XCTAssertFalse(state { $0.selectionCount = 1 }.isEnabled(.photoMergeHDRPanorama))
        XCTAssertFalse(state { $0.editorReady = false }.isEnabled(.photoMergeHDRPanorama))
        XCTAssertFalse(state { $0.exportQueueRunning = true }.isEnabled(.photoMergeHDRPanorama))
        XCTAssertFalse(state { $0.photoMergeRunning = true }.isEnabled(.photoMergeHDRPanorama))
        XCTAssertFalse(state { $0.isEditingText = true }.isEnabled(.photoMergeHDRPanorama),
                       "⌃⇧M mustn’t fire while typing")
    }

    /// Lightroom's key for HDR Panorama, beside ⌃M as ⌃⇧H sits beside ⌃H.
    func testTheShortcutIsControlShiftM() throws {
        let shortcut = try XCTUnwrap(Shortcuts.shortcut(for: .photoMergeHDRPanorama))
        XCTAssertEqual(shortcut.key, .character("m"))
        XCTAssertEqual(shortcut.modifiers, [.shift, .control])
        XCTAssertEqual(shortcut.glyphs, "⌃⇧M")
        XCTAssertEqual(Shortcuts.all.filter { $0.key == .character("m") && $0.modifiers == [.shift, .control] }.count,
                       1, "⌃⇧M is free in Latent’s own table")
        XCTAssertTrue(Shortcuts.system.allSatisfy { !($0.key == .character("m") && $0.modifiers == [.shift, .control]) })
    }

    /// The menu says Experimental, so nobody reaches it by accident.
    func testTheMenuItemSaysExperimental() {
        XCTAssertEqual(Shortcuts.menuTitle("HDR Panorama… (Experimental)", for: .photoMergeHDRPanorama),
                       "HDR Panorama… (Experimental)")
    }
}

// MARK: - The dialog

@MainActor
final class HDRPanoramaMergeSheetModelTests: XCTestCase {
    private func record(_ name: String, id: Int64) -> ImageRecord {
        ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: 1, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    private let root = URL(fileURLWithPath: "/Photos/Sweep", isDirectory: true)
    /// Two positions of three exposures.
    private let names = ["A0.NEF", "A1.NEF", "A2.NEF", "B0.NEF", "B1.NEF", "B2.NEF"]

    private var urls: [URL] { names.map { root.appendingPathComponent($0) } }
    private var records: [ImageRecord] { names.enumerated().map { record($1, id: Int64($0 + 1)) } }

    private func analysis(outputSize: PanoramaOutputSize = PanoramaFixtures.fits,
                          warnings: [HDRPanoramaWarning] = []) -> HDRPanoramaAnalysis {
        HDRPanoramaFixtures.analysis(urls: urls, positions: 2, exposures: 3, outputSize: outputSize,
                                     warnings: warnings)
    }

    nonisolated(unsafe) private var defaultsSuite = "latent-hdrpano-tests-\(UUID().uuidString)"

    override func tearDown() async throws {
        let suite = defaultsSuite
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func model(_ engine: FakeHDRPanoramaEngine,
                       destination: String? = "A0-HDRPano.dng") -> HDRPanoramaMergeSheetModel {
        HDRPanoramaMergeSheetModel(records: records, urls: urls, engine: engine,
                                   defaults: UserDefaults(suiteName: defaultsSuite)!,
                                   planDestination: { _ in destination })
    }

    private func waitForReady(_ model: HDRPanoramaMergeSheetModel) async throws {
        for _ in 0..<400 {
            if model.analysisResult != nil { return }
            if case .failed = model.phase { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the dialog never finished measuring")
    }

    /// The dialog lists the positions it found, what each holds and where
    /// it points, and names the result after the first photo.
    func testItShowsThePositionsAndTheirExposures() async throws {
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis()))
        let model = model(engine)
        model.start()
        try await waitForReady(model)

        XCTAssertEqual(model.rows.count, 2)
        let first = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(first.title, "Position 1")
        XCTAssertEqual(first.photos, "3 photos · A0.NEF – A1.NEF".replacingOccurrences(of: "A1", with: "A2"))
        XCTAssertEqual(first.exposures, "-2 EV, 0 EV, +2 EV")
        XCTAssertFalse(first.isLeftOut)
        XCTAssertFalse(first.direction.isEmpty, "the dialog says where a position points")
        XCTAssertEqual(first.record?.relPath, "A0.NEF", "the thumbnail is the position’s first photo")
        XCTAssertEqual(model.groupingText,
                       "3 exposures at each of 2 positions, from the repeating exposures and the gaps "
                       + "between shots.")
        XCTAssertEqual(model.destinationName, "A0-HDRPano.dng")
        XCTAssertNotNil(model.sizeText)
        XCTAssertNotNil(model.coverageText)
        XCTAssertEqual(model.scratchText?.hasSuffix("given back at the end"), true)
        XCTAssertTrue(model.canMerge)
        XCTAssertEqual(model.mergeButtonTitle, "Merge")
    }

    /// The word the plan insists on, with one sentence saying why.
    func testItSaysExperimentalAndWhy() {
        XCTAssertTrue(HDRPanoramaMergeSheetModel.experimentalNotice.hasPrefix("Experimental: "))
        XCTAssertTrue(HDRPanoramaMergeSheetModel.experimentalNotice.contains("never been checked on a real HDR "
                                                                             + "panorama"))
    }

    /// Both parents' options are remembered, and only the projection
    /// measures the photos again.
    func testOptionsAreRememberedAndOnlyProjectionReanalyses() async throws {
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis()))
        let model = model(engine)
        model.start()
        try await waitForReady(model)
        XCTAssertEqual(engine.analyseOptions.count, 1)

        model.autoAlign = false
        model.deghost = .medium
        model.autoCrop = false
        model.autoSettings = true
        XCTAssertEqual(engine.analyseOptions.count, 1, "the HDR options don’t change the layout")

        model.projection = .spherical
        try await waitForReady(model)
        XCTAssertEqual(engine.analyseOptions.count, 2, "the projection does")
        XCTAssertEqual(engine.analyseOptions.last?.panorama.projection, .spherical)
        XCTAssertEqual(engine.analyseOptions.last?.hdr.deghost, .medium)
        XCTAssertEqual(engine.analyseOptions.last?.hdr.autoAlign, false)

        // The next dialog opens where this one was left.
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let preferences = HDRPanoramaMergePreferences(defaults: defaults)
        XCTAssertFalse(preferences.autoAlign)
        XCTAssertEqual(preferences.deghost, .medium)
        XCTAssertEqual(preferences.projection, .spherical)
        XCTAssertFalse(preferences.autoCrop)
        XCTAssertTrue(preferences.autoSettings)
        XCTAssertEqual(preferences.options.hdr.deghost, .medium)
        XCTAssertEqual(preferences.options.panorama.autoCrop, false)
    }

    /// An oversized panorama is never refused: it says what it will make
    /// instead and waits to be agreed with (Harman's rule).
    func testAnOversizedHDRPanoramaWaitsForAgreement() async throws {
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis(outputSize: PanoramaFixtures.tooBig)))
        let model = model(engine)
        model.start()
        try await waitForReady(model)

        XCTAssertTrue(model.needsDownsamplingConsent)
        XCTAssertFalse(model.canMerge, "not until it is agreed to")
        XCTAssertEqual(model.mergeButtonTitle, "Merge at 43%")
        let text = try XCTUnwrap(model.downsampleText)
        XCTAssertTrue(text.contains("29,195 × 7,664"), text)
        XCTAssertFalse(model.warnings.contains { $0.contains("29,195") }, "the agreement isn’t repeated as a warning")
        model.acceptsDownsampling = true
        XCTAssertTrue(model.canMerge)
    }

    /// Everything the engine warned about, in the dialog's words.
    func testWarningsAreShownInWords() async throws {
        let warnings: [HDRPanoramaWarning] = [
            .unevenBrackets(counts: [3, 3, 2]),
            .singlePhotoPosition(position: 2, fileName: "C0.NEF"),
            .groupingIsAGuess(evidence: .timeGaps),
            .scratchSpace(bytes: 435_000_000),
        ]
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis(warnings: warnings)))
        let model = model(engine)
        model.start()
        try await waitForReady(model)

        XCTAssertEqual(model.warnings.count, 4)
        XCTAssertTrue(model.warnings[0].contains("3, 3 and 2"), model.warnings[0])
        XCTAssertTrue(model.warnings[1].contains("Position 3 is one photo, C0.NEF"), model.warnings[1])
        XCTAssertTrue(model.warnings[2].contains("gaps between shots"), model.warnings[2])
        XCTAssertTrue(model.warnings[3].contains("temporary space"), model.warnings[3])
    }

    /// A selection that isn't brackets is refused with the plan's own words.
    func testItSaysWhyPhotosArentAnHDRPanorama() async throws {
        let engine = FakeHDRPanoramaEngine(analysis: .failure(HDRPanoramaError.cantTellPositions))
        let model = model(engine)
        model.start()
        try await waitForReady(model)

        guard case .failed(let message) = model.phase else { return XCTFail("the dialog should have failed") }
        XCTAssertTrue(message.hasPrefix("These don’t look like brackets: each position needs the same exposures."),
                      message)
        XCTAssertFalse(model.canMerge)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// Closing the dialog stops the analysis and lets the engine go.
    func testCancelStopsTheAnalysis() async throws {
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis()))
        engine.closeGate()
        let model = model(engine)
        model.start()
        model.cancel()
        for _ in 0..<200 where engine.releases == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(engine.releases, 1)
        XCTAssertNil(model.analysisResult)
    }
}

// MARK: - The job

@MainActor
final class HDRPanoramaMergeJobTests: XCTestCase {
    nonisolated(unsafe) var folder: BracketFolder?

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
    }

    private func sweep() async throws -> BracketFolder {
        let made = try await BracketFolder.make()
        folder = made
        return made
    }

    private func queue(_ jobs: OutputJobs = OutputJobs(), exports: ExportQueue = ExportQueue()) -> PhotoMergeQueue {
        let queue = PhotoMergeQueue(gpuSlot: exports, jobs: jobs)
        queue.removeStrayResult = { try FileManager.default.removeItem(at: $0) }
        return queue
    }

    /// The three stand-in photos as one position of three exposures plus
    /// nothing else would be one position, so they are read as three
    /// positions of one photo — which is all the job needs: it only passes
    /// the analysis through.
    private func analysis(_ sweep: BracketFolder,
                          outputSize: PanoramaOutputSize = PanoramaFixtures.fits) -> HDRPanoramaAnalysis {
        HDRPanoramaFixtures.analysis(urls: sweep.urls, positions: 3, exposures: 1, outputSize: outputSize)
    }

    /// The sidecar goes in before the DNG; the result is named after the
    /// first photo of the first position, with the HDRPano suffix; and the
    /// recipe records every photo, not the intermediates.
    func testASuccessfulHDRPanoramaCommitsInOrderAndNamesTheResult() async throws {
        let sweep = try await sweep()
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis(sweep)))
        let jobs = OutputJobs()
        let exports = ExportQueue()
        let queue = queue(jobs, exports: exports)
        XCTAssertTrue(queue.startHDRPanorama(analysis(sweep), options: HDRPanoramaOptions(),
                                             records: sweep.records, library: sweep.library, engine: engine))
        XCTAssertTrue(queue.isRunning)
        XCTAssertEqual(queue.kind, .hdrPanorama)
        XCTAssertEqual(queue.name, "DSC_0106-HDRPano.dng")
        XCTAssertEqual(jobs.running.map(\.kind), [.hdrPanoramaMerge])
        XCTAssertTrue(exports.isGPUBusy, "exports wait")
        XCTAssertFalse(queue.startHDRPanorama(analysis(sweep), options: HDRPanoramaOptions(),
                                              records: sweep.records, library: sweep.library, engine: engine),
                       "one merge at a time")

        await queue.waitUntilDone()
        XCTAssertEqual(engine.log, [
            "before sidecar: sidecar false, dng false",
            "after sidecar: sidecar true, dng false",
            "wrote DSC_0106-HDRPano.dng",
        ])
        XCTAssertEqual(try sweep.files(), (BracketFolder.names + ["DSC_0106-HDRPano.dng"]).sorted())

        let sources = try XCTUnwrap(engine.sources.first)
        XCTAssertEqual(sources.map(\.path), BracketFolder.names, "every photo the user chose, beside the result")
        let stored = try XMPSidecar.read(from: sweep.sidecar("DSC_0106-HDRPano.dng")).mergeJSON
        let recipe = try MergeRecipe(jsonData: Data(try XCTUnwrap(stored).utf8))
        XCTAssertEqual(recipe.kind, .hdrPanorama)
        XCTAssertEqual(recipe.sources.count, BracketFolder.names.count)
        XCTAssertFalse(queue.summary.isEmpty)
    }

    /// A failure takes the sidecar back and says so, leaving nothing behind.
    func testAFailedHDRPanoramaTakesTheSidecarBack() async throws {
        let sweep = try await sweep()
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis(sweep)),
                                           script: .fail(.positionFailed(position: 1, reason: "no GPU")))
        let queue = queue()
        queue.startHDRPanorama(analysis(sweep), options: HDRPanoramaOptions(), records: sweep.records,
                               library: sweep.library, engine: engine)
        await queue.waitUntilDone()

        XCTAssertEqual(try sweep.files(), BracketFolder.names, "no DNG, nothing stray")
        let message = try XCTUnwrap(sweep.library.lastError)
        XCTAssertTrue(message.hasPrefix("HDR panorama merge failed: "), message)
        XCTAssertTrue(message.contains("bracket at position 2"), message)
    }

    /// Cancelling stops it and leaves the folder as it was.
    func testCancellingLeavesNothingBehind() async throws {
        let sweep = try await sweep()
        let engine = FakeHDRPanoramaEngine(analysis: .success(analysis(sweep)), script: .waitForCancel)
        let queue = queue()
        queue.startHDRPanorama(analysis(sweep), options: HDRPanoramaOptions(), records: sweep.records,
                               library: sweep.library, engine: engine)
        for _ in 0..<200 where engine.log.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        queue.cancel()
        await queue.waitUntilDone()

        XCTAssertEqual(try sweep.files(), BracketFolder.names)
        XCTAssertEqual(queue.summary, "HDR panorama merge cancelled")
    }

    /// Both stages' progress reaches the panel, in the engine's order.
    func testProgressFromBothStagesReachesThePanel() async throws {
        let sweep = try await sweep()
        let engine = FakeHDRPanoramaEngine(
            analysis: .success(analysis(sweep)),
            reports: [HDRPanoramaProgress(fraction: 0.1, stage: "Merging bracket 1 of 3"),
                      HDRPanoramaProgress(fraction: 0.7, stage: "Stitching tile 4 of 30")])
        let queue = queue()
        queue.startHDRPanorama(analysis(sweep), options: HDRPanoramaOptions(), records: sweep.records,
                               library: sweep.library, engine: engine)
        await queue.waitUntilDone()
        // No first edit was asked for, so the last thing reported is the
        // engine's own last stage.
        XCTAssertEqual(queue.progress?.stage, "Stitching tile 4 of 30")
        XCTAssertEqual(queue.progress?.fraction, 0.7)
        XCTAssertEqual(PhotoMergeQueue.spokenProgress(MergeProgress(fraction: 0.7,
                                                                    stage: "Stitching tile 4 of 30")),
                       "Stitching tile 4 of 30, 70 percent")
    }
}
