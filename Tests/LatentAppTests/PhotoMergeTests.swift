import XCTest
import AppKit
import Combine
@testable import Catalog
import MergeKit
import PixelEngine
@testable import latent_app

// Photo › Photo Merge › HDR… (docs/PhotoMerge.md phase 5b), against a fake
// engine: the real one lives in MergeKit and is tested there. There are no
// real brackets on hand, so the photos are tiny float DNGs made by MergeKit's
// writer, which the catalog opens like any raw.

/// A stand-in HDR engine that follows a script and records what it saw.
final class FakeHDREngine: HDRMerging, @unchecked Sendable {
    enum Script: Sendable {
        /// Writes the sidecar, then a real DNG.
        case write
        /// Writes the sidecar, then throws.
        case fail(HDRMergeError)
        /// Writes the sidecar, then waits to be cancelled.
        case waitForCancel
        /// Writes the sidecar and the DNG, then throws anyway: an engine
        /// that breaks the contract.
        case writeThenFail
        /// Another app puts a file under the name before the first DNG is
        /// written, so the write finds it; later merges write.
        case nameTakenOnce
    }

    private let lock = NSLock()
    private var _analysis: Result<HDRMergeAnalysis, Error>
    private var _gateOpen = true
    private var _log: [String] = []
    private var _recipes: [MergeRecipe] = []
    private var _destinations: [URL] = []
    private var _sources: [[MergeRecipe.Source]] = []
    private var _mergeOptions: [HDRMergeOptions] = []
    private var _analyseOptions: [HDRMergeOptions] = []
    private var _previews: [(options: HDRMergeOptions, overlay: Bool, longEdge: Int)] = []
    private var _releases = 0
    private var _previewError: Error?
    private var merges = 0
    let script: Script
    let reports: [HDRMergeProgress]

    init(analysis: Result<HDRMergeAnalysis, Error>, script: Script = .write, reports: [HDRMergeProgress] = []) {
        _analysis = analysis
        self.script = script
        self.reports = reports
    }

    var log: [String] { lock.withLock { _log } }
    var recipes: [MergeRecipe] { lock.withLock { _recipes } }
    var destinations: [URL] { lock.withLock { _destinations } }
    var sources: [[MergeRecipe.Source]] { lock.withLock { _sources } }
    /// The options each merge was given.
    var mergeOptions: [HDRMergeOptions] { lock.withLock { _mergeOptions } }
    /// The options each analysis was given.
    var analyseOptions: [HDRMergeOptions] { lock.withLock { _analyseOptions } }
    /// Each preview finished, in order, with what it was asked for.
    var previews: [(options: HDRMergeOptions, overlay: Bool, longEdge: Int)] { lock.withLock { _previews } }
    /// How many times the previews were released.
    var releases: Int { lock.withLock { _releases } }
    /// Makes every later preview throw `error` (nil: succeed).
    func failPreviews(with error: Error?) { lock.withLock { _previewError = error } }

    /// Holds `analyse` until `openGate`.
    func closeGate() { lock.withLock { _gateOpen = false } }
    func openGate() { lock.withLock { _gateOpen = true } }

    private func note(_ line: String) { lock.withLock { _log.append(line) } }

    /// Replaces the analysis the next `analyse` returns.
    func setAnalysis(_ analysis: HDRMergeAnalysis) { lock.withLock { _analysis = .success(analysis) } }

