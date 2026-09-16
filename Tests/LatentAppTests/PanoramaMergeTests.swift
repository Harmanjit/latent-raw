import XCTest
import AppKit
import Combine
@testable import Catalog
import MergeKit
import PixelEngine
import simd
@testable import latent_app

// Photo › Photo Merge › Panorama… (docs/PhotoMerge.md phase 8c), against a
// fake engine: the real one lives in MergeKit and is tested there. There are
// no sweeps on hand in CI, so the photos are the tiny float DNGs the HDR
// tests make, which the catalog opens like any raw.

/// A stand-in panorama engine that follows a script and records what it saw.
final class FakePanoramaEngine: PanoramaMerging, @unchecked Sendable {
    enum Script: Sendable {
        /// Writes the sidecar, then a real DNG.
        case write
        /// Writes the sidecar, then throws.
        case fail(PanoramaError)
        /// Writes the sidecar, then waits to be cancelled.
        case waitForCancel
        /// Another app puts a file under the name before the first DNG is
        /// written, so the write finds it; later merges write.
        case nameTakenOnce
    }

    private let lock = NSLock()
    private var _analysis: Result<PanoramaMergeAnalysis, Error>
    private var _gateOpen = true
    private var _log: [String] = []
    private var _recipes: [MergeRecipe] = []
    private var _destinations: [URL] = []
    private var _sources: [[MergeRecipe.Source]] = []
    private var _mergeOptions: [PanoramaMergeOptions] = []
    private var _analyseOptions: [PanoramaMergeOptions] = []
    private var _previews: [(options: PanoramaMergeOptions, longEdge: Int)] = []
    private var _releases = 0
    private var _previewError: Error?
    private var merges = 0
    let script: Script
    let reports: [PanoramaMergeProgress]

    init(analysis: Result<PanoramaMergeAnalysis, Error>, script: Script = .write,
         reports: [PanoramaMergeProgress] = []) {
        _analysis = analysis
        self.script = script
        self.reports = reports
    }

    var log: [String] { lock.withLock { _log } }
    var recipes: [MergeRecipe] { lock.withLock { _recipes } }
    var destinations: [URL] { lock.withLock { _destinations } }
    var sources: [[MergeRecipe.Source]] { lock.withLock { _sources } }
    var mergeOptions: [PanoramaMergeOptions] { lock.withLock { _mergeOptions } }
    var analyseOptions: [PanoramaMergeOptions] { lock.withLock { _analyseOptions } }
    var previews: [(options: PanoramaMergeOptions, longEdge: Int)] { lock.withLock { _previews } }
    var releases: Int { lock.withLock { _releases } }

    func failPreviews(with error: Error?) { lock.withLock { _previewError = error } }
    func closeGate() { lock.withLock { _gateOpen = false } }
    func openGate() { lock.withLock { _gateOpen = true } }
    func setAnalysis(_ analysis: PanoramaMergeAnalysis) { lock.withLock { _analysis = .success(analysis) } }

    private func note(_ line: String) { lock.withLock { _log.append(line) } }

    func analyse(_ urls: [URL], options: PanoramaMergeOptions) async throws -> PanoramaMergeAnalysis {
        note("analyse \(urls.count) \(options.projection.rawValue)")
        lock.withLock { _analyseOptions.append(options) }
        while !lock.withLock({ _gateOpen }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        return try lock.withLock { _analysis }.get()
    }

    /// A 3 x 1 picture after a moment's work (so a newer request can cancel
    /// it); records what it was asked for once done.
    func preview(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions,
                 longEdge: Int) async throws -> CGImage {
        try await Task.sleep(for: .milliseconds(20))
        if let error = lock.withLock({ _previewError }) { throw error }
        lock.withLock { _previews.append((options, longEdge)) }
        return FakeRenders.solid((0.4, 0.5, 0.6), width: 3, height: 1)
    }

    func merge(_ analysis: PanoramaMergeAnalysis, options: PanoramaMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (PanoramaMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
        let attempt = lock.withLock {
            merges += 1
            _destinations.append(destination)
            _sources.append(sources)
            _mergeOptions.append(options)
            return merges
        }
        // From another thread, as a real engine reports.
        let reports = reports
        await Task.detached { for report in reports { progress(report) } }.value
        let recipe = MergeRecipe(kind: .panorama, clipLevel: 1, lensApplied: true, reference: 0, sources: sources)
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
        case .nameTakenOnce where attempt == 1:
            try Data("another app".utf8).write(to: destination)
        case .nameTakenOnce:
            break
        }
        // A reported value, so the job must wait for its reports to land.
        try await Task.sleep(for: .milliseconds(50))
        let result = try BracketFolder.writeDNG(to: destination, recipe: recipe, brightness: 1)
        note("wrote \(destination.lastPathComponent)")
        return result
    }

    func releasePreviews() async { lock.withLock { _releases += 1 } }
}

/// What an engine would say of a sweep: photos in capture order, turning
/// left to right, each a little brighter or darker than the first.
enum PanoramaFixtures {
    /// The size Harman's own 17-frame sweep wants, and the largest his Mac
    /// can edit: the numbers the downsampling sentence was written against.
    static let tooBig = PanoramaOutputSize(fullWidth: 29_195, fullHeight: 7_664, scale: 0.4275,
                                           width: 12_482, height: 3_276, limit: .memory, decodeSpan: 2)
    static let fits = PanoramaOutputSize(fullWidth: 9_600, fullHeight: 3_200, scale: 1,
                                         width: 9_600, height: 3_200, limit: .none, decodeSpan: 1)

