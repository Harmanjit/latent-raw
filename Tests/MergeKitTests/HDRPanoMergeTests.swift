import Foundation
import Metal
import PixelEngine
import RawCore
import XCTest
import simd
@testable import MergeKit

/// The HDR panorama engine end to end (Phase 9, **experimental**):
/// synthetic bracketed sweeps of a known scene in, one panorama DNG out.
///
/// What these check that the grouping tests can't: that each position's
/// *merged* HDR is what gets stitched (not one of its frames), that the
/// result is the scene, that the recipe names every photo the user chose,
/// and that nothing is left behind.
final class HDRPanoMergeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try Fixtures.temporaryFolder()
        _ = PanoramaFrameStore.removeScratchOfThisProcess()
    }

    override class func tearDown() {
        HDRPanoTestSupport.removeCachedPhotos()
        PanoMergeTestSupport.removeCachedPhotos()
        super.tearDown()
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try super.tearDownWithError()
    }

    /// The real engines, with plenty of disk and a scratch folder this test
    /// can look inside.
    private func merger(availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil }) throws
    -> HDRPanoramaMerger {
        let gpu = try HDRTestSupport.gpu()
        return HDRPanoramaMerger(hdr: HDRMerger(gpu: gpu, memoryPolicy: MemoryPolicy(physicalMemory: 16 << 30)),
                                 panorama: PanoramaMerger(gpu: gpu), scratchRoot: folder,
                                 availableCapacity: availableCapacity)
    }

    // MARK: - End to end

    func testThreeBracketsStitchIntoOneHDRPanoramaOfTheScene() async throws {
        let urls = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let merger = try merger()
        let options = HDRPanoramaOptions()
        let started = Date()
        let analysis = try await merger.analyse(urls, options: options)
        let analysisSeconds = Date().timeIntervalSince(started)

        // Grouped into three positions of three exposures, in capture order.
        XCTAssertEqual(analysis.photos.count, 9)
        XCTAssertEqual(analysis.grouping.positions.map(\.frames), [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        XCTAssertEqual(analysis.grouping.evidence, .exposurePatternAndTiming)
        XCTAssertEqual(analysis.grouping.summaryText, "3 exposures at each of 3 positions")
        // The layout is solved on one photo per position, so the dialog can
        // show the sweep without merging anything.
        XCTAssertEqual(analysis.panorama.frames.count, 3)
        XCTAssertFalse(analysis.panorama.frames.contains(where: \.leftOut))
        let yaws = analysis.panorama.frames.compactMap { $0.yawPitchRoll?.x }
        for k in 1..<yaws.count {
            XCTAssertEqual(yaws[k] - yaws[k - 1], 0.4 * 180 / .pi, accuracy: 1.5, "step \(k)")
        }
        XCTAssertGreaterThan(analysis.estimatedScratchBytes, 0, "three positions are merged to temporary DNGs")

        let destination = folder.appendingPathComponent("sweep-HDRPano.dng")
        let sources = HDRPanoTestSupport.sources(analysis.photos.map(\.url))
        let sidecar = RecipeBox()
        let stages = StageBox()
        // Peak GPU memory, sampled every time the engine reports: one HDR
        // merge at a time, then the stitch, so it should stay bounded.
        let device = try HDRTestSupport.gpu().device
        let peak = PeakMemory(device: device)
        let mergeStarted = Date()
        let result = try await merger.merge(analysis, options: options, sources: sources, to: destination,
                                            prepareSidecar: { sidecar.store($0) },
                                            progress: { stages.store($0); peak.sample() })
        let mergeSeconds = Date().timeIntervalSince(mergeStarted)

        // The file, as the catalog and the editor read it.
        XCTAssertEqual(result.url, destination)
        let merged = try PanoMergeTestSupport.read(destination)
        XCTAssertEqual(merged.info.kind, MergeRecipe.Kind.hdrPanorama.rawValue)
        XCTAssertTrue(merged.info.lensApplied, "the stitch is lens-corrected already")
        XCTAssertEqual(merged.orientation, 0, "the stitch is upright, so the file must not be turned")
        XCTAssertNil(merged.info.lens)

        // The recipe: an HDR panorama of every photo the user chose, not of
        // the intermediates.
        let recipe = try XCTUnwrap(sidecar.recipe)
        XCTAssertEqual(recipe.kind, .hdrPanorama)
        XCTAssertEqual(recipe.sources.map(\.path), urls.map(\.lastPathComponent))
        XCTAssertEqual(recipe.sources.count, 9)
        XCTAssertEqual(recipe.reference, 0, "named after the first photo of the first position stitched")
        XCTAssertEqual(recipe.options["hdrPanorama"], .bool(true))
        XCTAssertEqual(recipe.options["experimental"], .bool(true))
        XCTAssertEqual(recipe.options["positions"], .number(3))
        XCTAssertEqual(recipe.options["grouping"], .string("exposurePatternAndTiming"))
        XCTAssertEqual(recipe.options["autoAlign"], .bool(true))
        XCTAssertEqual(recipe.options["deghost"], .string(DeghostAmount.none.rawValue))
        XCTAssertEqual(recipe.options["projection"], .string("cylindrical"))
        XCTAssertEqual(recipe.options["stitched"], .number(3))
        guard case .array(let brackets)? = recipe.options["brackets"], brackets.count == 3,
              case .object(let first) = brackets[0] else { return XCTFail("the recipe has no brackets") }
        XCTAssertEqual(first["frames"], .array([.number(0), .number(1), .number(2)]))
        XCTAssertEqual(first["merged"], .bool(true))

        // Both stages reported, in order, over the whole bar.
        XCTAssertTrue(stages.stages.contains { $0.contains("Merging bracket 1 of 3") })
        XCTAssertTrue(stages.stages.contains { $0.contains("Merging bracket 3 of 3") })
        XCTAssertTrue(stages.stages.contains("Laying out the panorama"))
        XCTAssertTrue(stages.stages.contains { $0.hasPrefix("Stitching") || $0.hasPrefix("Saving") })
        // The stitch reports from its own threads, so the tiles' fractions
        // can arrive a little out of order; what must hold is that both
        // stages report inside their own share of the bar.
        XCTAssertTrue(stages.fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        let layingOut = try XCTUnwrap(stages.stages.firstIndex(of: "Laying out the panorama"))
        XCTAssertTrue(stages.fractions[..<layingOut].allSatisfy { $0 <= HDRPanoramaMerger.hdrShare + 1e-9 },
                      "the HDR merges take the first part of the bar")
        XCTAssertTrue(stages.fractions[layingOut...].allSatisfy { $0 >= HDRPanoramaMerger.hdrShare - 1e-9 },
                      "the stitch takes the rest")

        // The pixels are the scene, to one exposure over the whole width.
        // The layout of one photo per position is the layout of their HDRs
        // (same size, lens and capture time), so the analysis's canvas is
        // the one the result was stitched on.
        let stitched = analysis.panorama
        let crop = HDRPanoMergeTests.cropRect(stitched, merged: merged)
        let comparison = HDRPanoTestSupport.compare(merged, with: stitched, over: crop)
        print("hdrpano-merge | \(comparison.samples) samples: scale \(String(format: "%.3f", comparison.scale)), "
              + "spread p90 \(String(format: "%.1f%%", comparison.spread * 100)), "
              + "left/right step \(String(format: "%.1f%%", comparison.sideStep * 100)) | "
              + "analyse \(String(format: "%.2f s", analysisSeconds)), "
              + "merge \(String(format: "%.2f s", mergeSeconds)), "
              + "peak GPU \(String(format: "%.0f MB", Double(peak.bytes) / 1e6))")
        XCTAssertGreaterThan(comparison.samples, 3_000)
        XCTAssertGreaterThan(comparison.scale, 0)
        XCTAssertLessThan(comparison.spread, 0.25, "the panorama should hold the scene, to one exposure")
        XCTAssertLessThan(comparison.sideStep, 0.10, "one coherent image: no step between the ends")

        // Nothing left behind: the intermediates and the blend's scratch.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("Latent-HDRPano-") }
        XCTAssertEqual(left, [], "the intermediate HDRs must be removed")
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0, "the stitch left scratch files behind")
    }

    /// The merged HDR of a position, not one of its frames, is what gets
    /// stitched: the result holds detail the brightest frame clipped away
    /// and detail the darkest frame lost in black.
    func testTheStitchUsesEachPositionsMergedHDR() async throws {
        let urls = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: HDRPanoramaOptions())
        let destination = folder.appendingPathComponent("range-HDRPano.dng")
        _ = try await merger.merge(analysis, options: HDRPanoramaOptions(),
                                   sources: HDRPanoTestSupport.sources(analysis.photos.map(\.url)),
                                   to: destination, prepareSidecar: { _ in }, progress: { _ in })
        let merged = try PanoMergeTestSupport.read(destination)

        // A single frame at the brightest exposure (4) clips everything
        // above (white − black) / (4 × counts per unit) = 0.27 of the
        // scene's radiance, which is 0.25 in the merge's units. The
        // stitched HDRs must hold the scene well past that.
        var values: [Double] = []
        for y in stride(from: 8, to: merged.height - 8, by: 5) {
            for x in stride(from: 8, to: merged.width - 8, by: 5) where !merged.isUncovered(x, y) {
                let pixel = merged.pixel(x, y)
                values.append(max(pixel.x, max(pixel.y, pixel.z)))
            }
        }
        values.sort()
        let clipOfBrightestFrame = Double(SyntheticBracket.white - SyntheticBracket.black.r)
            / (4 * SyntheticBracket.countsPerUnit) * SyntheticBracket.normalisedPerUnit
        let low = values[values.count / 100], high = values[values.count * 99 / 100]
        print("hdrpano-range | p1 \(String(format: "%.3f", low)), p99 \(String(format: "%.3f", high)), "
              + "a single bright frame clips at \(String(format: "%.3f", clipOfBrightestFrame))")
        XCTAssertGreaterThan(low, 0)
        XCTAssertGreaterThan(high, 1.5 * clipOfBrightestFrame,
                             "the stitch must hold highlights the brightest frame clipped away")
    }

    // MARK: - The awkward selections, merged

    /// A stray photo with no bracket goes into the panorama as it is, and
    /// the dialog is told so. (The same photos as the sweep, with the last
    /// bracket's middle exposure alone: no new files to paint.)
    func testAStrayPhotoIsStitchedAsItIs() async throws {
        let all = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let urls = Array(all[0...5]) + [all[7]]
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: HDRPanoramaOptions())
        XCTAssertEqual(analysis.grouping.positions.map(\.frames), [[0, 1, 2], [3, 4, 5], [6]])
        XCTAssertEqual(analysis.grouping.evidence, .timeGaps)
        XCTAssertFalse(analysis.grouping.positions[2].needsMerging)
        XCTAssertTrue(analysis.warnings.contains { warning in
            if case .singlePhotoPosition(2, "P02-1.dng") = warning { return true }
            return false
        })
        XCTAssertTrue(analysis.warnings.contains { if case .unevenBrackets = $0 { true } else { false } })

        let destination = folder.appendingPathComponent("stray-HDRPano.dng")
        let sidecar = RecipeBox()
        _ = try await merger.merge(analysis, options: HDRPanoramaOptions(),
                                   sources: HDRPanoTestSupport.sources(analysis.photos.map(\.url)),
                                   to: destination, prepareSidecar: { sidecar.store($0) }, progress: { _ in })
        let recipe = try XCTUnwrap(sidecar.recipe)
        XCTAssertEqual(recipe.sources.count, 7, "every photo is recorded, merged or not")
        guard case .array(let brackets)? = recipe.options["brackets"], brackets.count == 3,
              case .object(let stray) = brackets[2] else { return XCTFail("the recipe has no brackets") }
        XCTAssertEqual(stray["merged"], .bool(false))
        XCTAssertEqual(try PanoMergeTestSupport.read(destination).info.kind,
                       MergeRecipe.Kind.hdrPanorama.rawValue)
    }

    /// A photo merged earlier (a linear DNG) can stand in for a position,
    /// as Lightroom allows: it is stitched as it is, beside brackets that
    /// are merged now.
    func testAnAlreadyMergedPhotoCanBeAPosition() async throws {
        // Merge the middle position on its own first, as the user would
        // have, then hand that DNG back with the other two brackets.
        let urls = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let gpu = try HDRTestSupport.gpu()
        let hdr = HDRMerger(gpu: gpu, memoryPolicy: MemoryPolicy(physicalMemory: 16 << 30))
        let middle = Array(urls[3...5])
        let alreadyMerged = folder.appendingPathComponent("middle-HDR.dng")
        let middleAnalysis = try await hdr.analyse(middle, options: HDRMergeOptions())
        _ = try await hdr.merge(middleAnalysis, options: HDRMergeOptions(),
                                sources: HDRPanoTestSupport.sources(middle), to: alreadyMerged,
                                prepareSidecar: { _ in }, progress: { _ in })

        let selection = Array(urls[0...2]) + [alreadyMerged] + Array(urls[6...8])
        let merger = try merger()
        let analysis = try await merger.analyse(selection, options: HDRPanoramaOptions())
        XCTAssertEqual(analysis.grouping.positions.map(\.frames), [[0, 1, 2], [3], [4, 5, 6]])
        XCTAssertTrue(analysis.grouping.positions[1].alreadyMerged)
        XCTAssertTrue(analysis.warnings.contains { warning in
            if case .alreadyMergedPosition(1, "middle-HDR.dng") = warning { return true }
            return false
        })

        let destination = folder.appendingPathComponent("mixed-HDRPano.dng")
        let sidecar = RecipeBox()
        _ = try await merger.merge(analysis, options: HDRPanoramaOptions(),
                                   sources: HDRPanoTestSupport.sources(analysis.photos.map(\.url)),
                                   to: destination, prepareSidecar: { sidecar.store($0) }, progress: { _ in })
        let merged = try PanoMergeTestSupport.read(destination)
        XCTAssertEqual(merged.info.kind, MergeRecipe.Kind.hdrPanorama.rawValue)
        XCTAssertEqual(try XCTUnwrap(sidecar.recipe).sources.count, 7)
    }

    // MARK: - Refusals and tidying up

    func testAPlainSweepIsRefusedWithItsOwnMessage() async throws {
        // The same sweep's middle exposures only: four single shots.
        let all = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let urls = [all[1], all[4], all[7]]
        do {
            _ = try await merger().analyse(urls, options: HDRPanoramaOptions())
            XCTFail("a sweep of single shots isn’t an HDR panorama")
        } catch let error as HDRPanoramaError {
            XCTAssertEqual(error, .sameExposure)
        }
    }

    func testAFullDiskIsRefusedBeforeAnythingIsMerged() async throws {
        let urls = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let merger = try merger(availableCapacity: { _ in 1_000_000 })
        let analysis = try await merger.analyse(urls, options: HDRPanoramaOptions())
        do {
            _ = try await merger.merge(analysis, options: HDRPanoramaOptions(),
                                       sources: HDRPanoTestSupport.sources(analysis.photos.map(\.url)),
                                       to: folder.appendingPathComponent("full-HDRPano.dng"),
                                       prepareSidecar: { _ in }, progress: { _ in })
            XCTFail("a full disk must refuse the merge")
        } catch let error as HDRPanoramaError {
            guard case .notEnoughDiskSpace(let needed, let available) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertGreaterThan(needed, available)
            XCTAssertTrue(error.errorDescription?.contains("merged brackets") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            folder.appendingPathComponent("full-HDRPano.dng").path))
    }

    func testCancellingLeavesNoDNGAndNoIntermediates() async throws {
        let urls = try HDRPanoTestSupport.cached("sweep3x3", HDRPanoTestSupport.sweep(positions: 3))
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: HDRPanoramaOptions())
        let destination = folder.appendingPathComponent("cancelled-HDRPano.dng")
        let task = TaskHolder()
        let sources = HDRPanoTestSupport.sources(analysis.photos.map(\.url))
        let running = Task {
            try await merger.merge(analysis, options: HDRPanoramaOptions(), sources: sources, to: destination,
                                   prepareSidecar: { _ in },
                                   progress: { progress in
                                       // Once the second bracket starts, stop.
                                       if progress.stage.contains("bracket 2") { task.cancel() }
                                   })
        }
        task.hold(running)
        do {
            _ = try await running.value
            XCTFail("the merge should have been cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("Latent-HDRPano-") }
        XCTAssertEqual(left, [], "a cancelled merge must take its intermediates with it")
    }

    // MARK: - Helpers

    /// The rectangle of the output every pixel of which came from a photo.
    private static func cropRect(_ analysis: PanoramaMergeAnalysis,
                                 merged: PanoMergeTestSupport.Merged) -> CGRect {
        let scale = analysis.outputSize.scale
        let crop = analysis.layout.autoCropRect
        return CGRect(x: (crop.minX * scale).rounded(.up), y: (crop.minY * scale).rounded(.up),
                      width: (crop.width * scale).rounded(.down), height: (crop.height * scale).rounded(.down))
            .intersection(CGRect(x: 0, y: 0, width: merged.width, height: merged.height))
    }

    /// The recipe a merge hands to the sidecar, from the engine's thread.
    final class RecipeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MergeRecipe?
        var recipe: MergeRecipe? { lock.withLock { stored } }
        func store(_ recipe: MergeRecipe) { lock.withLock { stored = recipe } }
    }

    /// Every stage a merge reported, in order.
    final class StageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private var seenFractions: [Double] = []
        var stages: [String] { lock.withLock { seen } }
        var fractions: [Double] { lock.withLock { seenFractions } }
        func store(_ progress: HDRPanoramaProgress) {
            lock.withLock {
                seen.append(progress.stage)
                seenFractions.append(progress.fraction)
            }
        }
    }

    /// The largest the GPU's allocation was seen to be, sampled from the
    /// engine's progress reports.
    final class PeakMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0
        private let device: any MTLDevice

        init(device: any MTLDevice) { self.device = device }
        var bytes: Int { lock.withLock { seen } }
        func sample() {
            let now = device.currentAllocatedSize
            lock.withLock { seen = max(seen, now) }
        }
    }

    /// A task a progress callback can cancel, set after the task is made.
    final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<MergeDNGWriteResult, Error>?
        private var wanted = false

        func hold(_ task: Task<MergeDNGWriteResult, Error>) {
            lock.withLock {
                self.task = task
                if wanted { task.cancel() }
            }
        }

        func cancel() {
            lock.withLock {
                wanted = true
                task?.cancel()
            }
        }
    }
}