    func analyse(_ urls: [URL], options: HDRMergeOptions) async throws -> HDRMergeAnalysis {
        note("analyse \(urls.count)" + (options.autoAlign ? "" : " without aligning"))
        lock.withLock { _analyseOptions.append(options) }
        while !lock.withLock({ _gateOpen }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        return try lock.withLock { _analysis }.get()
    }

    func merge(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, sources: [MergeRecipe.Source],
               to destination: URL,
               prepareSidecar: @escaping @Sendable (MergeRecipe) async throws -> Void,
               progress: @escaping @Sendable (HDRMergeProgress) -> Void) async throws -> MergeDNGWriteResult {
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
        let recipe = MergeRecipe(kind: .hdr, clipLevel: 1, lensApplied: false, reference: analysis.referenceIndex,
                                 sources: sources)
        let sidecar = Self.sidecar(for: destination)
        note("before sidecar: sidecar \(Self.exists(sidecar)), dng \(Self.exists(destination))")
        try await prepareSidecar(recipe)
        lock.withLock { _recipes.append(recipe) }
        note("after sidecar: sidecar \(Self.exists(sidecar)), dng \(Self.exists(destination))")
        switch script {
        case .write:
            break
        case .fail(let error):
            throw error
        case .waitForCancel:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        case .writeThenFail:
            _ = try BracketFolder.writeDNG(to: destination, recipe: recipe, brightness: 1)
            throw HDRMergeError.gpuUnavailable(reason: "lost the device")
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

    /// A 3 x 2 picture after a moment's work (so a newer request can cancel
    /// it); records what it was asked for once done.
    func preview(_ analysis: HDRMergeAnalysis, options: HDRMergeOptions, longEdge: Int,
                 showDeghostOverlay: Bool) async throws -> CGImage {
        try await Task.sleep(for: .milliseconds(20))
        if let error = lock.withLock({ _previewError }) { throw error }
        lock.withLock { _previews.append((options, showDeghostOverlay, longEdge)) }
        return FakeRenders.solid((0.5, 0.5, 0.5), width: 3, height: 2)
    }

    func releasePreviews() { lock.withLock { _releases += 1 } }

    /// Where the catalog keeps the sidecar of a photo at the folder's top.
    static func sidecar(for photo: URL) -> URL {
        photo.deletingLastPathComponent().appendingPathComponent("_latent/xmp/\(photo.lastPathComponent).xmp")
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// A folder of three small float DNGs standing in for a bracket shot on a
/// tripod, opened as a catalog.
@MainActor
struct BracketFolder {
    static let names = ["DSC_0106.dng", "DSC_0107.dng", "DSC_0108.dng"]
    /// Brightest first, 2 stops apart.
    static let brightness: [Float] = [0.9, 0.225, 0.056]

    let base: URL
    let root: URL
    let library: Library

    static func make() async throws -> BracketFolder {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-photo-merge-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Bracket", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recipe = MergeRecipe(kind: .hdr, clipLevel: 1, lensApplied: false, reference: 0, sources: [])
        for (index, name) in names.enumerated() {
            _ = try writeDNG(to: root.appendingPathComponent(name), recipe: recipe, brightness: brightness[index],
                             captureDate: Date(timeIntervalSince1970: 1_789_498_799 + Double(index)))
        }
        let library = Library()
        try await library.open(folder: root, defaultSubfolderMode: .independent)
        return BracketFolder(base: base, root: root, library: library)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// The catalog's rows, in the analysis's order (brightest first).
    var records: [ImageRecord] {
        Self.names.compactMap { name in library.images.first { $0.fileName == name } }
    }

    var urls: [URL] { Self.names.map { root.appendingPathComponent($0) } }

    /// What an engine would say of the bracket: 2 stops apart, the middle
    /// one the reference.
    func analysis(warnings: [HDRMergeWarning] = []) -> HDRMergeAnalysis {
        let frames = urls.enumerated().map { index, url in
            HDRMergeFrame(url: url, exposureSeconds: [1.0 / 15, 1.0 / 60, 1.0 / 250][index], iso: 100, aperture: 8,
                          relativeEV: Double(-2 * index), exifRelativeEV: Double(-2 * index), clippedFraction: 0)
        }
        return HDRMergeAnalysis(frames: frames, referenceIndex: 1, width: 48, height: 32, exposureRangeStops: 4,
                                warnings: warnings, estimatedOutputBytes: 20_000)
    }

    /// Everything in the folder but the catalog's own, by name.
    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "_latent" }.sorted()
    }

    func sidecar(_ name: String) -> URL { root.appendingPathComponent("_latent/xmp/\(name).xmp") }

    /// A float LinearRaw DNG of 48 x 32 pixels, as a merge writes.
    nonisolated static func writeDNG(to url: URL, recipe: MergeRecipe, brightness: Float,
                                     captureDate: Date = Date(timeIntervalSince1970: 1_789_498_800)) throws
        -> MergeDNGWriteResult {
        let (width, height) = (48, 32)
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        for i in pixels.indices { pixels[i] = Float16(Float(i % 97) / 96 * brightness) }
        let metadata = MergeDNGMetadata(
            make: "Nikon", model: "D750",
            colorMatrix1: try MergeDNGMetadata.colorMatrix(fromCamXYZ: [0.9020, -0.2890, -0.0715, -0.4535, 1.2436,
                                                                         0.2348, -0.0934, 0.1919, 0.7086]),
            asShotNeutral: try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: [2.078125, 1, 1.207031]),
            software: "Latent tests", captureDate: captureDate, exposureTime: 1.0 / 60, fNumber: 8, iso: 100)
        return try LinearRawDNGWriter(freeSpaceMargin: 0).write(
            .buffer(pixels, width: width, height: height), maximum: brightness, metadata: metadata, recipe: recipe,
            preview: FakeRenders.solid((0.5, 0.5, 0.5), width: 48, height: 32), to: url)
    }
}

// MARK: - The command

@MainActor
final class PhotoMergeCommandTests: XCTestCase {
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

    /// Two or more photos, as a bracket needs; the whole selection, so the
    /// other views merge what the grid selected, as Export does.
    func testHDRMergeNeedsTwoOrMoreSelectedPhotos() {
        XCTAssertTrue(state().isEnabled(.photoMergeHDR))
        XCTAssertTrue(state { $0.selectionCount = 7 }.isEnabled(.photoMergeHDR))
        XCTAssertFalse(state { $0.selectionCount = 1 }.isEnabled(.photoMergeHDR), "one photo is no bracket")
        XCTAssertFalse(state { $0.selectionCount = 0; $0.hasSelection = false }.isEnabled(.photoMergeHDR))
        XCTAssertFalse(CommandState().isEnabled(.photoMergeHDR))
        for mode in [AppMode.loupe, .compare, .survey, .develop] {
            XCTAssertTrue(state { $0.mode = mode; $0.hasImage = true }.isEnabled(.photoMergeHDR), "\(mode)")
        }
        XCTAssertFalse(state { $0.editorReady = false }.isEnabled(.photoMergeHDR), "no GPU to merge with")
        XCTAssertFalse(state { $0.isEditingText = true }.isEnabled(.photoMergeHDR),
                       "⌃H deletes backward in a text field")
    }

    /// One full-size GPU job at a time: a merge and an export wait for each other.
    func testMergesAndExportsTakeTurns() {
        XCTAssertFalse(state { $0.exportQueueRunning = true }.isEnabled(.photoMergeHDR))
        XCTAssertFalse(state { $0.photoMergeRunning = true }.isEnabled(.photoMergeHDR))
        XCTAssertTrue(state().isEnabled(.export))
        XCTAssertFalse(state { $0.photoMergeRunning = true }.isEnabled(.export))

        let exports = ExportQueue()
        XCTAssertTrue(exports.claimSlot())
        XCTAssertTrue(exports.isGPUBusy)
        XCTAssertFalse(exports.claimSlot(), "the slot is taken")
        exports.releaseSlot()
        XCTAssertFalse(exports.isGPUBusy)
    }

    /// Lightroom's key, which nothing else in the table or the system has.
    func testTheShortcutIsControlH() throws {
        let shortcut = try XCTUnwrap(Shortcuts.shortcut(for: .photoMergeHDR))
        XCTAssertEqual(shortcut.key, .character("h"))
        XCTAssertEqual(shortcut.modifiers, .control)
        XCTAssertFalse(shortcut.isBare, "a menu key equivalent, not a single key")
        XCTAssertEqual(shortcut.glyphs, "⌃H")
        XCTAssertEqual(Shortcuts.menuTitle("HDR…", for: .photoMergeHDR), "HDR…")
        XCTAssertEqual(KeyCommand.command(for: BareKeyPress(.character("h"))), .heal, "H alone still heals")
    }
}

// MARK: - The dialog

@MainActor
final class HDRMergeSheetModelTests: XCTestCase {
    private func record(_ name: String, id: Int64) -> ImageRecord {
        ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: 1, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    private let root = URL(fileURLWithPath: "/Photos/Bracket", isDirectory: true)

    private func analysis(warnings: [HDRMergeWarning] = [], reference: Int = 1,
                          shifts: [Double?] = [nil, nil, nil]) -> HDRMergeAnalysis {
        // The engine hands the files back in exposure order, not the grid's.
        let names = ["DSC_0106.NEF", "DSC_0107.NEF", "DSC_0108.NEF"]
        let frames = names.enumerated().map { index, name in
            HDRMergeFrame(url: root.appendingPathComponent(name), exposureSeconds: [1.0 / 15, 1.0 / 60, 1.0 / 250][index],
                          iso: 100, aperture: 8, relativeEV: Double(-2 * index), exifRelativeEV: Double(-2 * index),
                          clippedFraction: 0, alignmentShiftPixels: shifts[index])
        }
        return HDRMergeAnalysis(frames: frames, referenceIndex: reference, width: 6016, height: 4016,
                                exposureRangeStops: 4, warnings: warnings, estimatedOutputBytes: 145_000_000)
    }

    /// Options remembered by one test only, never the user's own.
    nonisolated(unsafe) private var defaultsSuite = "latent-photo-merge-tests-\(UUID().uuidString)"

    override func tearDown() async throws {
        let suite = defaultsSuite
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }

    private func model(_ engine: FakeHDREngine, planned: String? = "DSC_0107-HDR.dng") -> (HDRMergeSheetModel, Recorder) {
        // The grid's order: darkest first.
        let records = [record("DSC_0108.NEF", id: 3), record("DSC_0106.NEF", id: 1), record("DSC_0107.NEF", id: 2)]
        let asked = Recorder()
        let model = HDRMergeSheetModel(records: records, urls: records.map { root.appendingPathComponent($0.relPath) },
                                       engine: engine, defaults: defaults) { reference in
            asked.names.append(reference.fileName)
            return planned
        }
        return (model, asked)
    }

    final class Recorder { var names: [String] = [] }

    func testAnalysingThenReady() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        engine.closeGate()
        let (model, asked) = model(engine, planned: "DSC_0107-HDR.dng")
        model.start()
        XCTAssertEqual(model.phase, .analysing)
        XCTAssertEqual(model.analysingText, "Analysing 3 photos…")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.phase, .analysing, "still reading")
        XCTAssertNil(model.analysisResult, "nothing to merge yet")

        engine.openGate()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(engine.log, ["analyse 3"])
        let rows = model.rows
        XCTAssertEqual(rows.map(\.fileName), ["DSC_0106.NEF", "DSC_0107.NEF", "DSC_0108.NEF"], "brightest first")
        XCTAssertEqual(rows.map(\.ev), ["+2 EV", "0 EV", "-2 EV"], "relative to the reference")
        XCTAssertEqual(rows.map(\.isReference), [false, true, false])
        XCTAssertEqual(rows.map { $0.record?.id }, [1, 2, 3], "matched to the grid's rows by file")
        XCTAssertEqual(rows[0].exposure, "1/15 s · ƒ/8 · ISO 100")
        XCTAssertEqual(rows[0].spoken, "DSC_0106.NEF, 1/15 s, ƒ/8, ISO 100, 2 stops brighter than the reference")
        XCTAssertEqual(rows[1].spoken, "DSC_0107.NEF, 1/60 s, ƒ/8, ISO 100, reference")
        XCTAssertEqual(model.sizeText, "6016 × 4016 (24.2 MP)")
        XCTAssertEqual(model.estimatedSizeText, "About 145 MB")
        XCTAssertEqual(model.destinationName, "DSC_0107-HDR.dng")
        XCTAssertEqual(asked.names, ["DSC_0107.NEF"], "named after the reference photo")
        XCTAssertEqual(model.referenceRecord?.id, 2)
        XCTAssertEqual(model.recordsInFrameOrder.map { $0?.id }, [1, 2, 3])
        XCTAssertEqual(model.warnings, [])
        XCTAssertNil(model.alignmentNote, "nothing moved")
        XCTAssertEqual(HDRMergeSheetModel.editsNotice,
                       "The merge starts from the original raw files. Edits you made to these photos aren’t used.")
    }

    func testWarningsInPlainWords() async {
        let engine = FakeHDREngine(analysis: .success(analysis(warnings: [
            .framesLookMisaligned(maximumShiftPixels: 3.4),
            .exposureMetadataDisagrees(frameIndex: 2, exifRelativeEV: -4, measuredRelativeEV: -4.7),
            .smallExposureRange(stops: 0.3),
            .frameCouldNotBeAligned(frameIndex: 0, leftOut: false),
            .frameCouldNotBeAligned(frameIndex: 2, leftOut: true),
        ])))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.warnings, [
            "These photos don’t line up exactly (up to 3 px apart), so edges may look doubled. "
                + "Turn on Auto Align to line them up.",
            "DSC_0108.NEF looks 0.7 stops darker than its camera settings say. Photo Merge uses the brightness it measured.",
            "These photos are only 0.3 stops apart, so the merge adds little. HDR works best with photos 2 stops apart.",
            "Photo Merge couldn’t align DSC_0106.NEF, but it looks close, so it’s merged as it is. "
                + "Edges may look slightly doubled.",
            "Photo Merge couldn’t align DSC_0108.NEF, so it’s left out of the merge.",
        ])
        XCTAssertTrue(HDRMergeSheetModel.text(for: .framesLookMisaligned(maximumShiftPixels: 0.2), frames: [])
            .contains("up to 1 px apart"), "never 0 px")
    }

    func testAnErrorReplacesTheList() async {
        let engine = FakeHDREngine(analysis: .failure(HDRMergeError.sameExposure))
        let (model, asked) = model(engine)
        model.start()
        await waitUntil("the error") { model.phase != .analysing }
        XCTAssertEqual(model.phase, .failed(HDRMergeError.sameExposure.errorDescription!))
        XCTAssertEqual(model.rows, [])
        XCTAssertNil(model.analysisResult, "Merge stays disabled")
        XCTAssertEqual(asked.names, [], "no name planned")

        struct Odd: Error {}
        let other = HDRMergeSheetModel.message(for: Odd())
        XCTAssertTrue(other.hasPrefix("These photos couldn’t be read for an HDR merge."), other)
        XCTAssertEqual(HDRMergeSheetModel.message(for: HDRMergeError.gpuUnavailable(reason: "out of memory")),
                       "The graphics processor couldn't run the merge: out of memory")
    }

    /// Auto Align on and Deghost None the first time, as Lightroom starts;
    /// after that, as they were last left.
    func testOptionsStartAsTheyWereLastLeft() {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        let (first, _) = model(engine)
        XCTAssertTrue(first.autoAlign)
        XCTAssertEqual(first.deghost, .none)
        XCTAssertEqual(first.options, HDRMergeOptions(deghost: .none, autoAlign: true))
        first.autoAlign = false
        first.deghost = .medium
        XCTAssertEqual(engine.log, [], "not started, so nothing is analysed")

        let (second, _) = model(engine)
        XCTAssertFalse(second.autoAlign)
        XCTAssertEqual(second.deghost, .medium)
        XCTAssertEqual(second.options, HDRMergeOptions(deghost: .medium, autoAlign: false))
    }

    /// Auto Align is measured by the analysis: turning it off measures the
    /// photos again, without aligning, and the dialog shows what that found.
    /// Deghost only matters to the merge, so changing it doesn't.
    func testTurningAutoAlignOffAnalysesAgain() async {
        let engine = FakeHDREngine(analysis: .success(analysis(shifts: [16.6, 0, 3.2])))
        let (model, asked) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.alignmentNote, "Photo Merge aligned these photos (up to 17 px).")
        XCTAssertEqual(model.warnings, [])

        engine.closeGate()
        model.deghost = .high
        XCTAssertNotNil(model.analysisResult, "Deghost doesn't analyse again")
        engine.setAnalysis(analysis(warnings: [.framesLookMisaligned(maximumShiftPixels: 16.6)]))
        model.autoAlign = false
        XCTAssertEqual(model.phase, .analysing)
        XCTAssertNil(model.alignmentNote)
        engine.openGate()
        await waitUntil("the second list") { model.analysisResult != nil }
        XCTAssertEqual(engine.log, ["analyse 3", "analyse 3 without aligning"])
        XCTAssertNil(model.alignmentNote)
        XCTAssertEqual(model.warnings.count, 1)
        XCTAssertTrue(model.warnings[0].contains("Turn on Auto Align"), model.warnings[0])
        XCTAssertEqual(asked.names, ["DSC_0107.NEF", "DSC_0107.NEF"])
        XCTAssertEqual(model.options, HDRMergeOptions(deghost: .high, autoAlign: false))
    }