    static func analysis(urls: [URL], leftOut: Set<Int> = [], outputSize: PanoramaOutputSize = fits,
                         projection: PanoramaProjection = .cylindrical,
                         warnings: [PanoramaMergeWarning] = [],
                         autoCropRect: CGRect = CGRect(x: 960, y: 320, width: 7_680, height: 2_240))
        -> PanoramaMergeAnalysis {
        let frames = urls.enumerated().map { index, url in
            PanoramaMergeFrame(url: url, captureTime: Date(timeIntervalSince1970: 1_789_498_800 + Double(index)),
                               exposureSeconds: 1.0 / 250, iso: 200, aperture: 5.6,
                               gainStops: leftOut.contains(index) ? 0 : Double(index) * 0.3 - 0.3,
                               yawPitchRoll: leftOut.contains(index) ? nil
                                   : SIMD3(Double(index) * 24 - 24, 0, 0),
                               leftOut: leftOut.contains(index))
        }
        let cameras = frames.indices.filter { !frames[$0].leftOut }.map { index in
            PanoramaCamera(frameIndex: index, rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1], focalLengthPixels: 5_000,
                           principalPoint: SIMD2(2_008, 3_008), width: 4_016, height: 6_016, exposureGain: 1)
        }
        let canvas = PanoramaCanvas(projection: projection, pixelsPerRadian: 5_000, origin: SIMD2(-4_800, -1_600),
                                    width: outputSize.fullWidth, height: outputSize.fullHeight)
        let layout = PanoramaLayout(cameras: cameras, canvas: canvas, autoCropRect: autoCropRect)
        var all = warnings
        if !leftOut.isEmpty, !warnings.contains(where: { if case .framesLeftOut = $0 { return true } else { return false } }) {
            all.insert(.framesLeftOut(indices: leftOut.sorted()), at: 0)
        }
        if outputSize.needsDownsampling,
           !warnings.contains(where: { if case .downsampled = $0 { return true } else { return false } }) {
            all.append(.downsampled(outputSize: outputSize))
        }
        return PanoramaMergeAnalysis(frames: frames, layout: layout, outputSize: outputSize, widthDegrees: 186,
                                     heightDegrees: 44, warnings: all, estimatedOutputBytes: 245_000_000)
    }
}

// MARK: - The command

@MainActor
final class PanoramaCommandTests: XCTestCase {
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

    /// Two or more photos, as a sweep needs; the whole selection, as the
    /// HDR command takes it.
    func testPanoramaNeedsTwoOrMoreSelectedPhotos() {
        XCTAssertTrue(state().isEnabled(.photoMergePanorama))
        XCTAssertTrue(state { $0.selectionCount = 17 }.isEnabled(.photoMergePanorama))
        XCTAssertFalse(state { $0.selectionCount = 1 }.isEnabled(.photoMergePanorama), "one photo is no panorama")
        XCTAssertFalse(state { $0.selectionCount = 0; $0.hasSelection = false }.isEnabled(.photoMergePanorama))
        XCTAssertFalse(CommandState().isEnabled(.photoMergePanorama))
        for mode in [AppMode.loupe, .compare, .survey, .develop] {
            XCTAssertTrue(state { $0.mode = mode; $0.hasImage = true }.isEnabled(.photoMergePanorama), "\(mode)")
        }
        XCTAssertFalse(state { $0.editorReady = false }.isEnabled(.photoMergePanorama), "no GPU to stitch with")
        XCTAssertFalse(state { $0.isEditingText = true }.isEnabled(.photoMergePanorama),
                       "⌃M inserts a line in a text field")
    }

    /// One full-size GPU job at a time: a panorama waits for an export or
    /// another merge, and they wait for it.
    func testPanoramasAndExportsTakeTurns() {
        XCTAssertFalse(state { $0.exportQueueRunning = true }.isEnabled(.photoMergePanorama))
        XCTAssertFalse(state { $0.photoMergeRunning = true }.isEnabled(.photoMergePanorama))
    }

    /// Lightroom's key, which nothing else in the table or the system has.
    func testTheShortcutIsControlM() throws {
        let shortcut = try XCTUnwrap(Shortcuts.shortcut(for: .photoMergePanorama))
        XCTAssertEqual(shortcut.key, .character("m"))
        XCTAssertEqual(shortcut.modifiers, .control)
        XCTAssertFalse(shortcut.isBare, "a menu key equivalent, not a single key")
        XCTAssertEqual(shortcut.glyphs, "⌃M")
        XCTAssertEqual(Shortcuts.menuTitle("Panorama…", for: .photoMergePanorama), "Panorama…")
        XCTAssertEqual(Shortcuts.all.filter { $0.key == .character("m") && $0.modifiers == .control }.count, 1,
                       "⌃M is free in Latent's own table")
        XCTAssertTrue(Shortcuts.system.allSatisfy { !($0.key == .character("m") && $0.modifiers == .control) },
                      "⌃M is free in the system's menus (⌘M minimises)")
        XCTAssertNil(KeyCommand.command(for: BareKeyPress(.character("m"))), "M alone still does nothing")
    }

    /// The harness's step name, so `LATENT_SNAPSHOT_STEPS=panoramamerge` works.
    func testTheSnapshotStepIsNamed() throws {
        XCTAssertEqual(try SnapshotPlan.parseSteps("panoramamerge"), [.panoramaMerge])
        XCTAssertFalse(SnapshotPlan.defaultSteps.contains(.panoramaMerge), "a dialog step is asked for by name")
    }
}

