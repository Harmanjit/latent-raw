import XCTest
import AppKit
@testable import Catalog
import PixelEngine
@testable import MLKit
@testable import latent_app

/// A render the test lets finish, recording when it starts and ends.
final class GatedRenders: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Set<Int> = []
    private var log: [String] = []

    var events: [String] { lock.withLock { log } }

    func release(_ key: Int) { lock.withLock { _ = open.insert(key) } }

    /// Waits for `release(key)`, stopping early (throwing) when cancelled.
    func render(_ key: Int) async throws -> Int {
        lock.withLock { log.append("start \(key)") }
        while !lock.withLock({ open.contains(key) }) {
            guard !Task.isCancelled else {
                lock.withLock { log.append("cancelled \(key)") }
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        lock.withLock { log.append("end \(key)") }
        return key
    }
}

@MainActor
func waitUntil(_ what: String, seconds: Double = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "timed out waiting for \(what)")
}

/// The export sheet's one shared render: callers of a key share it, a
/// render someone waits for isn't cancelled, and renders never overlap.
@MainActor
final class SharedRenderTests: XCTestCase {
    /// The quality comparison waits on the render; the size estimate
    /// moves on to other settings. The comparison still gets its render,
    /// and the estimate's starts only once that one has ended.
    func testARenderSomeoneWaitsForIsFinishedAndTheNextWaitsForIt() async throws {
        let shared = SharedRender<Int, Int>()
        let gates = GatedRenders()
        let compare = Task { try await shared.value(for: 1) { try await gates.render(1) } }
        let estimate = Task { try await shared.value(for: 1) { try await gates.render(1) } }
        await waitUntil("the first render") { gates.events == ["start 1"] }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(shared.started, 1, "one render for both")

        estimate.cancel()
        let next = Task { try await shared.value(for: 2) { try await gates.render(2) } }
        gates.release(2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gates.events, ["start 1"], "the next render waits for the one under way")

        gates.release(1)
        let compared = try await compare.value
        XCTAssertEqual(compared, 1)
        let second = try await next.value
        XCTAssertEqual(second, 2)
        XCTAssertEqual(gates.events, ["start 1", "end 1", "start 2", "end 2"])
        let cached = try await shared.value(for: 2) { XCTFail("rendered again"); return 0 }
        XCTAssertEqual(cached, 2)
    }

    /// Closing the comparison while the estimate's next render waits on
    /// its render stops that render, and the next one starts.
    func testASupersededRenderStopsWhenItsLastCallerStopsWaiting() async throws {
        let shared = SharedRender<Int, Int>()
        let gates = GatedRenders()
        let compare = Task { try await shared.value(for: 1) { try await gates.render(1) } }
        await waitUntil("the first render") { gates.events == ["start 1"] }
        let next = Task { try await shared.value(for: 2) { try await gates.render(2) } }
        gates.release(2)
        try await Task.sleep(for: .milliseconds(50))
        compare.cancel()
        await waitUntil("the next render") { gates.events.contains("end 2") }
        XCTAssertEqual(gates.events, ["start 1", "cancelled 1", "start 2", "end 2"])
        gates.release(1)
        let second = try await next.value
        XCTAssertEqual(second, 2)
    }

    /// A render nobody waits for any more is stopped when another is asked for.
    func testARenderNobodyWaitsForIsCancelled() async throws {
        let shared = SharedRender<Int, Int>()
        let gates = GatedRenders()
        let estimate = Task { try await shared.value(for: 1) { try await gates.render(1) } }
        await waitUntil("the first render") { gates.events == ["start 1"] }
        estimate.cancel()
        gates.release(2)
        let next = try await shared.value(for: 2) { try await gates.render(2) }
        XCTAssertEqual(next, 2)
        XCTAssertEqual(gates.events, ["start 1", "cancelled 1", "start 2", "end 2"])
        do {
            _ = try await estimate.value
            XCTFail("the cancelled caller has no render")
        } catch is CancellationError {
        }
    }
}

/// Stand-ins for `ExportWorker.render` results.
enum FakeRendered {
    static func make(width: Int = 64, height: Int = 48) -> ExportWorker.Rendered {
        var metadata = ExportMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)   // 2023
        metadata.keywords = ["k"]
        return ExportWorker.Rendered(
            image: Exporter.EncodableImage(image: FakeRenders.solid((0, 0, 0), width: width, height: height)),
            metadata: metadata, settings: ExportSettings(), masksGenerated: 0, phases: [], start: Date(),
            colorSpace: .sRGB, sourceName: "DSC_1", readMetadata: metadata)
    }

    static func record() -> ImageRecord {
        ImageRecord(id: 7, relPath: "A/DSC_1.NEF", preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }
}

final class PresetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [ExportPreset] = []
    var presets: [ExportPreset] { lock.withLock { log } }
    func append(_ preset: ExportPreset) { lock.withLock { log.append(preset) } }
}

