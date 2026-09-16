import Foundation
import PixelEngine
import RawCore
import XCTest
import simd
@testable import MergeKit

/// The panorama engine end to end (Phase 8c): synthetic photos of a known
/// scene in, a panorama DNG out, and every rule around it — the
/// downsampling path, cancellation, the sidecar's order, disk space, and
/// photos that can't be joined.
final class PanoMergeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try Fixtures.temporaryFolder()
        // No panorama scratch of this process may survive a test.
        _ = PanoramaFrameStore.removeScratchOfThisProcess()
    }

    override class func tearDown() {
        PanoMergeTestSupport.removeCachedPhotos()
        super.tearDown()
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try super.tearDownWithError()
    }

    private func merger(sizeLimits: PanoramaMerger.SizeLimits? = nil,
                        availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil }) throws -> PanoramaMerger {
        PanoramaMerger(gpu: try HDRTestSupport.gpu(), sizeLimits: sizeLimits, availableCapacity: availableCapacity)
    }

    // MARK: - End to end

    func testSyntheticPanoramaMergesToALinearPanoramaOfTheScene() async throws {
        let urls = try PanoMergeTestSupport.cached("row5", PanoMergeTestSupport.row(count: 5))
        let merger = try merger()
        let options = PanoramaMergeOptions()
        let (analysis, analysisReport) = try await merger.analyseWithReport(urls, options: options)

        // Every photo placed, in capture order, turning right in 0.4 rad steps.
        XCTAssertEqual(analysis.frames.count, 5)
        XCTAssertEqual(analysis.frames.map(\.url.lastPathComponent), urls.map(\.lastPathComponent))
        XCTAssertEqual(analysis.layout.cameras.map(\.frameIndex), Array(0..<5))
        XCTAssertFalse(analysis.frames.contains(where: \.leftOut))
        let yaws = analysis.frames.compactMap { $0.yawPitchRoll?.x }
        for k in 1..<yaws.count {
            XCTAssertEqual(yaws[k] - yaws[k - 1], 0.4 * 180 / .pi, accuracy: 1.0, "step \(k)")
        }
        // Same exposure everywhere, so no photo needs a gain.
        for frame in analysis.frames { XCTAssertEqual(frame.gainStops, 0, accuracy: 0.05) }
        XCTAssertEqual(analysis.widthDegrees, (4 * 0.4 + 2 * atan(450.0 / 700)) * 180 / .pi, accuracy: 3)
        XCTAssertEqual(analysis.layout.canvas.projection, .cylindrical)
        XCTAssertFalse(analysis.outputSize.needsDownsampling, "a small panorama fits")
        XCTAssertEqual(analysis.outputSize.decodeSpan, 1)
        XCTAssertGreaterThan(analysisReport.totalSeconds, 0)

        // The preview is the real blend, cropped as the dialog shows it.
        let preview = try await merger.preview(analysis, options: options, longEdge: 400)
        XCTAssertEqual(max(preview.width, preview.height), 400, accuracy: 1)
        let crop = analysis.layout.autoCropRect
        XCTAssertEqual(Double(preview.width) / Double(preview.height), crop.width / crop.height, accuracy: 0.05)

        let destination = folder.appendingPathComponent("panorama.dng")
        var sidecarRecipe: MergeRecipe?
        let sidecar = RecipeBox()
        let (result, report) = try await merger.mergeWithReport(
            analysis, options: options, sources: PanoMergeTestSupport.sources(analysis), to: destination,
            prepareSidecar: { sidecar.store($0) }, progress: { _ in })
        sidecarRecipe = sidecar.recipe

        // The file, as the catalog and the editor will read it.
        XCTAssertEqual(result.url, destination)
        let merged = try PanoMergeTestSupport.read(destination)
        XCTAssertEqual([merged.width, merged.height], [analysis.outputSize.width, analysis.outputSize.height])
        XCTAssertEqual(merged.info.kind, MergeRecipe.Kind.panorama.rawValue)
        XCTAssertTrue(merged.info.lensApplied, "the panorama is lens-corrected already")
        XCTAssertEqual(merged.orientation, 0, "the stitch is upright, so the file must not be turned")
        XCTAssertEqual(merged.info.baselineShift, result.normalisation.shift)
        XCTAssertEqual(Double(merged.baselineExposure), Double(result.normalisation.shift), accuracy: 1e-4)
        XCTAssertEqual(merged.info.clipLevel, result.recipe.clipLevel, accuracy: 1e-6)
        XCTAssertEqual(Double(merged.info.clipLevel) * pow(2, Double(merged.info.baselineShift)),
                       Double(report.clipLevel), accuracy: 1e-3)
        XCTAssertNil(merged.info.lens, "a lens-corrected panorama names no lens")

        // The recipe: what was merged and how.
        let recipe = try XCTUnwrap(sidecarRecipe)
        XCTAssertEqual(recipe.kind, .panorama)
        XCTAssertTrue(recipe.lensApplied)
        XCTAssertEqual(recipe.sources.count, 5)
        XCTAssertEqual(recipe.reference, 0)
        XCTAssertEqual(recipe.clipLevel, result.recipe.clipLevel, accuracy: 1e-6)
        XCTAssertEqual(recipe.options["projection"], .string("cylindrical"))
        XCTAssertEqual(recipe.options["autoCrop"], .bool(true))
        XCTAssertEqual(recipe.options["decodeSpan"], .number(1))
        XCTAssertEqual(recipe.options["canvasWidth"], .number(Double(analysis.layout.canvas.width)))
        XCTAssertEqual(recipe.options["canvasHeight"], .number(Double(analysis.layout.canvas.height)))
        XCTAssertEqual(recipe.options["outputWidth"], .number(Double(analysis.outputSize.width)))
        XCTAssertNil(recipe.options["leftOut"])
        // The crop travels in the output's own pixels and normalised.
        guard case .object(let cropPixels)? = recipe.options["cropPixels"],
              case .number(let cropX)? = cropPixels["x"], case .number(let cropY)? = cropPixels["y"],
              case .number(let cropWidth)? = cropPixels["width"],
              case .number(let cropHeight)? = cropPixels["height"] else {
            return XCTFail("the recipe has no crop rectangle")
        }
        guard case .object(let normalised)? = recipe.options["cropNormalised"],
              case .number(let normalisedWidth)? = normalised["width"] else {
            return XCTFail("the recipe has no normalised crop rectangle")
        }
        XCTAssertEqual(normalisedWidth, cropWidth / Double(merged.width), accuracy: 1e-5)
        XCTAssertGreaterThan(cropWidth * cropHeight, 0.4 * Double(merged.width * merged.height))

        // Inside the crop every pixel came from a photo.
        var uncovered = 0
        for y in stride(from: Int(cropY), to: Int(cropY + cropHeight), by: 4) {
            for x in stride(from: Int(cropX), to: Int(cropX + cropWidth), by: 4)
            where merged.isUncovered(x, y) { uncovered += 1 }
        }
        XCTAssertEqual(uncovered, 0, "the Auto Crop rectangle must hold only real pixels")

        // The pixels are the scene: sampled over the crop, in merge units.
        var errors: [Double] = []
        var mergedMean = 0.0, trueMean = 0.0, samples = 0
        for y in stride(from: Int(cropY) + 8, to: Int(cropY + cropHeight) - 8, by: 7) {
            for x in stride(from: Int(cropX) + 8, to: Int(cropX + cropWidth) - 8, by: 7) {
                let canvasPixel = (SIMD2(Double(x), Double(y)) + 0.5) / analysis.outputSize.scale
                guard let truth = PanoMergeTestSupport.truth(canvasPixel: canvasPixel,
                                                             canvas: analysis.layout.canvas) else { continue }
                let pixel = merged.pixel(x, y)
                for c in 0..<3 {
                    errors.append(abs(pixel[c] - truth[c]) / truth[c])
                    mergedMean += pixel[c]
                    trueMean += truth[c]
                }
                samples += 1
            }
        }
        XCTAssertGreaterThan(samples, 5_000)
        errors.sort()
        let median = errors[errors.count / 2], p90 = errors[errors.count * 9 / 10]
        print("pano-merge | \(samples) samples: median error \(String(format: "%.2f%%", median * 100)), "
              + "p90 \(String(format: "%.2f%%", p90 * 100)), "
              + "mean \(String(format: "%.4f", mergedMean / Double(3 * samples))) against "
              + "\(String(format: "%.4f", trueMean / Double(3 * samples)))")
        XCTAssertLessThan(median, 0.06, "the panorama should hold the scene's own radiance")
        XCTAssertLessThan(p90, 0.20)
        XCTAssertEqual(mergedMean / trueMean, 1, accuracy: 0.03, "no overall exposure shift")

        // The brightest value the writer was given really did bound the file.
        XCTAssertGreaterThanOrEqual(report.maximumBound, report.maximumSeen)
        XCTAssertGreaterThan(report.maximumSeen, 0)
        XCTAssertLessThanOrEqual(report.maximumBound, 4 * report.maximumSeen, "the bound is not wildly loose")
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0, "the merge left scratch files behind")
    }

    // MARK: - Size

    func testATinyEditingBudgetShrinksThePanoramaAndSaysSo() async throws {
        let urls = try PanoMergeTestSupport.cached("row4", PanoMergeTestSupport.row(count: 4))
        // 0.12 MP of editing budget: about a quarter of the canvas's side.
        let merger = try merger(sizeLimits: .init(maxTextureSide: 16_384, editPixelBudget: 120_000))
        let (analysis, _) = try await merger.analyseWithReport(urls)
        let size = analysis.outputSize
        XCTAssertTrue(size.needsDownsampling)
        XCTAssertEqual(size.limit, .memory)
        XCTAssertEqual(size.scale, (120_000 / (Double(size.fullWidth) * Double(size.fullHeight))).squareRoot(),
                       accuracy: 1e-9)
        XCTAssertEqual(size.width, Int(Double(size.fullWidth) * size.scale))
        XCTAssertEqual(size.height, Int(Double(size.fullHeight) * size.scale))
        XCTAssertEqual(size.decodeSpan, Int(1 / size.scale), "frames are decoded no smaller than the output")
        XCTAssertGreaterThanOrEqual(size.decodeSpan, 2)

        let warning = try XCTUnwrap(analysis.warnings.first { if case .downsampled = $0 { return true } else { return false } })
        guard case .downsampled(let warned) = warning else { return XCTFail("wrong warning") }
        XCTAssertEqual(warned, size)
        let message = warning.message(frames: analysis.frames)
        XCTAssertTrue(message.contains("The most this Mac can edit is"), message)
        XCTAssertTrue(message.contains(PanoramaSizeText.percent(size.scale)), message)
        XCTAssertTrue(message.contains(PanoramaSizeText.size(width: size.width, height: size.height)), message)

        // And the file really is that size, decoded at that span.
        let destination = folder.appendingPathComponent("small.dng")
        let (result, _) = try await merger.mergeWithReport(
            analysis, options: PanoramaMergeOptions(), sources: PanoMergeTestSupport.sources(analysis),
            to: destination, prepareSidecar: { _ in }, progress: { _ in })
        let merged = try PanoMergeTestSupport.read(destination)
        XCTAssertEqual([merged.width, merged.height], [size.width, size.height])
        XCTAssertEqual(result.recipe.options["decodeSpan"], .number(Double(size.decodeSpan)))
        XCTAssertEqual(result.recipe.options["sizeLimit"], .string("memory"))
    }

    func testASmallGPUTextureLimitIsNamedInTheWarning() throws {
        let size = PanoramaOutputSizer.size(fullWidth: 58_210, fullHeight: 5_940, maxTextureSide: 16_384,
                                            editPixelBudget: 1e9)
        XCTAssertEqual(size.limit, .textureSide)
        let message = PanoramaMergeWarning.downsampled(outputSize: size).message()
        XCTAssertEqual(message, "This panorama would be 58,210 × 5,940 px (346 MP). The largest this Mac can edit "
                       + "is 16,384 px on a side, so the photos will be reduced to 28% (16,384 × 1,671 px, 27 MP).")
    }

    func testEveryWarningHasTheDialogsWords() {
        XCTAssertEqual(PanoramaMergeWarning.unevenExposure(stops: 0.42).message(),
                       "The photos still differ in brightness by 0.4 stops after evening them out, "
                       + "so seams may show.")
        XCTAssertEqual(PanoramaMergeWarning.largeParallax(rmsPixels: 7.2).message(),
                       "The camera moved as well as turned (the photos line up only to about 7 px), "
                       + "so things close to the camera may look doubled.")
        XCTAssertEqual(PanoramaMergeWarning.framesLeftOut(indices: [1]).message(),
                       "photo 2 doesn't overlap the others enough to be joined, so it is left out.")
        XCTAssertEqual(PanoramaMergeWarning.framesLeftOut(indices: [0, 2, 3]).message(),
                       "photo 1, photo 3 and photo 4 don't overlap the others enough to be joined, "
                       + "so they are left out.")
        // A panorama that fits says nothing about its size.
        let fits = PanoramaOutputSizer.size(fullWidth: 4_000, fullHeight: 1_000, maxTextureSide: 16_384,
                                            editPixelBudget: 1e9)
        XCTAssertEqual(fits.downsampleMessage, "")
        XCTAssertEqual(fits.sizeMessage, "4,000 × 1,000 px (4.0 MP)")
    }

    // MARK: - Safety

    func testCancellingLeavesNoDNGAndNoScratchFiles() async throws {
        let urls = try PanoMergeTestSupport.cached("row4", PanoMergeTestSupport.row(count: 4))
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: PanoramaMergeOptions())
        let destination = folder.appendingPathComponent("cancelled.dng")
        let gate = PanoMergeTestSupport.Gate(), box = PanoMergeTestSupport.TaskBox()
        let sidecar = RecipeBox()
        let task = Task {
            await gate.wait()
            _ = try await merger.merge(analysis, options: PanoramaMergeOptions(),
                                       sources: PanoMergeTestSupport.sources(analysis), to: destination,
                                       prepareSidecar: { sidecar.store($0) },
                                       progress: { progress in
                                           // Once a photo has been prepared: the next
                                           // check between frames must stop the merge.
                                           if progress.fraction > 0 { box.cancel(at: progress.fraction) }
                                       })
        }
        box.hold(task)
        gate.open()
        do {
            try await task.value
            XCTFail("the merge should have been cancelled")
        } catch is CancellationError {
            // As expected.
        }
        XCTAssertNotNil(box.cancelledAt, "the merge never reported progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a cancelled merge wrote a DNG")
        XCTAssertNil(sidecar.recipe, "a cancelled merge asked for a sidecar")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension != "dng" }, [], "a temporary file was left behind")
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0, "scratch files were left behind")
    }

    func testTheSidecarIsPreparedBeforeTheDNGExistsAndItsFailureWritesNothing() async throws {
        let urls = try PanoMergeTestSupport.cached("row3", PanoMergeTestSupport.row(count: 3))
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: PanoramaMergeOptions())
        let destination = folder.appendingPathComponent("sidecar.dng")

        struct Refused: Error {}
        do {
            _ = try await merger.merge(analysis, options: PanoramaMergeOptions(),
                                       sources: PanoMergeTestSupport.sources(analysis), to: destination,
                                       prepareSidecar: { _ in throw Refused() }, progress: { _ in })
            XCTFail("the merge should have failed with the sidecar")
        } catch is Refused {
            // As expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0)

        // Now let it through: the recipe it is given is the one the file holds.
        let seen = RecipeBox()
        let (result, _) = try await merger.mergeWithReport(
            analysis, options: PanoramaMergeOptions(), sources: PanoMergeTestSupport.sources(analysis),
            to: destination,
            prepareSidecar: { recipe in
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                               "the sidecar must be prepared before the DNG is written")
                seen.store(recipe)
            }, progress: { _ in })
        XCTAssertEqual(seen.recipe, result.recipe, "the sidecar's recipe and the file's must be the same")
    }

    func testAFullDiskRefusesTheMergeBeforeAnyWork() async throws {
        let urls = try PanoMergeTestSupport.cached("row3", PanoMergeTestSupport.row(count: 3))
        let merger = try merger(availableCapacity: { _ in 1_000_000 })
        let analysis = try await merger.analyse(urls, options: PanoramaMergeOptions())
        let destination = folder.appendingPathComponent("full-disk.dng")
        let sidecar = RecipeBox()
        do {
            _ = try await merger.merge(analysis, options: PanoramaMergeOptions(),
                                       sources: PanoMergeTestSupport.sources(analysis), to: destination,
                                       prepareSidecar: { sidecar.store($0) }, progress: { _ in })
            XCTFail("the merge should have been refused")
        } catch PanoramaError.notEnoughDiskSpace(let needed, let available) {
            XCTAssertEqual(available, 1_000_000)
            XCTAssertGreaterThan(needed, available)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(sidecar.recipe)
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0)
    }

    func testAPhotoThatCantBeJoinedIsReportedAndLeftOut() async throws {
        // Three overlapping photos and one of a different part of the sky.
        var shots = PanoMergeTestSupport.row(count: 3)
        shots.append(PanoMergeTestSupport.Shot(yaw: 2.4, pitch: 0.5))
        let urls = try PanoMergeTestSupport.cached("apart", shots)
        let merger = try merger()
        let (analysis, _) = try await merger.analyseWithReport(urls)

        XCTAssertEqual(analysis.frames.count, 4)
        XCTAssertTrue(analysis.frames[3].leftOut)
        XCTAssertNil(analysis.frames[3].yawPitchRoll)
        XCTAssertEqual(analysis.layout.cameras.map(\.frameIndex), [0, 1, 2])
        let warning = try XCTUnwrap(analysis.warnings.first {
            if case .framesLeftOut = $0 { return true } else { return false }
        })
        guard case .framesLeftOut(let indices) = warning else { return XCTFail("wrong warning") }
        XCTAssertEqual(indices, [3])
        XCTAssertTrue(warning.message(frames: analysis.frames).contains(urls[3].lastPathComponent))

        let destination = folder.appendingPathComponent("left-out.dng")
        let (result, _) = try await merger.mergeWithReport(
            analysis, options: PanoramaMergeOptions(), sources: PanoMergeTestSupport.sources(analysis),
            to: destination, prepareSidecar: { _ in }, progress: { _ in })
        XCTAssertEqual(result.recipe.options["leftOut"], .array([.number(3)]))
        XCTAssertEqual(result.recipe.options["stitched"], .number(3))
        XCTAssertEqual(result.recipe.options["photos"], .number(4))
        XCTAssertEqual(result.recipe.sources.count, 4, "every photo is still recorded")
    }

    // MARK: - Previews

    func testReleasingPreviewsMakesTheNextPreviewReadThePhotosAgain() async throws {
        let urls = try PanoMergeTestSupport.cached("row3", PanoMergeTestSupport.row(count: 3))
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: PanoramaMergeOptions())
        XCTAssertNotNil(merger.previewCache.frames(for: urls))
        let (first, cachedReport) = try await merger.previewWithReport(analysis, options: PanoramaMergeOptions(),
                                                                       longEdge: 300)
        XCTAssertFalse(cachedReport.stages.contains { $0.name == "Decode and reduce" })

        await merger.releasePreviews()
        XCTAssertNil(merger.previewCache.frames(for: urls))
        let (again, coldReport) = try await merger.previewWithReport(analysis, options: PanoramaMergeOptions(),
                                                                     longEdge: 300)
        XCTAssertTrue(coldReport.stages.contains { $0.name == "Decode and reduce" })
        XCTAssertEqual([first.width, first.height], [again.width, again.height])
    }

    func testAPreviewWithoutAutoCropShowsTheWholeCanvas() async throws {
        let urls = try PanoMergeTestSupport.cached("row3", PanoMergeTestSupport.row(count: 3))
        let merger = try merger()
        let analysis = try await merger.analyse(urls, options: PanoramaMergeOptions())
        let whole = try await merger.preview(analysis, options: PanoramaMergeOptions(autoCrop: false), longEdge: 300)
        let canvas = analysis.layout.canvas
        XCTAssertEqual(Double(whole.width) / Double(whole.height),
                       Double(canvas.width) / Double(canvas.height), accuracy: 0.05)
    }

    /// A recipe a callback hands back, from whatever thread calls it.
    final class RecipeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MergeRecipe?

        var recipe: MergeRecipe? { lock.withLock { stored } }
        func store(_ recipe: MergeRecipe) { lock.withLock { stored = recipe } }
    }
}
