import XCTest
import ImageIO
@testable import Catalog
import PixelEngine
import MLKit
@testable import latent_app

/// Export › Photos at once (ExportQueue+Concurrency.swift): the queue run
/// several photos at a time writes the same files, under the same numbered
/// names, in the same order, as one at a time; the saved choice is clamped
/// to what the batch's photos allow and kept apart from the presets.
@MainActor
final class ExportPhotosAtOnceTests: XCTestCase {
    nonisolated(unsafe) var folder: BracketFolder?
    nonisolated(unsafe) var gpuContext: GPUContext?

    override func setUp() async throws {
        gpuContext = try await GPUContext.shared()
    }

    override func tearDown() async throws {
        await MainActor.run { folder?.remove() }
    }

    private func export(_ photos: BracketFolder, workers: Int, preset: ExportPreset,
                        into name: String) async throws -> (queue: ExportQueue, out: URL) {
        let out = photos.base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let queue = ExportQueue(outputJobs: OutputJobs())
        // Six photos: the three of the folder, twice over, in a batch.
        queue.start(records: photos.records + photos.records, library: photos.library, preset: preset,
                    destination: out, gpu: gpuContext!, photosAtOnce: workers)
        XCTAssertTrue(queue.isRunning)
        await waitUntil("the export", seconds: 60) { !queue.isRunning }
        return (queue, out)
    }

    private func contents(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            files[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }

    func testSeveralAtOnceWriteTheSameNumberedFilesAsOneAtATime() async throws {
        let photos = try await BracketFolder.make()
        folder = photos
        var preset = ExportPreset()
        preset.format = .jpeg
        preset.template = "{seq}-{name}"
        preset.revealWhenDone = false
        preset.addToCatalog = false
        let serial = try await export(photos, workers: 1, preset: preset, into: "one")
        let parallel = try await export(photos, workers: 3, preset: preset, into: "three")
        XCTAssertTrue(serial.queue.failures.isEmpty, serial.queue.failures.map(\.reason).joined(separator: "; "))
        XCTAssertTrue(parallel.queue.failures.isEmpty, parallel.queue.failures.map(\.reason).joined(separator: "; "))
        XCTAssertEqual(serial.queue.done, 6)
        XCTAssertEqual(parallel.queue.done, 6)
        let one = try contents(serial.out), three = try contents(parallel.out)
        XCTAssertEqual(one.keys.sorted(), ["001-DSC_0106.jpg", "002-DSC_0107.jpg", "003-DSC_0108.jpg",
                                           "004-DSC_0106.jpg", "005-DSC_0107.jpg", "006-DSC_0108.jpg"])
        XCTAssertEqual(three.keys.sorted(), one.keys.sorted(), "the same names and numbering")
        for (name, data) in one {
            XCTAssertEqual(three[name], data, "\(name): the same bytes, pixels and metadata")
        }
        XCTAssertTrue(parallel.queue.summary.hasPrefix("6 of 6 exported"), parallel.queue.summary)
        XCTAssertEqual(parallel.queue.currentName, "")
        XCTAssertEqual(parallel.queue.photosAtOnce, 1, "back to idle")
    }

    /// With several at once, the names already taken are skipped in order
    /// and counted once each, as one at a time.
    func testSkipsAndProgressCountOncePerPhoto() async throws {
        let photos = try await BracketFolder.make()
        folder = photos
        var preset = ExportPreset()
        preset.template = "{name}"
        preset.collision = .skip
        preset.revealWhenDone = false
        let out = photos.base.appendingPathComponent("skip", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("taken".utf8).write(to: out.appendingPathComponent("DSC_0107.jpg"))
        let queue = ExportQueue(outputJobs: OutputJobs())
        queue.start(records: photos.records, library: photos.library, preset: preset, destination: out,
                    gpu: gpuContext!, photosAtOnce: 3)
        await waitUntil("the export", seconds: 60) { !queue.isRunning }
        XCTAssertEqual(queue.done, 3)
        XCTAssertTrue(queue.summary.contains("2 of 3 exported"), queue.summary)
        XCTAssertTrue(queue.summary.contains("1 skipped"), queue.summary)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("DSC_0107.jpg")), Data("taken".utf8))
    }

    /// Cancel with several at once stops starting photos, and every photo
    /// started is finished and counted.
    func testCancelStopsAllWorkers() async throws {
        let photos = try await BracketFolder.make()
        folder = photos
        var preset = ExportPreset()
        preset.revealWhenDone = false
        let out = photos.base.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let queue = ExportQueue(outputJobs: OutputJobs())
        let records = Array(repeating: photos.records, count: 10).flatMap { $0 }
        queue.start(records: records, library: photos.library, preset: preset, destination: out,
                    gpu: gpuContext!, photosAtOnce: 2)
        queue.cancel()
        await queue.stopAfterCurrentFile()
        XCTAssertFalse(queue.isRunning)
        XCTAssertTrue(queue.summary.contains("(cancelled)"), queue.summary)
        XCTAssertLessThan(queue.done, records.count)
        let written = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertTrue(written.allSatisfy { $0.hasSuffix(".jpg") }, "no half-written file: \(written)")
        XCTAssertEqual(written.count, queue.done - queue.failures.count)
    }