// MARK: - The dialog

@MainActor
final class PanoramaMergeSheetModelTests: XCTestCase {
    private func record(_ name: String, id: Int64) -> ImageRecord {
        ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: 1, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    private let root = URL(fileURLWithPath: "/Photos/Sweep", isDirectory: true)
    private let names = ["DSC_0106.NEF", "DSC_0107.NEF", "DSC_0108.NEF"]

    private func analysis(leftOut: Set<Int> = [], outputSize: PanoramaOutputSize = PanoramaFixtures.fits,
                          projection: PanoramaProjection = .cylindrical,
                          warnings: [PanoramaMergeWarning] = []) -> PanoramaMergeAnalysis {
        PanoramaFixtures.analysis(urls: names.map { root.appendingPathComponent($0) }, leftOut: leftOut,
                                  outputSize: outputSize, projection: projection, warnings: warnings)
    }

    /// Options remembered by one test only, never the user's own.
    nonisolated(unsafe) private var defaultsSuite = "latent-panorama-tests-\(UUID().uuidString)"

    override func tearDown() async throws {
        let suite = defaultsSuite
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }

    private func model(_ engine: FakePanoramaEngine,
                       planned: String? = "DSC_0106-Pano.dng") -> (PanoramaMergeSheetModel, Recorder) {
        // The grid's order, which need not be capture order.
        let records = [record("DSC_0108.NEF", id: 3), record("DSC_0106.NEF", id: 1), record("DSC_0107.NEF", id: 2)]
        let asked = Recorder()
        let model = PanoramaMergeSheetModel(records: records,
                                            urls: records.map { root.appendingPathComponent($0.relPath) },
                                            engine: engine, defaults: defaults) { reference in
            asked.names.append(reference.fileName)
            return planned
        }
        return (model, asked)
    }

    final class Recorder { var names: [String] = [] }

    func testAnalysingThenReady() async throws {
        let engine = FakePanoramaEngine(analysis: .success(analysis()))
        engine.closeGate()
        let (model, asked) = model(engine)
        model.start()
        XCTAssertEqual(model.phase, .analysing)
        XCTAssertEqual(model.analysingText, "Measuring 3 photos…")
        XCTAssertFalse(model.canMerge, "nothing to stitch yet")

        engine.openGate()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(engine.log, ["analyse 3 automatic"])
        let rows = model.rows
        XCTAssertEqual(rows.map(\.fileName), names, "in the order they were taken")
        XCTAssertEqual(rows.map(\.direction), ["24° left", "centre", "24° right"])
        XCTAssertEqual(rows.map(\.brightness), ["-0.3 EV", "0 EV", "+0.3 EV"])
        XCTAssertEqual(rows.map(\.isLeftOut), [false, false, false])
        XCTAssertEqual(rows.map { $0.record?.id }, [1, 2, 3], "matched to the grid's rows by file")
        XCTAssertEqual(rows[0].exposure, "1/250 s · ƒ/5.6 · ISO 200")
        XCTAssertEqual(rows[0].spoken,
                       "DSC_0106.NEF, 1/250 s, ƒ/5.6, ISO 200, points 24 degrees left of centre, darkened by 0.3 stops")
        XCTAssertEqual(rows[1].spoken,
                       "DSC_0107.NEF, 1/250 s, ƒ/5.6, ISO 200, points at the centre of the panorama, "
                           + "no brightness correction")
        XCTAssertEqual(model.sizeText, "9,600 × 3,200 (31 MP)")
        XCTAssertEqual(model.coverageText, "186° across, 44° tall")
        XCTAssertEqual(model.estimatedSizeText, "About 245 MB")
        XCTAssertEqual(model.destinationName, "DSC_0106-Pano.dng")
        XCTAssertEqual(asked.names, ["DSC_0106.NEF"], "named after the first photo of the sweep")
        XCTAssertEqual(model.referenceRecord?.id, 1)
        XCTAssertEqual(model.recordsInFrameOrder.map { $0?.id }, [1, 2, 3])
        XCTAssertEqual(model.warnings, [])
        XCTAssertNil(model.downsampleText, "it fits")
        XCTAssertEqual(model.mergeButtonTitle, "Merge")
        XCTAssertTrue(model.canMerge)
        XCTAssertEqual(PanoramaMergeSheetModel.editsNotice,
                       "The merge starts from the original raw files. Edits you made to these photos aren’t used.")
        XCTAssertEqual(PanoramaMergeSheetModel.editsNotice, HDRMergeSheetModel.editsNotice, "both dialogs say it")
    }

    /// A photo that couldn't be joined is marked in the list, named in a
    /// warning, and never becomes the photo the result is named after.
    func testPhotosLeftOutAreMarked() async {
        let engine = FakePanoramaEngine(analysis: .success(analysis(leftOut: [0, 2])))
        let (model, asked) = model(engine, planned: "DSC_0107-Pano.dng")
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        let rows = model.rows
        XCTAssertEqual(rows.map(\.isLeftOut), [true, false, true])
        XCTAssertEqual(rows[0].direction, "", "a photo left out points nowhere")
        XCTAssertEqual(rows[0].brightness, "")
        XCTAssertEqual(rows[0].spoken, "DSC_0106.NEF, 1/250 s, ƒ/5.6, ISO 200, left out of the panorama")
        XCTAssertEqual(model.leftOutNames, ["DSC_0106.NEF", "DSC_0108.NEF"])
        XCTAssertEqual(asked.names, ["DSC_0107.NEF"], "named after the first photo that was joined")
        XCTAssertEqual(model.destinationName, "DSC_0107-Pano.dng")
        XCTAssertEqual(model.warnings, [
            "2 photos couldn’t be joined to the others, so they’re left out: DSC_0106.NEF and DSC_0108.NEF. "
                + "They probably don’t overlap the rest enough: a panorama needs about 30% overlap between "
                + "neighbouring shots.",
        ])
        XCTAssertTrue(model.canMerge, "a photo left out doesn't stop the merge")
    }

    func testWarningsInPlainWords() async {
        let engine = FakePanoramaEngine(analysis: .success(analysis(leftOut: [2], warnings: [
            .unevenExposure(stops: 1.2),
            .largeParallax(rmsPixels: 7.4),
        ])))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.warnings, [
            "DSC_0108.NEF couldn’t be joined to the others, so it’s left out. It probably doesn’t overlap them "
                + "enough: a panorama needs about 30% overlap between neighbouring shots.",
            "These photos are 1.2 stops apart in brightness even after evening them out, so seams may still show. "
                + "Shoot a panorama with the exposure set by hand.",
            "The photos line up to about 7 px. Things close to the camera may look doubled: that happens when the "
                + "camera moves sideways instead of turning on the spot.",
        ])
        XCTAssertTrue(PanoramaMergeSheetModel.text(for: .largeParallax(rmsPixels: 0.2), frames: [])
            .contains("about 1 px"), "never 0 px")
        XCTAssertEqual(PanoramaMergeSheetModel.text(for: .framesLeftOut(indices: []), frames: []),
                       "Some photos couldn’t be joined to the others, so they’re left out of the panorama.")
    }