    /// The note appears only for a shift worth mentioning, never as "0 px".
    func testTheAlignmentNote() async {
        for (shifts, note) in [([0.3, 0, 0.2], nil), ([nil, 0, nil], nil), ([0.6, 0, nil], "up to 1 px"),
                               ([2.5, 0, 1.1], "up to 3 px")] as [([Double?], String?)] {
            let engine = FakeHDREngine(analysis: .success(analysis(shifts: shifts)))
            let (model, _) = model(engine)
            model.start()
            await waitUntil("the list") { model.analysisResult != nil }
            XCTAssertEqual(model.alignmentNote, note.map { "Photo Merge aligned these photos (\($0))." }, "\(shifts)")
        }
    }

    /// A photo Auto Align gave up on is marked in the list, as the Panorama
    /// dialog marks one it couldn't join: the warning that explains it
    /// scrolls out of the notes box once there are a couple of them, so the
    /// list itself has to say so.
    func testAFrameLeftOutIsMarkedInTheList() async {
        let warnings: [HDRMergeWarning] = [.frameCouldNotBeAligned(frameIndex: 2, leftOut: true)]
        let engine = FakeHDREngine(analysis: .success(analysis(warnings: warnings)))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.rows.map(\.isLeftOut), [false, false, true])
        XCTAssertEqual(model.leftOutIndices, [2])
        XCTAssertTrue(model.rows[2].spoken.hasSuffix("left out of the merge"),
                      "VoiceOver says so too: \(model.rows[2].spoken)")
        XCTAssertFalse(model.rows[1].spoken.contains("left out"))
    }

    /// A photo the aligner only half managed is merged as it is, so it is
    /// not marked: the mark means "not in the merge".
    func testAFrameMergedUnalignedIsNotMarked() async {
        let warnings: [HDRMergeWarning] = [.frameCouldNotBeAligned(frameIndex: 2, leftOut: false)]
        let engine = FakeHDREngine(analysis: .success(analysis(warnings: warnings)))
        let (model, _) = model(engine)
        model.start()
        await waitUntil("the list") { model.analysisResult != nil }
        XCTAssertEqual(model.rows.map(\.isLeftOut), [false, false, false])
    }

    /// Closing the dialog while the photos are read stops the analysis and
    /// shows no error.
    func testCancellingWhileAnalysing() async throws {
        let engine = FakeHDREngine(analysis: .success(analysis()))
        engine.closeGate()
        let (model, _) = model(engine)
        model.start()
        try await Task.sleep(for: .milliseconds(30))
        model.cancel()
        engine.openGate()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.phase, .analysing)
    }

    /// The app builds the real engine, not a stand-in.
    func testTheAppUsesTheRealEngine() async throws {
        let gpu = try await GPUContext.shared()
        XCTAssertTrue(PhotoMergeEngine.hdr(gpu: gpu) is HDRMerger)
    }

    func testStops() {
        XCTAssertEqual(HDRMergeSheetModel.evText(2), "+2 EV")
        XCTAssertEqual(HDRMergeSheetModel.evText(-2.0001), "-2 EV")
        XCTAssertEqual(HDRMergeSheetModel.evText(0.02), "0 EV")
        XCTAssertEqual(HDRMergeSheetModel.evText(-0.67), "-0.7 EV")
        XCTAssertEqual(HDRMergeSheetModel.spokenEV(-1), "1 stop darker than the reference")
        XCTAssertEqual(HDRMergeSheetModel.spokenEV(0), "same exposure as the reference")
        XCTAssertEqual(HDRMergeSheetModel.stopsText(1), "1 stop")
    }
}

