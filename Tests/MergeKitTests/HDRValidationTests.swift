import XCTest
import PixelEngine
@testable import MergeKit

/// Every reason a set of photos can't be merged, as `HDRMergeError`.
final class HDRValidationTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws {
        folder = try Fixtures.temporaryFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A small bracket (120 x 80), noiseless: validation never needs more.
    private func bracket(_ frames: [SyntheticBracket.Frame], name: String = "v",
                         width: Int = 120, height: Int = 80) throws -> [URL] {
        try SyntheticBracket.write(frames, of: SyntheticBracket.scene(width: width, height: height), noise: false,
                                   to: folder, name: name)
    }

    private func assertAnalysis(of urls: [URL], merger: HDRMerger? = nil, throws expected: HDRMergeError,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await (merger ?? HDRTestSupport.merger()).analyse(urls)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as HDRMergeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    func testTooFewFrames() async throws {
        let urls = try bracket(SyntheticBracket.frames([1]))
        try await assertAnalysis(of: urls, throws: .tooFewFrames)
        try await assertAnalysis(of: [], throws: .tooFewFrames)
    }

    func testTooManyFrames() async throws {
        let urls = try bracket(SyntheticBracket.frames([4, 1]))
        // The count is checked before any file is opened.
        try await assertAnalysis(of: Array(repeating: urls[0], count: 10), throws: .tooManyFrames(limit: 9))
        let small = try HDRTestSupport.merger(memoryPolicy: MemoryPolicy(physicalMemory: 8 << 30))
        try await assertAnalysis(of: Array(repeating: urls[0], count: 6), merger: small, throws: .tooManyFrames(limit: 5))
    }

    func testDifferentCameras() async throws {
        var frames = SyntheticBracket.frames([4, 1])
        frames[1].model = "D610"
        try await assertAnalysis(of: try bracket(frames), throws: .differentCameras)
    }

    func testDifferentSizes() async throws {
        let a = try bracket(SyntheticBracket.frames([4]), name: "a")
        let b = try bracket(SyntheticBracket.frames([1]), name: "b", width: 100)
        try await assertAnalysis(of: a + b, throws: .differentSizes)
    }

    func testDifferentOrientations() async throws {
        var frames = SyntheticBracket.frames([4, 1])
        frames[1].orientation = 6
        try await assertAnalysis(of: try bracket(frames), throws: .differentOrientations)
    }

    /// An already-merged (linear) DNG isn't a Bayer raw.
    func testUnsupportedSource() async throws {
        let raws = try bracket(SyntheticBracket.frames([4]))
        var writer = LinearRawDNGWriter()
        writer.availableCapacity = { _ in nil }
        let linear = try writer.write(.buffer(Fixtures.pixels(width: 64, height: 48, maximum: 1), width: 64, height: 48),
                                      maximum: 1, metadata: Fixtures.metadata(), recipe: Fixtures.recipe(),
                                      preview: Fixtures.previewImage(), to: folder.appendingPathComponent("merged.dng"))
        try await assertAnalysis(of: raws + [linear.url], throws: .unsupportedSource(fileName: "merged.dng"))
    }

    func testSameExposure() async throws {
        // 0.2 stops apart: under the 0.3 a bracket needs.
        let urls = try bracket(SyntheticBracket.frames([1, pow(2, -0.2)]))
        try await assertAnalysis(of: urls, throws: .sameExposure)
    }

    func testUnreadable() async throws {
        let urls = try bracket(SyntheticBracket.frames([4]))
        let junk = folder.appendingPathComponent("junk.nef")
        try Data("not a raw file".utf8).write(to: junk)
        do {
            _ = try await HDRTestSupport.merger().analyse(urls + [junk])
            XCTFail("expected unreadable")
        } catch HDRMergeError.unreadable(let name, let reason) {
            XCTAssertEqual(name, "junk.nef")
            XCTAssertFalse(reason.isEmpty)
        }
        let missing = folder.appendingPathComponent("gone.nef")
        do {
            _ = try await HDRTestSupport.merger().analyse(urls + [missing])
            XCTFail("expected unreadable")
        } catch HDRMergeError.unreadable(let name, _) {
            XCTAssertEqual(name, "gone.nef")
        }
    }

    /// The disk check runs before any merging, and nothing is written.
    func testNotEnoughDiskSpace() async throws {
        let urls = try bracket(SyntheticBracket.frames([4, 1]))
        let merger = try HDRTestSupport.merger(availableCapacity: { _ in 10_000_000 })
        let analysis = try await merger.analyse(urls)
        let destination = folder.appendingPathComponent("out.dng")
        let sidecarCalled = LockedFlag()
        do {
            _ = try await merger.merge(analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls),
                                       to: destination, prepareSidecar: { _ in sidecarCalled.set() }, progress: { _ in })
            XCTFail("expected notEnoughDiskSpace")
        } catch HDRMergeError.notEnoughDiskSpace(let needed, let available) {
            XCTAssertEqual(available, 10_000_000)
            XCTAssertEqual(needed, analysis.estimatedOutputBytes + HDRMerger.freeSpaceMargin)
        }
        XCTAssertFalse(sidecarCalled.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A merge bigger than the GPU can hold is refused before it starts.
    func testGPUUnavailable() async throws {
        let urls = try bracket(SyntheticBracket.frames([4, 1]))
        let merger = try HDRTestSupport.merger(gpuMemoryBudget: 100_000)
        let analysis = try await merger.analyse(urls)
        do {
            _ = try await merger.merge(analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls),
                                       to: folder.appendingPathComponent("out.dng"), prepareSidecar: { _ in },
                                       progress: { _ in })
            XCTFail("expected gpuUnavailable")
        } catch HDRMergeError.gpuUnavailable(let reason) {
            XCTAssertTrue(reason.contains("graphics memory"), reason)
        }
    }

    func testErrorsHaveMessages() {
        let errors: [HDRMergeError] = [.tooFewFrames, .tooManyFrames(limit: 5), .differentCameras, .differentSizes,
                                       .differentOrientations, .unsupportedSource(fileName: "a.dng"), .sameExposure,
                                       .notEnoughDiskSpace(neededBytes: 1, availableBytes: 0),
                                       .unreadable(fileName: "a.nef", reason: "why"), .gpuUnavailable(reason: "why")]
        for error in errors { XCTAssertFalse(error.errorDescription?.isEmpty ?? true) }
    }
}

/// A Bool set from any thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