    /// Each page of a PDF drawn into a bitmap, 8 times its point size.
    private func pages(_ url: URL) throws -> [[UInt8]] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        return try (1...document.numberOfPages).map { number in
            let page = try XCTUnwrap(document.page(at: number))
            let box = page.getBoxRect(.mediaBox)
            let w = Int(box.width * 8), h = Int(box.height * 8)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.scaleBy(x: 8, y: 8)
                context.drawPDFPage(page)
            }
            return pixels
        }
    }

    /// A combined PDF made several photos at a time has the same pages, in
    /// the same order, as one made one at a time.
    func testCombinedPDFKeepsItsPageOrder() async throws {
        let photos = try await BracketFolder.make()
        folder = photos
        var preset = ExportPreset()
        preset.fileKind = .pdf
        preset.formats.pdf.combine = true
        preset.formats.pdf.combinedFileName = "Proofs"
        preset.revealWhenDone = false
        let serial = try await export(photos, workers: 1, preset: preset, into: "pdf1")
        let parallel = try await export(photos, workers: 3, preset: preset, into: "pdf3")
        XCTAssertTrue(parallel.queue.failures.isEmpty, parallel.queue.failures.map(\.reason).joined(separator: "; "))
        XCTAssertEqual(parallel.queue.done, 6)
        let one = try pages(serial.out.appendingPathComponent("Proofs.pdf"))
        let three = try pages(parallel.out.appendingPathComponent("Proofs.pdf"))
        XCTAssertEqual(one.count, 6)
        XCTAssertEqual(three.count, 6)
        for index in one.indices { XCTAssertEqual(one[index], three[index], "page \(index + 1)") }
        XCTAssertNotEqual(one[0], one[1], "the bracket's photos differ, so the order shows")
    }

    // MARK: The choice

    func testChoiceIsKeptApartFromPresetsAndClampedPerBatch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "latent-photos-at-once-\(UUID().uuidString)"))
        XCTAssertEqual(ExportPhotosAtOnce.load(defaults: defaults), ExportConcurrency.automaticChoice)
        ExportPhotosAtOnce.save(4, defaults: defaults)
        XCTAssertEqual(ExportPhotosAtOnce.load(defaults: defaults), 4)
        ExportPhotosAtOnce.save(-3, defaults: defaults)
        XCTAssertEqual(ExportPhotosAtOnce.load(defaults: defaults), ExportConcurrency.automaticChoice)

        // A preset saved before the control existed loads as it was.
        let old = try JSONDecoder().decode(ExportPreset.self, from: Data(#"{"format":"jpeg","quality":0.8}"#.utf8))
        XCTAssertEqual(old.quality, 0.8)

        let mac16 = ExportConcurrency.Machine(physicalMemory: 16 << 30, gpuWorkingSet: 11_453_251_584,
                                              activeCores: 10)
        var d750 = ImageRecord(id: 1, relPath: "a.NEF", preservedName: nil, size: 27_000_000, mtime: 0,
                               xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil,
                               iso: nil, shutter: nil, aperture: nil, focal: nil, width: 6032, height: 4032,
                               orientation: nil, rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
        var big = d750
        big.width = 9504; big.height = 6336
        let preset = ExportPreset()
        let small = ExportQueue.concurrency(records: [d750], preset: preset, choice: 0, machine: mac16)
        XCTAssertEqual(small.workers, ExportConcurrency.measuredBest)
        XCTAssertEqual(small.note, "")
        let many = ExportQueue.concurrency(records: [d750, big], preset: preset, choice: 6, machine: mac16)
        XCTAssertLessThan(many.limit, small.limit + 1)
        XCTAssertLessThan(many.limit, 6, "a 60 MP photo in the batch lowers the limit")
        XCTAssertTrue(many.clamped)
        XCTAssertEqual(many.workers, many.limit)
        XCTAssertTrue(many.note.contains("6 is more than this Mac can take"), many.note)

        // A 2048 px export needs less per photo than full size.
        var web = ExportPreset()
        web.resize = true
        web.maxLongEdge = 2048
        XCTAssertLessThan(ExportPhotosAtOnce.outputMegapixels(preset: web, source: 24.3), 3)
        XCTAssertEqual(ExportPhotosAtOnce.outputMegapixels(preset: preset, source: 24.3), 24.3, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(ExportPhotosAtOnce.limit(records: [d750], preset: web, machine: mac16),
                                    ExportPhotosAtOnce.limit(records: [d750], preset: preset, machine: mac16))
        XCTAssertTrue(ExportPhotosAtOnce.help(limit: 3).hasPrefix("Your Mac can export up to 3 photos at a time"))
    }
}
