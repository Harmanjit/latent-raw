import Foundation
import PixelEngine
import RawCore
import XCTest
@testable import MergeKit

/// Harman's own 17-frame handheld panorama (TestAssets/pano, not in the
/// repository: skipped when it is missing or with LATENT_CI_ASSETS_ONLY=1)
/// merged end to end, which is what Phase 8c is for.
///
/// Set LATENT_PANO_REVIEW to a folder to keep the DNG for looking at.
final class PanoMergeRealTests: XCTestCase {
    private func photos() throws -> [URL] {
        try XCTSkipIf(ProcessInfo.processInfo.environment["LATENT_CI_ASSETS_ONLY"] == "1", "CI assets only")
        let directory = TestAssets.url("pano")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("TestAssets/pano is missing")
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "nef" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Changing the projection in the dialog must not read the 17 raws and
    /// solve the geometry all over again: the projection decides the canvas
    /// and the crop, and nothing before them. The decoded photos and the
    /// solved cameras are kept, so the second analysis is a canvas and a
    /// coverage pass.
    func testAnotherProjectionReusesTheDecodedPhotosAndTheSolvedCameras() async throws {
        let urls = try photos()
        let merger = PanoramaMerger(gpu: try HDRTestSupport.gpu())
        let (first, firstReport) = try await merger.analyseWithReport(
            urls, options: PanoramaMergeOptions(projection: .automatic))
        let (second, secondReport) = try await merger.analyseWithReport(
            urls, options: PanoramaMergeOptions(projection: .spherical))

        // The photos are opened and decoded once, and the cameras solved once.
        let slow = ["Open photos", "Decode and reduce", "Solve cameras"]
        XCTAssertTrue(slow.allSatisfy { name in firstReport.stages.contains { $0.name == name } },
                      "\(firstReport.stages.map(\.name))")
        XCTAssertFalse(secondReport.stages.contains { slow.contains($0.name) },
                       "the second analysis must reuse them: \(secondReport.stages.map(\.name))")
        for (which, stages) in [("first", firstReport.stages), ("again", secondReport.stages)] {
            for stage in stages {
                print(String(format: "pano-projection | %@ %@ %.3f s", which, stage.name, stage.seconds))
            }
        }
        print(String(format: "pano-projection | first analysis %.2f s, another projection %.2f s (%.0fx faster)",
                     firstReport.totalSeconds, secondReport.totalSeconds,
                     firstReport.totalSeconds / max(secondReport.totalSeconds, 1e-9)))
        XCTAssertLessThan(secondReport.totalSeconds, firstReport.totalSeconds / 4)

        // And it really is the other projection, over the same cameras.
        XCTAssertEqual(first.layout.canvas.projection, .cylindrical)
        XCTAssertEqual(second.layout.canvas.projection, .spherical)
        XCTAssertEqual(second.layout.cameras, first.layout.cameras)
        XCTAssertEqual(second.frames.map(\.url), first.frames.map(\.url))
        XCTAssertNotEqual(second.layout.canvas.height, first.layout.canvas.height)

        // Closing the dialog gives the memory back; then it measures again.
        await merger.releasePreviews()
        let (_, afterRelease) = try await merger.analyseWithReport(
            urls, options: PanoramaMergeOptions(projection: .spherical))
        XCTAssertTrue(afterRelease.stages.contains { $0.name == "Decode and reduce" })
    }

    /// About 12 seconds on an M1 Pro: analysis 6 s, merge 6 s, 275 MB written.
    func testHarmansSeventeenFramesMergeIntoOnePanoramaDNG() async throws {
        let urls = try photos()
        XCTAssertEqual(urls.count, 17)
        let review = ProcessInfo.processInfo.environment["LATENT_PANO_REVIEW"]
        let folder = try review.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Fixtures.temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            if review == nil {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        _ = PanoramaFrameStore.removeScratchOfThisProcess()

        let merger = PanoramaMerger(gpu: try HDRTestSupport.gpu())
        let options = PanoramaMergeOptions()
        let (analysis, analysisReport) = try await merger.analyseWithReport(urls, options: options)

        // Every photo is part of the panorama, in capture order.
        XCTAssertEqual(analysis.frames.count, 17)
        XCTAssertEqual(analysis.layout.cameras.map(\.frameIndex), Array(0..<17))
        XCTAssertFalse(analysis.frames.contains(where: \.leftOut))
        XCTAssertEqual(analysis.layout.canvas.projection, .cylindrical)
        XCTAssertEqual(analysis.widthDegrees, 194, accuracy: 5)
        // The gains even the aperture changes out to well under a stop.
        for frame in analysis.frames { XCTAssertLessThan(abs(frame.gainStops), 1.5, frame.url.lastPathComponent) }
        // 224 MP is past what any Mac can edit, so it is reduced and said so.
        let size = analysis.outputSize
        XCTAssertTrue(size.needsDownsampling)
        XCTAssertLessThanOrEqual(max(size.width, size.height),
                                 PanoramaOutputSizer.maxTextureSide(try HDRTestSupport.gpu().device))
        XCTAssertGreaterThanOrEqual(size.decodeSpan, 2)
        XCTAssertTrue(analysis.warnings.contains { if case .downsampled = $0 { return true } else { return false } })
        // Handheld, with people walking close by: the solve leaves a few
        // pixels of parallax, and the dialog says so.
        XCTAssertTrue(analysis.warnings.contains { if case .largeParallax = $0 { return true } else { return false } })

        let preview = try await merger.preview(analysis, options: options, longEdge: 1024)
        XCTAssertEqual(max(preview.width, preview.height), 1024, accuracy: 2, "a preview of the size asked for")

        let destination = folder.appendingPathComponent("harman-pano.dng")
        try? FileManager.default.removeItem(at: destination)
        let (result, report) = try await merger.mergeWithReport(
            analysis, options: options, sources: PanoMergeTestSupport.sources(analysis), to: destination,
            prepareSidecar: { _ in }, progress: { _ in })
        print(String(format: "pano-merge-real | %d x %d px at scale %.3f, span %d; analysis %.1f s, merge %.1f s; "
                     + "%.0f MB written, %.0f MB scratch, peak GPU %.2f GB; bound %.3f, written %.3f",
                     size.width, size.height, size.scale, size.decodeSpan, analysisReport.totalSeconds,
                     report.totalSeconds, Double(result.byteCount) / 1e6, Double(report.scratchBytes) / 1e6,
                     Double(report.peakGPUBytes) / 1_073_741_824, report.maximumBound, report.maximumSeen))
        for stage in report.stages { print(String(format: "pano-merge-real |   %@ %.2f s", stage.name, stage.seconds)) }

        // It opens as a lens-corrected linear panorama of the size promised.
        let file = try RawFile(path: destination.path, metadataOnly: true)
        guard case .linearRGB = file.summary.cfaPattern else { return XCTFail("not a linear source") }
        XCTAssertEqual([file.summary.rawWidth, file.summary.rawHeight], [size.width, size.height])
        let info = try XCTUnwrap(file.summary.mergeInfo)
        XCTAssertEqual(info.kind, MergeRecipe.Kind.panorama.rawValue)
        XCTAssertTrue(info.lensApplied)
        XCTAssertNil(info.lens, "nothing may match a lens profile to a lens-corrected panorama")
        XCTAssertEqual(file.summary.orientation, 0, "the stitch is upright, though the photos were portrait")
        XCTAssertEqual(file.summary.cameraModel, "D750")
        XCTAssertGreaterThanOrEqual(report.maximumBound, report.maximumSeen)
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0)
    }
}