// MARK: - The job

@MainActor
final class PhotoMergeJobTests: XCTestCase {
    nonisolated(unsafe) var folder: BracketFolder?

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
    }

    private func bracket() async throws -> BracketFolder {
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

    /// The sidecar goes in before the DNG exists; then the DNG; then the
    /// folder is read again and the result selected, holding the GPU slot,
    /// a job and a keep-awake activity until it ends.
    func testASuccessfulMergeCommitsInOrderAndSelectsTheResult() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()))
        let jobs = OutputJobs()
        let exports = ExportQueue()
        let queue = queue(jobs, exports: exports)
        let held = ExportActivity.activeCount
        XCTAssertTrue(queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine))
        XCTAssertTrue(queue.isRunning)
        XCTAssertEqual(jobs.running.map(\.kind), [.photoMerge])
        XCTAssertEqual(ExportActivity.activeCount, held + 1)
        XCTAssertTrue(exports.isGPUBusy, "exports wait")
        XCTAssertFalse(queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine),
                       "one merge at a time")

        await queue.waitUntilDone()
        XCTAssertEqual(engine.log.filter { !$0.hasPrefix("analyse") }, [
            "before sidecar: sidecar false, dng false",
            "after sidecar: sidecar true, dng false",
            "wrote DSC_0107-HDR.dng",
        ])
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0107-HDR.dng"])
        XCTAssertEqual(try bracket.files(), (BracketFolder.names + ["DSC_0107-HDR.dng"]).sorted())

        // The recipe: sources beside the result, the catalog's hashes and capture times.
        let sources = try XCTUnwrap(engine.sources.first)
        XCTAssertEqual(sources.map(\.path), BracketFolder.names)
        XCTAssertEqual(sources.map(\.hash), bracket.records.map { $0.hashString.replacingOccurrences(of: "xxh64:", with: "") })
        XCTAssertTrue(sources.allSatisfy { $0.hash.count == 16 })
        XCTAssertEqual(sources.map(\.captureTime), bracket.records.map { $0.captureTime ?? -1 })
        let stored = try XMPSidecar.read(from: bracket.sidecar("DSC_0107-HDR.dng")).mergeJSON
        XCTAssertEqual(try MergeRecipe(jsonData: Data(stored.utf8)), engine.recipes.first)

        let result = try XCTUnwrap(bracket.library.images.first { $0.fileName == "DSC_0107-HDR.dng" },
                                   "catalogued by the refresh")
        XCTAssertEqual(bracket.library.selectedImageID, result.id)
        XCTAssertEqual(bracket.library.selectedImageIDs, [result.id!])
        let recipe = try await bracket.library.mergeRecipe(for: result)
        XCTAssertNotNil(recipe, "the waiting sidecar gave the new row its recipe")
        XCTAssertTrue(queue.summary.hasPrefix("Merged DSC_0107-HDR.dng in "), queue.summary)
        XCTAssertNil(bracket.library.lastError)
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(jobs.isRunning)
        XCTAssertFalse(exports.isGPUBusy)
        XCTAssertEqual(ExportActivity.activeCount, held)
    }

    /// The dialog's options reach the engine's merge unchanged.
    func testTheOptionsReachTheMerge() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()))
        let queue = queue()
        let options = HDRMergeOptions(deghost: .medium, autoAlign: false)
        XCTAssertTrue(queue.start(bracket.analysis(), options: options, records: bracket.records,
                                  library: bracket.library, engine: engine))
        await queue.waitUntilDone()
        XCTAssertEqual(engine.mergeOptions, [options])
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0107-HDR.dng"])
    }

    /// A filter that would hide the result is cleared, so it can be seen.
    func testTheResultIsRevealedThroughAFilter() async throws {
        let bracket = try await bracket()
        bracket.library.filter.minRating = 3
        XCTAssertTrue(bracket.library.visibleImages.isEmpty)
        let queue = queue()
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library,
                    engine: FakeHDREngine(analysis: .success(bracket.analysis())))
        await queue.waitUntilDone()
        let id = try XCTUnwrap(bracket.library.images.first { $0.fileName == "DSC_0107-HDR.dng" }?.id)
        XCTAssertFalse(bracket.library.filter.isActive)
        XCTAssertTrue(bracket.library.visibleImages.contains { $0.id == id })
        XCTAssertEqual(bracket.library.selectedImageID, id)
    }

    /// A name is taken by a file, by a sidecar a file left behind, or by a
    /// row: the stale sidecar alone is enough to move the result on.
    func testAStaleSidecarMovesTheNameOn() async throws {
        let bracket = try await bracket()
        let stale = bracket.sidecar("DSC_0107-HDR.dng")
        try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8).write(to: stale)
        let queue = queue()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()))
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0107-HDR-2.dng"])
        XCTAssertEqual(try bracket.files(), (BracketFolder.names + ["DSC_0107-HDR-2.dng"]).sorted())
        XCTAssertEqual(try String(contentsOf: stale, encoding: .utf8), "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>",
                       "someone else's sidecar is left alone")
        XCTAssertEqual(bracket.library.selectedImage?.fileName, "DSC_0107-HDR-2.dng")
    }

    /// A failed merge takes its sidecar back and says why in the status bar.
    func testAFailedMergeLeavesNothingAndReportsTheError() async throws {
        let bracket = try await bracket()
        let error = HDRMergeError.notEnoughDiskSpace(neededBytes: 300_000_000, availableBytes: 1_000_000)
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()), script: .fail(error))
        let jobs = OutputJobs()
        let queue = queue(jobs)
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        await queue.waitUntilDone()
        await bracket.library.waitForPendingWork()
        XCTAssertTrue(engine.log.contains("after sidecar: sidecar true, dng false"))
        XCTAssertFalse(FakeHDREngine.exists(bracket.sidecar("DSC_0107-HDR.dng")), "the sidecar is taken back")
        XCTAssertEqual(try bracket.files(), BracketFolder.names, "no DNG, nothing stray")
        XCTAssertEqual(bracket.library.lastError, "HDR merge failed: \(error.errorDescription!)")
        XCTAssertEqual(queue.summary, "")
        XCTAssertFalse(jobs.isRunning)
        XCTAssertFalse(queue.gpuSlot.isGPUBusy)
    }

    /// Cancel from the panel: no DNG, no sidecar, and no error shown.
    func testACancelledMergeLeavesNothing() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()), script: .waitForCancel)
        let queue = queue()
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        let sidecar = bracket.sidecar("DSC_0107-HDR.dng")
        await waitUntil("the sidecar") { FakeHDREngine.exists(sidecar) }
        queue.cancel()
        await queue.waitUntilDone()
        XCTAssertFalse(FakeHDREngine.exists(sidecar))
        XCTAssertEqual(try bracket.files(), BracketFolder.names)
        XCTAssertNil(bracket.library.lastError)
        XCTAssertEqual(queue.summary, "HDR merge cancelled")
    }

    /// An engine that leaves its DNG behind and throws anyway: the file is
    /// taken away with the sidecar, so a half-made result is never catalogued.
    func testADNGLeftByAThrowingEngineIsRemoved() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()), script: .writeThenFail)
        let queue = queue()
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(try bracket.files(), BracketFolder.names)
        XCTAssertFalse(FakeHDREngine.exists(bracket.sidecar("DSC_0107-HDR.dng")))
        XCTAssertNotNil(bracket.library.lastError)
    }

    /// Another file takes the name while the pixels are merged: that file
    /// keeps it, the merge's sidecar isn't left beside it, and the merge
    /// goes to the next name.
    func testANameTakenAtTheLastMomentPlansANewOne() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()), script: .nameTakenOnce)
        let queue = queue()
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(engine.destinations.map(\.lastPathComponent), ["DSC_0107-HDR.dng", "DSC_0107-HDR-2.dng"])
        XCTAssertEqual(try String(contentsOf: bracket.root.appendingPathComponent("DSC_0107-HDR.dng"), encoding: .utf8),
                       "another app", "the other file is kept")
        XCTAssertFalse(FakeHDREngine.exists(bracket.sidecar("DSC_0107-HDR.dng")),
                       "the other file doesn't get the merge's recipe")
        XCTAssertTrue(FakeHDREngine.exists(bracket.sidecar("DSC_0107-HDR-2.dng")))
        XCTAssertEqual(bracket.library.selectedImage?.fileName, "DSC_0107-HDR-2.dng")
        XCTAssertNil(bracket.library.lastError)
    }

    /// Quitting asks, as for exports and contact sheets, then stops the
    /// merge and waits for it to tidy up before the app goes
    /// (`AppDelegate.applicationShouldTerminate` does these steps).
    func testQuittingStopsTheMergeAndWaitsForItToTidyUp() async throws {
        let bracket = try await bracket()
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()), script: .waitForCancel)
        let jobs = OutputJobs()
        let queue = queue(jobs)
        let held = ExportActivity.activeCount
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        let sidecar = bracket.sidecar("DSC_0107-HDR.dng")
        await waitUntil("the sidecar") { FakeHDREngine.exists(sidecar) }

        XCTAssertTrue(jobs.isRunning)
        let text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still making an HDR merge")
        XCTAssertEqual(text.information, "Quitting now stops the HDR merge, which leaves no photo.")
        XCTAssertEqual(text.button, "Stop and Quit")

        jobs.cancelAll()
        await jobs.waitUntilDone()
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(FakeHDREngine.exists(sidecar), "tidied before the wait ends")
        XCTAssertEqual(try bracket.files(), BracketFolder.names)
        XCTAssertFalse(bracket.library.hasPendingWork)
        XCTAssertEqual(ExportActivity.activeCount, held)
    }

    /// The engine reports from any thread; the panel sees each report on
    /// the main thread, in order.
    func testProgressArrivesOnTheMainThread() async throws {
        let bracket = try await bracket()
        let reports = (1...5).map { HDRMergeProgress(fraction: Double($0) / 5, stage: "Merging photo \($0) of 5") }
        let engine = FakeHDREngine(analysis: .success(bracket.analysis()), reports: reports)
        let queue = queue()
        var seen: [MergeProgress] = []
        var offMain = 0
        let watch = queue.$progress.dropFirst().sink { progress in
            if !Thread.isMainThread { offMain += 1 }
            if let progress { seen.append(progress) }
        }
        defer { watch.cancel() }
        queue.start(bracket.analysis(), records: bracket.records, library: bracket.library, engine: engine)
        await queue.waitUntilDone()
        XCTAssertEqual(seen, reports.map(MergeProgress.init), "the engine's reports, in order")
        XCTAssertEqual(offMain, 0)
        XCTAssertEqual(PhotoMergeQueue.spokenProgress(MergeProgress(reports[1])), "Merging photo 2 of 5, 40 percent")
        XCTAssertEqual(PhotoMergeQueue.spokenProgress(nil), "Starting")
    }

    /// An export holding the GPU refuses the merge, and the other way round.
    func testAMergeWaitsForTheExportQueue() async throws {
        let bracket = try await bracket()
        let exports = ExportQueue()
        XCTAssertTrue(exports.claimSlot())
        let jobs = OutputJobs()
        let queue = queue(jobs, exports: exports)
        XCTAssertFalse(queue.start(bracket.analysis(), records: bracket.records, library: bracket.library,
                                   engine: FakeHDREngine(analysis: .success(bracket.analysis()))))
        XCTAssertFalse(queue.isRunning)
        XCTAssertFalse(jobs.isRunning)
        exports.releaseSlot()
    }

    func testRecipePathsAreRelativeToTheResult() {
        XCTAssertEqual(PhotoMergeQueue.relativePath("A.NEF", fromFolderOf: "A-HDR.dng"), "A.NEF")
        XCTAssertEqual(PhotoMergeQueue.relativePath("Day 2/A.NEF", fromFolderOf: "Day 2/A-HDR.dng"), "A.NEF")
        XCTAssertEqual(PhotoMergeQueue.relativePath("Day 3/B.NEF", fromFolderOf: "Day 2/A-HDR.dng"), "../Day 3/B.NEF")
        XCTAssertEqual(PhotoMergeQueue.relativePath("B.NEF", fromFolderOf: "Day 2/Sub/A-HDR.dng"), "../../B.NEF")
        XCTAssertEqual(PhotoMergeQueue.relativePath("Day 2/Sub/B.NEF", fromFolderOf: "A-HDR.dng"), "Day 2/Sub/B.NEF")
    }

    /// The quit alert names every kind of job under way.
    func testTheQuitAlertCombinesMergesWithPrintsAndContactSheets() {
        let jobs = OutputJobs()
        _ = jobs.begin(.print, name: "12 Photos")
        _ = jobs.begin(.contactSheet, name: "Sheet.pdf")
        _ = jobs.begin(.photoMerge, name: "DSC_0107.NEF")
        let text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still printing “12 Photos”, making a contact sheet and making an HDR merge")
        XCTAssertEqual(text.information, "Quitting now stops the contact sheet, which isn’t saved, and the HDR merge, "
                       + "which leaves no photo, and waits for the print to reach the printing system, then quits.")
        XCTAssertEqual(text.button, "Finish Printing and Quit")
        for job in jobs.running { jobs.end(job.id) }
    }
}
