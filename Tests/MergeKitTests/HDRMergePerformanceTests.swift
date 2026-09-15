import XCTest
import PixelEngine
@testable import MergeKit

/// Three 24 MP frames (6016 x 4016, a Nikon D750's size), analysed and
/// merged, timed stage by stage. Writes about 150 MB of raws and 150 MB of
/// DNG, so it only runs when asked:
///
///     LATENT_PERF=1 swift test --filter HDRMergePerformanceTests
///
/// Set LATENT_HDR_BRACKET_DIR to a folder to keep the bracket there (for
/// timing `latent-cli merge-hdr` in a release build on the same frames).
/// The plan's target is under 10 s for the whole merge (docs/PhotoMerge.md
/// section 6); a debug build's CPU stages run several times slower than a
/// release build's.
final class HDRMergePerformanceTests: XCTestCase {
    func testThreeFrame24MegapixelMerge() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LATENT_PERF"] == "1" else {
            throw XCTSkip("set LATENT_PERF=1 to time a 3 x 24 MP merge")
        }
        let keep = environment["LATENT_HDR_BRACKET_DIR"].map { URL(fileURLWithPath: $0) }
        let folder = try keep ?? Fixtures.temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: folder) } }

        let (width, height) = (6016, 4016)
        let generated = Date()
        let scene = SyntheticBracket.scene(width: width, height: height)
        let urls = try SyntheticBracket.write(SyntheticBracket.frames(HDRTestSupport.threeExposures), of: scene,
                                              noise: true, to: folder, name: "perf24")
        print(String(format: "Generated the bracket in %.1f s", Date().timeIntervalSince(generated)))

        let merger = HDRMerger(gpu: try HDRTestSupport.gpu(), memoryPolicy: MemoryPolicy(physicalMemory: 16 << 30),
                               availableCapacity: { _ in nil }, keepsPreviewFrames: true)
        let (analysis, analysisReport) = try await merger.analyseWithReport(urls)

        // The dialog's preview, twice: the second is what an option change
        // costs once the frames are kept and the GPU's pipelines are built.
        for deghost in [DeghostAmount.none, .medium] {
            let options = HDRMergeOptions(deghost: deghost)
            var seconds: [Double] = []
            for _ in 0..<2 {
                let clock = ContinuousClock(), started = clock.now
                _ = try await merger.preview(analysis, options: options, longEdge: 1024,
                                             showDeghostOverlay: deghost != .none)
                let elapsed = clock.now - started
                seconds.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
            }
            print(String(format: "Preview of 3 x 24 MP, deghost %@: %.3f s, then %.3f s", deghost.rawValue as NSString,
                         seconds[0], seconds[1]))
            // The dialog wants under 0.3 s in a release build; this is a
            // debug build on a machine that may be busy.
            XCTAssertLessThan(seconds[1], 3)
        }
        merger.releasePreviews()
        let output = folder.appendingPathComponent("perf24-HDR.dng")
        try? FileManager.default.removeItem(at: output)
        let (result, mergeReport) = try await merger.mergeWithReport(
            analysis, options: HDRMergeOptions(), sources: HDRTestSupport.sources(urls), to: output,
            prepareSidecar: { _ in }, progress: { _ in })
        if keep == nil { try? FileManager.default.removeItem(at: output) }

        for (title, report) in [("analysis", analysisReport), ("merge", mergeReport)] {
            print("\(title):")
            for stage in report.stages { print(String(format: "  %-40@ %6.3f s", stage.name as NSString, stage.seconds)) }
            print(String(format: "  total %.2f s, peak GPU %.2f GB", report.totalSeconds,
                         Double(report.peakGPUBytes) / 1_073_741_824))
        }
        print(String(format: "3 x 24 MP HDR: %.2f s (analysis %.2f + merge %.2f), DNG %.0f MB",
                     analysisReport.totalSeconds + mergeReport.totalSeconds, analysisReport.totalSeconds,
                     mergeReport.totalSeconds, Double(result.byteCount) / 1e6))
        for (frame, want) in zip(analysis.frames, [0.0, -2, -4]) {
            XCTAssertEqual(frame.relativeEV, want, accuracy: 0.02)
        }
        XCTAssertEqual(analysis.warnings, [])
        // Generous for a debug build on a loaded machine; the release
        // number is what the plan's 10 s is about.
        XCTAssertLessThan(analysisReport.totalSeconds + mergeReport.totalSeconds, 60)
    }
}
