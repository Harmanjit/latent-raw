import XCTest
import ImageIO
@testable import MLKit
@testable import PixelEngine
import ColorKit

/// Several photos at once (ExportPipeline, ExportConcurrency;
/// docs/Performance-Plan.md #19): results in the batch's order, never more
/// than the workers asked for, retries, pause and cancel, the machine
/// limit, and files identical to a one-at-a-time export.
final class ExportPipelineTests: XCTestCase {
    /// Counts how many jobs run at once.
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var peak = 0
        private(set) var total = 0
        func enter() { lock.withLock { running += 1; total += 1; peak = max(peak, running) } }
        func leave() { lock.withLock { running -= 1 } }
        var current: Int { lock.withLock { running } }
    }

    /// Jobs that finish out of order (later ones sooner) still commit in
    /// order, and no more than `workers` run at once.
    func testCommitsInOrderWithAtMostWorkersRunning() async {
        for workers in [1, 2, 4] {
            let gauge = Gauge()
            var next = 0
            var committed: [Int] = []
            await ExportPipeline.run(
                workers: workers,
                next: { () async -> ExportPipeline.Step<Int, Int>? in
                    guard next < 12 else { return nil }
                    defer { next += 1 }
                    // Every fifth settles without work, as a skipped file does.
                    return next % 5 == 3 ? .done(next) : .run(next)
                },
                work: { n in
                    gauge.enter()
                    try? await Task.sleep(for: .milliseconds(5 + (12 - n) * 2))
                    gauge.leave()
                    return n
                },
                commit: { committed.append($0) })
            XCTAssertEqual(committed, Array(0..<12), "\(workers) workers")
            XCTAssertLessThanOrEqual(gauge.peak, workers)
            if workers > 1 { XCTAssertGreaterThan(gauge.peak, 1, "jobs overlapped") }
            XCTAssertEqual(gauge.current, 0)
        }
    }

    /// A result can send its photo round again (a name taken meanwhile);
    /// it is committed once, in its place.
    func testRetryRunsThePhotoAgainInItsPlace() async {
        var next = 0
        var committed: [String] = []
        var retried = 0
        await ExportPipeline.run(
            workers: 3,
            next: { () async -> ExportPipeline.Step<String, String>? in
                guard next < 4 else { return nil }
                defer { next += 1 }
                return .run("\(next)")
            },
            work: { job in job },
            retry: { output in
                guard output == "1" else { return nil }
                retried += 1
                return .run("1-again")
            },
            commit: { committed.append($0) })
        XCTAssertEqual(committed, ["0", "1-again", "2", "3"])
        XCTAssertEqual(retried, 1)
    }

    /// Held (paused), the run starts nothing new but still commits what was
    /// under way; cancelled, it starts nothing more and waits for the
    /// photos already started, which are committed before it returns.
    func testHoldAndCancelLetStartedPhotosFinish() async {
        let gauge = Gauge()
        let task = Task { () -> [Int] in
            var next = 0
            var committed: [Int] = []
            await ExportPipeline.run(
                workers: 3,
                next: { () async -> ExportPipeline.Step<Int, Int>? in
                    guard next < 100, !Task.isCancelled else { return nil }
                    defer { next += 1 }
                    return .run(next)
                },
                work: { n in
                    gauge.enter()
                    try? await Task.sleep(for: .milliseconds(40))
                    gauge.leave()
                    return n
                },
                commit: { committed.append($0) })
            return committed
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let committed = await task.value
        XCTAssertEqual(gauge.current, 0, "nothing still running when run returns")
        XCTAssertEqual(committed, Array(0..<committed.count), "in order, with no gaps")
        XCTAssertEqual(committed.count, gauge.total, "every photo started was committed")
        XCTAssertLessThan(committed.count, 100, "stopped early")
        XCTAssertGreaterThan(committed.count, 0)

        // Held from the start after the first photo: the others wait until
        // the hold lifts.
        var holding = true
        var next = 0
        var order: [String] = []
        await ExportPipeline.run(
            workers: 3,
            hold: { holding },
            next: { () async -> ExportPipeline.Step<Int, Int>? in
                guard next < 3 else { return nil }
                defer { next += 1 }
                order.append("start \(next)")
                return .run(next)
            },
            work: { n in n },
            commit: { n in
                order.append("commit \(n)")
                holding = false
            })
        XCTAssertEqual(order, ["start 0", "commit 0", "start 1", "start 2", "commit 1", "commit 2"])
    }

    // MARK: The limit

    private let mac16 = ExportConcurrency.Machine(physicalMemory: 16 << 30, gpuWorkingSet: 11_453_251_584,
                                                  activeCores: 10)

    func testLimitFollowsMemoryPhotoSizeAndCap() {
        let full24 = ExportConcurrency.limit(machine: mac16, sourceMegapixels: 24.3, outputMegapixels: 24.3)
        let full45 = ExportConcurrency.limit(machine: mac16, sourceMegapixels: 45.7, outputMegapixels: 45.7)
        let small24 = ExportConcurrency.limit(machine: mac16, sourceMegapixels: 24.3, outputMegapixels: 2.8)
        XCTAssertGreaterThanOrEqual(full24, 2, "a 16 GB Mac takes at least the recommended 2")
        XCTAssertLessThan(full45, full24, "bigger photos lower the limit")
        XCTAssertGreaterThanOrEqual(small24, full24, "a small file needs less")
        // All in flight together stay within a quarter of the memory.
        let perPhoto = ExportConcurrency.perPhotoBytes(sourceMegapixels: 45.7, outputMegapixels: 45.7)
        XCTAssertLessThanOrEqual(UInt64(full45) * perPhoto, UInt64(16 << 30) / 4)

        let mac8 = ExportConcurrency.Machine(physicalMemory: 8 << 30, gpuWorkingSet: 5_726_623_744, activeCores: 8)
        XCTAssertLessThan(ExportConcurrency.limit(machine: mac8, sourceMegapixels: 24.3, outputMegapixels: 24.3),
                          full24 + 1)
        XCTAssertEqual(ExportConcurrency.limit(machine: mac8, sourceMegapixels: 400, outputMegapixels: 400), 1,
                       "never below one")
        let studio = ExportConcurrency.Machine(physicalMemory: 192 << 30, gpuWorkingSet: 150 << 30, activeCores: 24)
        XCTAssertEqual(ExportConcurrency.limit(machine: studio, sourceMegapixels: 24, outputMegapixels: 24),
                       ExportConcurrency.hardCap)
        let twoCores = ExportConcurrency.Machine(physicalMemory: 64 << 30, gpuWorkingSet: 0, activeCores: 2)
        XCTAssertEqual(ExportConcurrency.limit(machine: twoCores, sourceMegapixels: 24, outputMegapixels: 24), 1,
                       "one photo per two cores")
    }

    func testChoiceIsClampedToTheLimit() {
        XCTAssertEqual(ExportConcurrency.resolve(choice: ExportConcurrency.automaticChoice, limit: 5).workers,
                       ExportConcurrency.measuredBest)
        XCTAssertEqual(ExportConcurrency.resolve(choice: ExportConcurrency.automaticChoice, limit: 1).workers, 1)
        XCTAssertFalse(ExportConcurrency.resolve(choice: ExportConcurrency.automaticChoice, limit: 1).clamped)
        XCTAssertEqual(ExportConcurrency.resolve(choice: 3, limit: 5).workers, 3)
        XCTAssertFalse(ExportConcurrency.resolve(choice: 3, limit: 5).clamped)
        XCTAssertEqual(ExportConcurrency.resolve(choice: 6, limit: 2).workers, 2)
        XCTAssertTrue(ExportConcurrency.resolve(choice: 6, limit: 2).clamped)
        XCTAssertEqual(ExportConcurrency.estimatedMegapixels(width: 6032, height: 4032, fileBytes: 0), 24.32,
                       accuracy: 0.01)
        XCTAssertEqual(ExportConcurrency.estimatedMegapixels(width: nil, height: nil, fileBytes: 27_000_000), 27,
                       accuracy: 0.01, "about a byte per pixel when the size isn't known")
    }

    /// The model steps are gated only for edits that use a model.
    func testOnlyModelEditsTakeTurns() {
        var p = EditParameters()
        XCTAssertFalse(ExportModelGate.needsModels(p))
        p.exposureEV = 1
        XCTAssertFalse(ExportModelGate.needsModels(p))
        p.aiDenoise = 0.5
        XCTAssertTrue(ExportModelGate.needsModels(p))
    }

    // MARK: Files

    /// Three photos exported with 1 worker and with 3: the same files,
    /// byte for byte, under the same names.
    func testSeveralAtOnceWriteTheSameFilesAsOneAtATime() async throws {
        let raw = try TestAssets.d750URL()
        let gpu = try GPUContext()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var exposure = EditParameters()
        exposure.exposureEV = 0.7
        exposure.contrast = 20
        let edits: [String?] = [nil, try EditStack(parameters: exposure).encodeJSON(), nil]
        var outputs: [Int: [String: Data]] = [:]
        for workers in [1, 3] {
            let folder = base.appendingPathComponent("w\(workers)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var next = 0
            var names: [String] = []
            await ExportPipeline.run(
                workers: workers,
                next: { () async -> ExportPipeline.Step<ExportWorker.Request, Result<URL, Error>>? in
                    guard next < edits.count else { return nil }
                    defer { next += 1 }
                    let destination = folder.appendingPathComponent(String(format: "photo-%03d.jpg", next + 1))
                    var request = ExportWorker.Request(
                        sourceURL: raw, destinationURL: destination, editStackJSON: edits[next], userRotation: 0,
                        settings: ExportSettings(format: .jpeg, quality: 0.9), colorSpace: .sRGB,
                        maxLongEdge: next == 2 ? 1600 : nil, keywords: ["k\(next)"], rating: next)
                    request.replacesExisting = false
                    return .run(request)
                },
                work: { request in
                    do {
                        _ = try await ExportWorker.export(request, gpu: gpu)
                        return .success(request.destinationURL)
                    } catch {
                        return .failure(error)
                    }
                },
                commit: { result in
                    switch result {
                    case .success(let url): names.append(url.lastPathComponent)
                    case .failure(let error): XCTFail("\(error)")
                    }
                })
            XCTAssertEqual(names, ["photo-001.jpg", "photo-002.jpg", "photo-003.jpg"])
            var files: [String: Data] = [:]
            for name in names { files[name] = try Data(contentsOf: folder.appendingPathComponent(name)) }
            outputs[workers] = files
        }
        let serial = try XCTUnwrap(outputs[1]), parallel = try XCTUnwrap(outputs[3])
        XCTAssertEqual(serial.keys.sorted(), parallel.keys.sorted())
        for (name, data) in serial {
            XCTAssertEqual(parallel[name], data, "\(name) differs between 1 and 3 at once")
        }
        // And they are real, different pictures.
        XCTAssertNotEqual(serial["photo-001.jpg"], serial["photo-002.jpg"])
    }
}