    /// Harman's rule: a panorama too big to edit is never refused. The
    /// dialog says what would have been made, what will be made and why,
    /// and Merge waits until that is agreed to.
    func testATooBigPanoramaIsExplainedAndAgreedTo() async {
        let engine = FakePanoramaEngine(analysis: .success(analysis(outputSize: PanoramaFixtures.tooBig)))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.downsampleText,
                       "This panorama would be 29,195 × 7,664 pixels (224 MP). The largest this Mac can edit is "
                           + "12,482 × 3,276 (41 MP), limited by memory, so the photos will be merged at 43%.")
        XCTAssertEqual(model.sizeText, "12,482 × 3,276 (41 MP)", "the size it will really be")
        XCTAssertTrue(model.needsDownsamplingConsent)
        XCTAssertEqual(model.consentLabel, "Merge at 43%")
        XCTAssertEqual(model.mergeButtonTitle, "Merge at 43%", "the button says what it will do")
        XCTAssertFalse(model.canMerge, "not until it is agreed to")
        XCTAssertFalse(model.warnings.contains { $0.contains("would be") }, "it has its own agreement, not a warning")

        model.acceptsDownsampling = true
        XCTAssertTrue(model.canMerge)

        // Measuring again (another projection) asks again: a size agreed to
        // is agreed to for that size only.
        engine.setAnalysis(analysis(outputSize: PanoramaFixtures.tooBig, projection: .spherical))
        model.projection = .spherical
        await waitUntil("the second list") { model.analysisResult?.layout.canvas.projection == .spherical }
        XCTAssertFalse(model.acceptsDownsampling)
        XCTAssertFalse(model.canMerge)
    }

    /// The graphics processor's limit is said in its own words.
    func testTheLimitIsNamed() {
        let texture = PanoramaOutputSize(fullWidth: 40_000, fullHeight: 8_000, scale: 0.4, width: 16_000,
                                         height: 3_200, limit: .textureSide, decodeSpan: 2)
        XCTAssertTrue(PanoramaMergeSheetModel.text(for: .downsampled(outputSize: texture), frames: [])
            .contains("limited by the largest picture the graphics processor can hold"))
        XCTAssertEqual(PanoramaMergeSheetModel.percent(0.4275), "43%")
        XCTAssertEqual(PanoramaMergeSheetModel.percent(0.004), "1%", "never 0%")
        XCTAssertEqual(PanoramaMergeSheetModel.pixelSize(12_482, 3_276), "12,482 × 3,276 (41 MP)")
        XCTAssertEqual(PanoramaMergeSheetModel.pixelSize(3_000, 2_000), "3,000 × 2,000 (6.0 MP)")
    }

    func testAnErrorReplacesTheList() async {
        let engine = FakePanoramaEngine(analysis: .failure(PanoramaError.notAPanorama(
            reason: "no two neighbouring photos could be matched.")))
        let (model, asked) = model(engine)
        model.start()
        await waitUntil("the error") { model.phase != .analysing }
        XCTAssertEqual(model.phase, .failed("These photos don't form a panorama: no two neighbouring photos "
                                            + "could be matched."))
        XCTAssertEqual(model.rows, [])
        XCTAssertFalse(model.canMerge, "Merge stays disabled")
        XCTAssertEqual(asked.names, [], "no name planned")

        struct Odd: Error {}
        XCTAssertTrue(PanoramaMergeSheetModel.message(for: Odd())
            .hasPrefix("These photos couldn’t be read for a panorama."))
    }

    /// The app builds the real engine, and what it throws reaches the
    /// dialog as a sentence a person can read.
    func testTheAppUsesTheRealEngine() async throws {
        let gpu = try await GPUContext.shared()
        let engine = PhotoMergeEngine.panorama(gpu: gpu)
        XCTAssertTrue(engine is PanoramaMerger, "the app builds the real engine")
        do {
            // Two files that aren't photos: the engine must refuse them.
            _ = try await engine.analyse([root.appendingPathComponent("A.NEF"),
                                          root.appendingPathComponent("B.NEF")], options: PanoramaMergeOptions())
            XCTFail("stitching files that aren't photos must throw")
        } catch {
            let message = PanoramaMergeSheetModel.message(for: error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), message)
        }
    }

    /// Projection is measured by the analysis: changing it measures the
    /// photos again. Auto Crop and Auto Settings don't.
    func testChangingTheProjectionAnalysesAgain() async {
        let engine = FakePanoramaEngine(analysis: .success(analysis()))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.projectionHint, "Latent chose Cylindrical. Wraps around like a label on a can; "
                       + "upright things stay upright.")

        model.autoCrop = false
        model.autoSettings = true
        XCTAssertNotNil(model.analysisResult, "neither measures the photos again")
        XCTAssertEqual(engine.log, ["analyse 3 automatic"])

        engine.closeGate()
        engine.setAnalysis(analysis(projection: .perspective))
        model.projection = .perspective
        XCTAssertEqual(model.phase, .analysing)
        engine.openGate()
        await waitUntil("the second list") { model.analysisResult != nil }
        XCTAssertEqual(engine.log, ["analyse 3 automatic", "analyse 3 perspective"])
        XCTAssertEqual(model.projectionHint, "Straight lines stay straight; only for a narrow sweep.")
        XCTAssertEqual(model.options,
                       PanoramaMergeOptions(projection: .perspective, autoCrop: false, autoSettings: true))
    }

    /// Automatic first, Auto Crop on, Auto Settings off; after that, as
    /// they were last left.
    func testOptionsStartAsTheyWereLastLeft() {
        let engine = FakePanoramaEngine(analysis: .success(analysis()))
        let (first, _) = model(engine)
        XCTAssertEqual(first.projection, .automatic)
        XCTAssertTrue(first.autoCrop)
        XCTAssertFalse(first.autoSettings)
        XCTAssertEqual(first.options, PanoramaMergeOptions(projection: .automatic, autoCrop: true,
                                                           autoSettings: false))
        first.projection = .spherical
        first.autoCrop = false
        first.autoSettings = true
        XCTAssertEqual(engine.log, [], "not started, so nothing is analysed")

        let (second, _) = model(engine)
        XCTAssertEqual(second.projection, .spherical)
        XCTAssertFalse(second.autoCrop)
        XCTAssertTrue(second.autoSettings)
        XCTAssertFalse(second.acceptsDownsampling, "agreeing to a smaller panorama is never remembered")
    }

    /// The preview follows the options, a moment after the last change, and
    /// only the newest one shows.
    func testThePreviewFollowsTheOptions() async throws {
        let engine = FakePanoramaEngine(analysis: .success(analysis()))
        let (model, _) = model(engine)
        model.previewLongEdge = 640
        model.start()
        await waitUntil("the first preview") { model.preview != nil }
        XCTAssertEqual(engine.previews.count, 1)
        XCTAssertEqual(engine.previews[0].longEdge, 640)
        XCTAssertFalse(model.isUpdatingPreview)
        XCTAssertEqual(model.spokenPreview, "up to date")

        model.autoCrop = false
        XCTAssertTrue(model.isUpdatingPreview)
        XCTAssertEqual(model.spokenPreview, "updating")
        await model.waitForPreview()
        XCTAssertEqual(engine.previews.count, 2)
        XCTAssertFalse(engine.previews[1].options.autoCrop)

        // A failing preview says so and leaves the picture that was there.
        engine.failPreviews(with: PanoramaError.gpuUnavailable(reason: "out of memory"))
        model.autoCrop = true
        await model.waitForPreview()
        XCTAssertNotNil(model.preview)
        XCTAssertEqual(model.previewProblem,
                       "The preview couldn’t be made. The GPU couldn't prepare the photos (out of memory).")
        XCTAssertEqual(model.spokenPreview, "not available")

        // Closing the dialog lets the engine free what it kept.
        model.cancel()
        await waitUntil("the release") { engine.releases > 0 }
    }

    /// Closing the dialog while the photos are read stops the analysis and
    /// shows no error.
    func testCancellingWhileAnalysing() async throws {
        let engine = FakePanoramaEngine(analysis: .success(analysis()))
        engine.closeGate()
        let (model, _) = model(engine)
        model.start()
        try await Task.sleep(for: .milliseconds(30))
        model.cancel()
        engine.openGate()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.phase, .analysing)
    }
}

