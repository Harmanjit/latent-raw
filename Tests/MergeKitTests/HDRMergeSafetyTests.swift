import XCTest
import PixelEngine
@testable import MergeKit

/// What a merge promises the app beyond its pixels: the sidecar comes
/// first, a failure or a cancellation leaves no DNG, progress is reported,
/// and GPU memory doesn't grow with the number of frames.
final class HDRMergeSafetyTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws {
        folder = try Fixtures.temporaryFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The files in the output folder, temporary ones included.
    private func outputFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testSidecarIsPreparedBeforeTheDNGExistsWithTheStoredRecipe() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let merger = try HDRTestSupport.merger()
        let analysis = try await merger.analyse(urls)
        let destination = folder.appendingPathComponent("out-HDR.dng")
        let seen = RecipeBox()
        let progress = ProgressLog()
        let result = try await merger.merge(
            analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls), to: destination,
            prepareSidecar: { recipe in
                seen.record(recipe, dngExisted: FileManager.default.fileExists(atPath: destination.path))
            },
            progress: { progress.append($0) })
        let (recipe, dngExisted) = try XCTUnwrap(seen.value)
        XCTAssertFalse(dngExisted, "the sidecar must be written before the DNG")
        XCTAssertEqual(recipe, result.recipe, "the sidecar gets the recipe exactly as the DNG stores it")
        XCTAssertEqual(try outputFiles(), ["out-HDR.dng"])

        let steps = progress.values
        XCTAssertEqual(steps.first?.fraction, 0)
        XCTAssertEqual(steps.last?.fraction, 1)
        XCTAssertEqual(steps.map(\.fraction), steps.map(\.fraction).sorted(), "progress only moves forward")
        XCTAssertTrue(steps.contains { $0.stage == "Merging photo 3 of 3" })
    }

    func testThrowingSidecarWritesNothing() async throws {
        struct SidecarFailed: Error {}
        let urls = try HDRTestSupport.cleanBracket()
        let merger = try HDRTestSupport.merger()
        let analysis = try await merger.analyse(urls)
        do {
            _ = try await merger.merge(analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls),
                                       to: folder.appendingPathComponent("out-HDR.dng"),
                                       prepareSidecar: { _ in throw SidecarFailed() }, progress: { _ in })
            XCTFail("the sidecar's error must be rethrown")
        } catch is SidecarFailed {}
        XCTAssertEqual(try outputFiles(), [])
    }

    /// Cancelled between frames: CancellationError, no sidecar, no DNG.
    func testCancelledBetweenFramesLeavesNothing() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let merger = try HDRTestSupport.merger()
        let analysis = try await merger.analyse(urls)
        let sidecar = LockedFlag()
        do {
            _ = try await merger.merge(
                analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls),
                to: folder.appendingPathComponent("out-HDR.dng"), prepareSidecar: { _ in sidecar.set() },
                progress: { step in
                    // Progress is reported from the merge's own task, so this
                    // cancels the merge as the second frame starts.
                    if step.stage == "Merging photo 2 of 3" { withUnsafeCurrentTask { $0?.cancel() } }
                })
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertFalse(sidecar.value)
        XCTAssertEqual(try outputFiles(), [])
    }

    /// Cancelled while the app writes the sidecar: still no DNG.
    func testCancelledDuringSidecarLeavesNoDNG() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let merger = try HDRTestSupport.merger()
        let analysis = try await merger.analyse(urls)
        do {
            _ = try await merger.merge(
                analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls),
                to: folder.appendingPathComponent("out-HDR.dng"),
                prepareSidecar: { _ in withUnsafeCurrentTask { $0?.cancel() } }, progress: { _ in })
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(try outputFiles(), [])
    }

    /// Frames are merged one at a time into textures made once, so five
    /// frames peak no higher than three.
    func testGPUMemoryIsFlatAsFramesAreAdded() async throws {
        let three = try HDRTestSupport.cleanBracket()
        let five = try HDRTestSupport.bracket("clean5", SyntheticBracket.frames([16, 4, 1, 0.25, 0.0625]), noise: false)
        let merger = try HDRTestSupport.merger()
        // A first merge builds the pipelines and caches, so both measured
        // merges start from the same state.
        _ = try await HDRTestSupport.merge(three, merger: merger)
        let (_, _, threeReport, threeFolder) = try await HDRTestSupport.merge(three, merger: merger)
        let (_, _, fiveReport, fiveFolder) = try await HDRTestSupport.merge(five, merger: merger)
        try? FileManager.default.removeItem(at: threeFolder)
        try? FileManager.default.removeItem(at: fiveFolder)
        // Room for Metal's own small allocations to vary: 2% of the merge's
        // estimated textures.
        let slack = HDRMergeAccumulator.estimatedPeakBytes(width: 1200, height: 800) / 50
        XCTAssertGreaterThan(threeReport.peakGPUBytes, 0)
        XCTAssertLessThanOrEqual(fiveReport.peakGPUBytes, threeReport.peakGPUBytes + slack,
                                 "3 frames peaked at \(threeReport.peakGPUBytes) bytes, 5 at \(fiveReport.peakGPUBytes)")
    }
}

final class RecipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (MergeRecipe, Bool)?
    func record(_ recipe: MergeRecipe, dngExisted: Bool) { lock.lock(); stored = (recipe, dngExisted); lock.unlock() }
    var value: (MergeRecipe, Bool)? { lock.lock(); defer { lock.unlock() }; return stored }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [HDRMergeProgress] = []
    func append(_ step: HDRMergeProgress) { lock.lock(); steps.append(step); lock.unlock() }
    var values: [HDRMergeProgress] { lock.lock(); defer { lock.unlock() }; return steps }
}