@MainActor
final class ExportPreviewRendererTests: XCTestCase {
    /// Typing a watermark or switching metadata encodes again but doesn't
    /// render: the render is made without either and finished per caller.
    func testWatermarkAndMetadataDontRenderAgain() async throws {
        let asked = PresetLog()
        let renderer = ExportPreviewRenderer { _, preset in
            asked.append(preset)
            return FakeRendered.make()
        }
        let record = FakeRendered.record()
        var preset = ExportPreset()
        let plain = try await renderer.rendered(record, preset: preset)
        XCTAssertNil(plain.settings.watermark)
        XCTAssertNotNil(plain.metadata)

        preset.watermarkEnabled = true
        preset.watermark = ExportWatermark(text: "© {year} {name}", corner: .bottomLeft, size: 0.2, opacity: 1)
        preset.watermark.red = 1; preset.watermark.green = 1; preset.watermark.blue = 1
        let marked = try await renderer.rendered(record, preset: preset)
        XCTAssertEqual(marked.settings.watermark?.text, "© 2023 DSC_1")
        let before = try XCTUnwrap(plain.image.image.dataProvider?.data) as Data
        let after = try XCTUnwrap(marked.image.image.dataProvider?.data) as Data
        XCTAssertNotEqual(before, after, "the watermark is stamped")
        preset.watermarkEnabled = false
        let clean = try await renderer.rendered(record, preset: preset)
        XCTAssertEqual(try XCTUnwrap(clean.image.image.dataProvider?.data) as Data, before,
                       "into a copy: the kept render stays clean")
        preset.watermarkEnabled = true

        preset.includeLocation = true
        let located = try await renderer.rendered(record, preset: preset)
        XCTAssertEqual(located.metadata?.includeLocation, true)
        preset.includeMetadata = false
        let bare = try await renderer.rendered(record, preset: preset)
        XCTAssertNil(bare.metadata)
        XCTAssertEqual(renderer.renderCount, 1)
        XCTAssertTrue(asked.presets.allSatisfy { !$0.watermarkEnabled && $0.includeMetadata && $0.includeLocation })

        preset.resize = true
        _ = try await renderer.rendered(record, preset: preset)
        XCTAssertEqual(renderer.renderCount, 2, "a new size is a new render")
    }
}

final class EncodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var peak = 0
    private var count = 0
    var maximumAtOnce: Int { lock.withLock { peak } }
    var started: Int { lock.withLock { count } }

    func encode() -> Int {
        lock.withLock { running += 1; count += 1; peak = max(peak, running) }
        Thread.sleep(forTimeInterval: 0.35)
        lock.withLock { running -= 1 }
        return 1000
    }
}

@MainActor
final class QualityCompareModelTests: XCTestCase {
    /// The render the window waits on is let go by the sheet: the window
    /// asks again rather than spinning for good.
    func testARenderStoppedUnderTheWindowIsAskedForAgain() async throws {
        let gates = GatedRenders()
        let calls = PresetLog()
        let renderer = ExportPreviewRenderer { _, preset in
            calls.append(preset)
            _ = try await gates.render(calls.presets.count)
            return FakeRendered.make()
        }
        let model = QualityCompareModel(renderer: renderer, record: FakeRendered.record(), preset: ExportPreset()) { _ in }
        model.encodedSize = { _, _ in 1000 }
        model.start()
        await waitUntil("the render") { gates.events == ["start 1"] }
        renderer.discard()
        gates.release(2)
        await waitUntil("the window's render", seconds: 5) { model.phase == .ready }
        XCTAssertEqual(gates.events, ["start 1", "cancelled 1", "start 2", "end 2"])
        model.stop()
    }

    /// Moving a pane's quality in steps doesn't start a whole-file encode
    /// beside one still running: they take turns.
    func testSizeEncodesTakeTurns() async throws {
        let renderer = ExportPreviewRenderer { _, _ in FakeRendered.make() }
        let model = QualityCompareModel(renderer: renderer, record: FakeRendered.record(), preset: ExportPreset()) { _ in }
        let encodes = EncodeLog()
        model.encodedSize = { _, _ in encodes.encode() }
        model.start()
        await waitUntil("the render") { model.phase == .ready }
        await waitUntil("the first encode") { encodes.started == 1 }
        let pane = try XCTUnwrap(model.panes.first)
        for step in 1...3 {
            model.setQuality(0.30 + Float(step) / 100, forPane: pane.id)
            try await Task.sleep(for: .milliseconds(300))
        }
        await waitUntil("the sizes", seconds: 10) { model.panes.allSatisfy { model.sizes[QualityCompareModel.key($0.quality)] != nil } }
        XCTAssertEqual(encodes.maximumAtOnce, 1)
        model.stop()
    }
}

@MainActor
final class Flag {
    var value = false
}

@MainActor
final class OutputJobsTests: XCTestCase {
    func testAJobHoldsOffSleepUntilItEnds() async {
        let jobs = OutputJobs()
        let held = ExportActivity.activeCount
        var stopped = false
        let print = jobs.begin(.print, name: "12 Photos")
        let sheet = jobs.begin(.contactSheet, name: "Trip Contact Sheet.pdf") { stopped = true }
        XCTAssertTrue(jobs.isRunning)
        XCTAssertEqual(ExportActivity.activeCount, held + 2)
        jobs.cancelAll()
        XCTAssertTrue(stopped)

        let waited = Flag()
        let waiter = Task { await jobs.waitUntilDone(); waited.value = true }
        jobs.end(sheet)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(waited.value, "the print still runs")
        jobs.end(print)
        await waiter.value
        XCTAssertTrue(waited.value)
        XCTAssertFalse(jobs.isRunning)
        XCTAssertEqual(ExportActivity.activeCount, held)
    }