// MARK: - The job

@MainActor
final class PanoramaMergeJobTests: XCTestCase {
    nonisolated(unsafe) var folder: BracketFolder?

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
    }

    private func sweep() async throws -> BracketFolder {
        let made = try await BracketFolder.make()
        folder = made
        XCTAssertEqual(made.records.count, 3, "the catalog opens the stand-in DNGs")
        return made
    }

    private func queue(_ jobs: OutputJobs = OutputJobs(), exports: ExportQueue = ExportQueue()) -> PhotoMergeQueue {
        let queue = PhotoMergeQueue(gpuSlot: exports, jobs: jobs)
        queue.removeStrayResult = { try FileManager.default.removeItem(at: $0) }
        return queue
    }

    private func analysis(_ sweep: BracketFolder, leftOut: Set<Int> = [],
                          outputSize: PanoramaOutputSize = PanoramaFixtures.fits) -> PanoramaMergeAnalysis {
        PanoramaFixtures.analysis(urls: sweep.urls, leftOut: leftOut, outputSize: outputSize)
    }

    /// The sidecar goes in before the DNG exists; then the DNG; then the
    /// folder is read again and the result selected, holding the GPU slot,
    /// a job and a keep-awake activity until it ends.
    func testASuccessfulPanoramaCommitsInOrderAndSelectsTheResult() async throws {
        let sweep = try await sweep()
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)))
        let jobs = OutputJobs()
        let exports = ExportQueue()
        let queue = queue(jobs, exports: exports)
        let held = ExportActivity.activeCount
        XCTAssertTrue(queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                                          library: sweep.library, engine: engine))
        XCTAssertTrue(queue.isRunning)
        XCTAssertEqual(queue.kind, .panorama)
        XCTAssertEqual(queue.name, "DSC_0106-Pano.dng")
        XCTAssertEqual(jobs.running.map(\.kind), [.panoramaMerge])
        XCTAssertEqual(ExportActivity.activeCount, held + 1)
        XCTAssertTrue(exports.isGPUBusy, "exports wait")
        XCTAssertFalse(queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                                           library: sweep.library, engine: engine), "one merge at a time")

        await queue.waitUntilDone()
        XCTAssertEqual(engine.log, [
            "before sidecar: sidecar false, dng false",
            "after sidecar: sidecar true, dng false",
            "wrote DSC_0106-Pano.dng",
        ])
        XCTAssertEqual(try sweep.files(), (BracketFolder.names + ["DSC_0106-Pano.dng"]).sorted())

        let sources = try XCTUnwrap(engine.sources.first)
        XCTAssertEqual(sources.map(\.path), BracketFolder.names, "every photo of the sweep, beside the result")
        XCTAssertEqual(sources.map(\.captureTime), sweep.records.map { $0.captureTime ?? -1 })
        let stored = try XMPSidecar.read(from: sweep.sidecar("DSC_0106-Pano.dng")).mergeJSON
        XCTAssertEqual(try MergeRecipe(jsonData: Data(stored.utf8)), engine.recipes.first)
        XCTAssertEqual(engine.recipes.first?.kind, .panorama)

        let result = try XCTUnwrap(sweep.library.images.first { $0.fileName == "DSC_0106-Pano.dng" },
                                   "catalogued by the refresh")
        XCTAssertEqual(sweep.library.selectedImageID, result.id)
        XCTAssertTrue(queue.summary.hasPrefix("Merged DSC_0106-Pano.dng in "), queue.summary)
        XCTAssertNil(sweep.library.lastError)
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(jobs.isRunning)
        XCTAssertFalse(exports.isGPUBusy)
        XCTAssertEqual(ExportActivity.activeCount, held)
    }

    /// The result takes the name of the first photo that was joined, not of
    /// one left out.
    func testTheResultIsNamedAfterTheFirstJoinedPhoto() async throws {
        let sweep = try await sweep()
        let analysis = analysis(sweep, leftOut: [0])
        XCTAssertEqual(PhotoMergeQueue.panoramaReferenceIndex(analysis), 1)
        let engine = FakePanoramaEngine(analysis: .success(analysis))
        let queue = queue()
        XCTAssertTrue(queue.startPanorama(analysis, options: PanoramaMergeOptions(), records: sweep.records,
                                          library: sweep.library, engine: engine))
        await queue.waitUntilDone()
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0107-Pano.dng"])
        XCTAssertEqual(sweep.library.selectedImage?.fileName, "DSC_0107-Pano.dng")
    }

    /// A name is taken by a file, by a sidecar a file left behind, or by a
    /// row: the stale sidecar alone is enough to move the result on.
    func testAStaleSidecarMovesTheNameOn() async throws {
        let sweep = try await sweep()
        let stale = sweep.sidecar("DSC_0106-Pano.dng")
        try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8).write(to: stale)
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)))
        let queue = queue()
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0106-Pano-2.dng"])
        XCTAssertEqual(try sweep.files(), (BracketFolder.names + ["DSC_0106-Pano-2.dng"]).sorted())
        XCTAssertEqual(sweep.library.selectedImage?.fileName, "DSC_0106-Pano-2.dng")
    }

    /// Another file takes the name while the pixels are stitched: that file
    /// keeps it and the merge goes to the next name.
    func testANameTakenAtTheLastMomentPlansANewOne() async throws {
        let sweep = try await sweep()
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)), script: .nameTakenOnce)
        let queue = queue()
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0106-Pano.dng", "DSC_0106-Pano-2.dng"])
        XCTAssertFalse(FakeHDREngine.exists(sweep.sidecar("DSC_0106-Pano.dng")),
                       "the other file doesn't get the merge's recipe")
        XCTAssertTrue(FakeHDREngine.exists(sweep.sidecar("DSC_0106-Pano-2.dng")))
        XCTAssertNil(sweep.library.lastError)
    }

    /// A failed stitch takes its sidecar back and says why in the status bar.
    func testAFailedPanoramaLeavesNothingAndReportsTheError() async throws {
        let sweep = try await sweep()
        let error = PanoramaError.gpuUnavailable(reason: "out of memory")
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)), script: .fail(error))
        let queue = queue()
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine)
        await queue.waitUntilDone()
        await sweep.library.waitForPendingWork()
        XCTAssertTrue(engine.log.contains("after sidecar: sidecar true, dng false"))
        XCTAssertFalse(FakeHDREngine.exists(sweep.sidecar("DSC_0106-Pano.dng")), "the sidecar is taken back")
        XCTAssertEqual(try sweep.files(), BracketFolder.names, "no DNG, nothing stray")
        XCTAssertEqual(sweep.library.lastError, "Panorama merge failed: \(error.errorDescription!)")
        XCTAssertEqual(queue.summary, "")
        XCTAssertFalse(queue.gpuSlot.isGPUBusy)
    }

    /// Cancel from the panel: no DNG, no sidecar, and no error shown.
    func testACancelledPanoramaLeavesNothing() async throws {
        let sweep = try await sweep()
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)), script: .waitForCancel)
        let queue = queue()
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine)
        let sidecar = sweep.sidecar("DSC_0106-Pano.dng")
        await waitUntil("the sidecar") { FakeHDREngine.exists(sidecar) }
        queue.cancel()
        await queue.waitUntilDone()
        XCTAssertFalse(FakeHDREngine.exists(sidecar))
        XCTAssertEqual(try sweep.files(), BracketFolder.names)
        XCTAssertNil(sweep.library.lastError)
        XCTAssertEqual(queue.summary, "Panorama merge cancelled")
    }

    /// The dialog's options reach the engine's merge unchanged.
    func testTheOptionsReachTheMerge() async throws {
        let sweep = try await sweep()
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)))
        let queue = queue()
        let options = PanoramaMergeOptions(projection: .spherical, autoCrop: false, autoSettings: true)
        XCTAssertTrue(queue.startPanorama(analysis(sweep), options: options, records: sweep.records,
                                          library: sweep.library, engine: engine))
        await queue.waitUntilDone()
        XCTAssertEqual(engine.mergeOptions, [options])
    }

    /// Auto Crop's rectangle is stored as the result's crop edit, through
    /// the catalog's normal edit path, so undo and history work.
    func testAutoCropIsStoredAsTheResultsCropEdit() async throws {
        let sweep = try await sweep()
        let gpu = try await GPUContext.shared()
        let analysis = analysis(sweep)
        let crop = try XCTUnwrap(PanoramaResultEdit.crop(for: analysis))
        let engine = FakePanoramaEngine(analysis: .success(analysis))
        let queue = queue()
        // Auto Settings off, so no GPU work: exactly the app's own closure.
        queue.startPanorama(analysis, options: PanoramaMergeOptions(autoCrop: true), records: sweep.records,
                            library: sweep.library, engine: engine,
                            firstEdit: { url in
                                try PanoramaResultEdit.editStackJSON(forPhotoAt: url, crop: crop,
                                                                     autoAdjust: false, gpu: gpu)
                            })
        await queue.waitUntilDone()
        await sweep.library.waitForPendingWork()
        let result = try XCTUnwrap(sweep.library.images.first { $0.fileName == "DSC_0106-Pano.dng" })
        let storedJSON = try await sweep.library.editStack(for: result)
        let json = try XCTUnwrap(storedJSON)
        let stack = try EditStack.decode(json: json)
        let stored = try XCTUnwrap(stack.modules.crop)
        // The auto-crop rectangle is 7,680 x 2,240 in a 9,600 x 3,200 canvas.
        XCTAssertEqual(Double(stored.w), 0.8, accuracy: 0.001)
        XCTAssertEqual(Double(stored.h), 0.7, accuracy: 0.001)
        XCTAssertEqual(Double(stored.cx), 0.5, accuracy: 0.001)
        XCTAssertEqual(Double(stored.cy), 0.45, accuracy: 0.001)
        XCTAssertTrue(sweep.library.editedImageIDs.contains(result.id!))
        let sidecar = try XMPSidecar.read(from: sweep.sidecar("DSC_0106-Pano.dng"))
        XCTAssertEqual(sidecar.editStackJSON, json)
        XCTAssertFalse(sidecar.mergeJSON.isEmpty, "beside the recipe")
        XCTAssertNil(sweep.library.lastError)
    }

    /// Auto Settings' adjustments are stored the same way, and the two are
    /// one edit, so one undo takes the photo back to the raw stitch.
    func testAutoSettingsAndAutoCropAreOneEdit() async throws {
        let sweep = try await sweep()
        var adjusted = EditParameters()
        adjusted.exposureEV = 0.7
        adjusted.contrast = 1.8
        let auto = EditStack(parameters: adjusted)
        let crop = CropParameters(centre: [0.5, 0.45], size: [0.8, 0.7])
        let json = try XCTUnwrap(try PanoramaResultEdit.combine(autoAdjusted: auto, crop: crop))
        let combined = try EditStack.decode(json: json)
        XCTAssertEqual(combined.modules.exposure?.ev, 0.7, "Auto Settings kept")
        XCTAssertEqual(combined.modules.crop?.w, 0.8, "Auto Crop kept")

        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)))
        let queue = queue()
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(autoCrop: true, autoSettings: true),
                            records: sweep.records, library: sweep.library, engine: engine,
                            firstEdit: { _ in json })
        await queue.waitUntilDone()
        await sweep.library.waitForPendingWork()
        let result = try XCTUnwrap(sweep.library.images.first { $0.fileName == "DSC_0106-Pano.dng" })
        let storedJSON = try await sweep.library.editStack(for: result)
        XCTAssertEqual(storedJSON, json)
    }

    /// A first edit that can't be worked out leaves the panorama as it is,
    /// and says so.
    func testAFirstEditThatFailsLeavesThePanoramaUnedited() async throws {
        let sweep = try await sweep()
        struct Broken: Error, LocalizedError { var errorDescription: String? { "no colour profile" } }
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)))
        let queue = queue()
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine, firstEdit: { _ in throw Broken() })
        await queue.waitUntilDone()
        let result = try XCTUnwrap(sweep.library.images.first { $0.fileName == "DSC_0106-Pano.dng" })
        let storedJSON = try await sweep.library.editStack(for: result)
        XCTAssertNil(storedJSON)
        XCTAssertEqual(sweep.library.lastError,
                       "Panorama merge DSC_0106-Pano.dng finished, but: Auto Crop and Auto Settings couldn’t be "
                           + "worked out: no colour profile")
    }

    /// Quitting asks, as for exports and contact sheets, then stops the
    /// stitch and waits for it to tidy up before the app goes.
    func testQuittingStopsThePanoramaAndWaitsForItToTidyUp() async throws {
        let sweep = try await sweep()
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)), script: .waitForCancel)
        let jobs = OutputJobs()
        let queue = queue(jobs)
        let held = ExportActivity.activeCount
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine)
        let sidecar = sweep.sidecar("DSC_0106-Pano.dng")
        await waitUntil("the sidecar") { FakeHDREngine.exists(sidecar) }

        XCTAssertTrue(jobs.isRunning)
        let text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still making a panorama merge")
        XCTAssertEqual(text.information, "Quitting now stops the panorama merge, which leaves no photo.")
        XCTAssertEqual(text.button, "Stop and Quit")

        jobs.cancelAll()
        await jobs.waitUntilDone()
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(FakeHDREngine.exists(sidecar), "tidied before the wait ends")
        XCTAssertEqual(try sweep.files(), BracketFolder.names)
        XCTAssertFalse(sweep.library.hasPendingWork)
        XCTAssertEqual(ExportActivity.activeCount, held)
    }

    /// The engine reports from any thread; the panel sees each report on
    /// the main thread, in order.
    func testProgressArrivesOnTheMainThread() async throws {
        let sweep = try await sweep()
        let reports = (1...5).map { PanoramaMergeProgress(fraction: Double($0) / 5, stage: "Stitching tile \($0) of 5") }
        let engine = FakePanoramaEngine(analysis: .success(analysis(sweep)), reports: reports)
        let queue = queue()
        var seen: [MergeProgress] = []
        var offMain = 0
        let watch = queue.$progress.dropFirst().sink { progress in
            if !Thread.isMainThread { offMain += 1 }
            if let progress { seen.append(progress) }
        }
        defer { watch.cancel() }
        queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(), records: sweep.records,
                            library: sweep.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(seen, reports.map(MergeProgress.init))
        XCTAssertEqual(offMain, 0)
        XCTAssertEqual(PhotoMergeQueue.spokenProgress(MergeProgress(reports[1])),
                       "Stitching tile 2 of 5, 40 percent")
    }

    /// An export holding the GPU refuses the stitch, and the other way round.
    func testAPanoramaWaitsForTheExportQueue() async throws {
        let sweep = try await sweep()
        let exports = ExportQueue()
        XCTAssertTrue(exports.claimSlot())
        let jobs = OutputJobs()
        let queue = queue(jobs, exports: exports)
        XCTAssertFalse(queue.startPanorama(analysis(sweep), options: PanoramaMergeOptions(),
                                           records: sweep.records, library: sweep.library,
                                           engine: FakePanoramaEngine(analysis: .success(analysis(sweep)))))
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(jobs.isRunning)
        exports.releaseSlot()
    }
}

// MARK: - Auto Crop's rectangle

final class PanoramaResultEditTests: XCTestCase {
    private func analysis(cropRect: CGRect, full: (Int, Int) = (9_600, 3_200)) -> PanoramaMergeAnalysis {
        let size = PanoramaOutputSize(fullWidth: full.0, fullHeight: full.1, scale: 0.5, width: full.0 / 2,
                                      height: full.1 / 2, limit: .memory, decodeSpan: 2)
        return PanoramaFixtures.analysis(urls: [URL(fileURLWithPath: "/Photos/A.NEF"),
                                                URL(fileURLWithPath: "/Photos/B.NEF")],
                                         outputSize: size, autoCropRect: cropRect)
    }

    /// Normalised against the canvas at full resolution, so the crop is the
    /// same rectangle whatever scale the panorama was merged at.
    func testTheCropIsNormalisedAgainstTheWholeCanvas() throws {
        let crop = try XCTUnwrap(PanoramaResultEdit.crop(
            for: analysis(cropRect: CGRect(x: 960, y: 320, width: 7_680, height: 2_240))))
        XCTAssertEqual(crop.size.x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(crop.size.y, 0.7, accuracy: 0.0001)
        XCTAssertEqual(crop.centre.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(crop.centre.y, 0.45, accuracy: 0.0001)
        XCTAssertEqual(crop.angle, 0, "Auto Crop never straightens")
    }

    /// Nothing to crop: no edit, so the panorama opens with no history of
    /// its own.
    func testAWholeCanvasIsNoCrop() throws {
        XCTAssertNil(PanoramaResultEdit.crop(for: analysis(cropRect: CGRect(x: 0, y: 0, width: 9_600, height: 3_200))))
        XCTAssertNil(PanoramaResultEdit.crop(for: analysis(cropRect: .zero)))
        XCTAssertNil(try PanoramaResultEdit.combine(autoAdjusted: nil, crop: nil), "neither option: no edit")
    }
}