    func testQuitAlertSaysWhatHappensToEachJob() {
        let jobs = OutputJobs()
        _ = jobs.begin(.contactSheet, name: "Sheet.pdf")
        var text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still making a contact sheet")
        XCTAssertEqual(text.button, "Stop and Quit")
        _ = jobs.begin(.print, name: "12 Photos")
        text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still printing “12 Photos” and making a contact sheet")
        XCTAssertTrue(text.information.contains("isn’t saved"))
        XCTAssertTrue(text.information.contains("printing system"))
        XCTAssertEqual(text.button, "Finish Printing and Quit")
        for job in jobs.running { jobs.end(job.id) }
    }

    /// Remove Dust and Find Faces are jobs like a merge: the keep-awake
    /// reason names the first photo, and the quit alert says that stopping
    /// keeps the photos already done.
    func testDustRemovalAndFaceSearchAreJobsQuittingStops() {
        let jobs = OutputJobs()
        var stopped: [String] = []
        let dust = jobs.begin(.dustRemoval, name: "DSC_0107.NEF") { stopped.append("dust") }
        var text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still removing sensor dust from photos")
        XCTAssertEqual(text.information, "Quitting now stops the dust removal, which keeps the photos already done.")
        XCTAssertEqual(text.button, "Stop and Quit")
        jobs.end(dust)

        let faces = jobs.begin(.findFaces, name: "DSC_0107.NEF") { stopped.append("faces") }
        text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still finding faces for touch-up")
        XCTAssertEqual(text.information, "Quitting now stops the face search, which keeps the photos already done.")
        XCTAssertEqual(text.button, "Stop and Quit")

        // Beside a print and a merge, in the order the message names them.
        _ = jobs.begin(.print, name: "12 Photos")
        _ = jobs.begin(.photoMerge, name: "DSC_0106.NEF")
        text = OutputJobs.quitAlert(for: jobs.running)
        XCTAssertEqual(text.message, "Latent is still printing “12 Photos”, making an HDR merge and finding faces for touch-up")
        XCTAssertEqual(text.information, "Quitting now stops the HDR merge, which leaves no photo, and the face search, "
                       + "which keeps the photos already done, and waits for the print to reach the printing system, then quits.")
        XCTAssertEqual(text.button, "Finish Printing and Quit")
        jobs.cancelAll()
        XCTAssertEqual(stopped, ["faces"])
        XCTAssertTrue(jobs.running.contains { $0.id == faces })
        for job in jobs.running { jobs.end(job.id) }
        XCTAssertFalse(jobs.isRunning)
    }

    /// Files don't move or change name under a print or contact sheet.
    func testFileCommandsWaitForPrintsAndContactSheets() {
        var state = CommandState()
        state.mode = .library
        state.hasSelection = true
        state.selectionCount = 1
        XCTAssertTrue(state.isEnabled(.rename))
        XCTAssertTrue(state.isEnabled(.moveToFolder))
        state.outputJobRunning = true
        XCTAssertFalse(state.isEnabled(.rename))
        XCTAssertFalse(state.isEnabled(.moveToFolder))
        XCTAssertFalse(state.isEnabled(.copyToFolder))
    }

    /// A contact sheet counts from Save until it is written or stopped, and
    /// quitting's cancel stops it.
    func testAContactSheetSaveIsAJobUntilItEnds() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        // Slow enough that the save is still going when it is stopped.
        let slow = SheetRenderer(cache: SheetImageCache(byteBudget: 1 << 20)) { _, longEdge in
            Thread.sleep(forTimeInterval: 0.05)
            return FakeRenders.solid((1, 0, 0), width: longEdge, height: longEdge)
        }
        let model = ContactSheetModel(items: FakeRenders.items((0..<40).map { "r\($0)" }), title: "Trip",
                                      thumbnails: FakeRenders.thumbnails, previewRenderer: nil,
                                      makeRenderer: { _ in slow }, store: nil)
        let held = ExportActivity.activeCount
        var result: Error??
        model.save(to: scratch.url.appendingPathComponent("Trip.pdf")) { result = .some($0) }
        XCTAssertEqual(OutputJobs.shared.running.map(\.kind), [.contactSheet])
        XCTAssertGreaterThan(ExportActivity.activeCount, held)
        OutputJobs.shared.cancelAll()
        await waitUntil("the save to stop") { result != nil }
        guard case ContactSheetWriter.Failure.cancelled? = result ?? nil else { return XCTFail("\(String(describing: result))") }
        XCTAssertFalse(OutputJobs.shared.isRunning)
        XCTAssertEqual(ExportActivity.activeCount, held)
        model.close()
    }
}
