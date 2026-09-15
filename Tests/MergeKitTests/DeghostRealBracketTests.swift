import XCTest
import PixelEngine
import RawCore
@testable import MergeKit

/// Deghosting and clip feathering on real brackets with movement, each
/// merged without and with deghosting at medium. The brackets live in
/// TestAssets/merge, which isn't in the repository, so these skip where
/// they're missing, CI included.
///
/// What they check is deliberately coarse, because the truth isn't known:
/// deghosting makes the moving area sharper (one exposure instead of a
/// blend of several), it leaves out a sane share of each frame, and it
/// doesn't raise the merge's GPU memory.
final class DeghostRealBracketTests: XCTestCase {
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/merge")

    /// The raws of a bracket folder, or a skip.
    static func bracket(_ name: String, extension ext: String) throws -> [URL] {
        let folder = assets.appendingPathComponent(name)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.uppercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.count >= 2 else { throw XCTSkip("TestAssets/merge/\(name) isn't here") }
        return urls
    }

    typealias Region = (x: Int, y: Int, width: Int, height: Int)

    /// Merges an analysed bracket and returns the luminance (the mean of
    /// camera RGB, on the merge's scale) over `region`, and the report.
    static func merge(_ analysis: HDRMergeAnalysis, merger: HDRMerger, options: HDRMergeOptions,
                      region: Region) async throws -> (luminance: [Float], report: HDRMergeReport) {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (result, report) = try await merger.mergeWithReport(
            analysis, options: options, sources: HDRTestSupport.sources(analysis.frames.map(\.url)),
            to: folder.appendingPathComponent("merged-HDR.dng"), prepareSidecar: { _ in }, progress: { _ in })
        let file = try RawFile(path: result.url.path)
        let plane = try XCTUnwrap(file.linearPlane)
        let scale = Float(1 << (file.summary.mergeInfo?.baselineShift ?? 0)) / 3
        let samples = plane.samples
        var luminance = [Float](repeating: 0, count: region.width * region.height)
        for y in 0..<region.height {
            for x in 0..<region.width {
                let i = ((region.y + y) * plane.width + region.x + x) * 4
                luminance[y * region.width + x] = (Float(samples[i]) + Float(samples[i + 1]) + Float(samples[i + 2])) * scale
            }
        }
        return (luminance, report)
    }

    /// What a bracket looks like merged without and with deghosting.
    struct Outcome {
        let none: (sharpness: Double, report: HDRMergeReport)
        let medium: (sharpness: Double, report: HDRMergeReport)
        let reference: Int
    }

    static func mergeBothWays(_ urls: [URL], region: Region) async throws -> Outcome {
        let merger = try HDRTestSupport.merger()
        let analysis = try await merger.analyse(urls)
        let none = try await merge(analysis, merger: merger, options: HDRMergeOptions(), region: region)
        let medium = try await merge(analysis, merger: merger, options: HDRMergeOptions(deghost: .medium),
                                     region: region)
        return Outcome(none: (sharpness(none.luminance, width: region.width, height: region.height), none.report),
                       medium: (sharpness(medium.luminance, width: region.width, height: region.height), medium.report),
                       reference: analysis.referenceIndex)
    }

    /// The mean absolute difference of log2 luminance between neighbouring
    /// pixels: a blend of several poses of something moving has softer
    /// edges than any one pose.
    static func sharpness(_ luminance: [Float], width: Int, height: Int) -> Double {
        var total = 0.0, count = 0
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let centre = log2(max(luminance[y * width + x], 1e-6))
                total += Double(abs(log2(max(luminance[y * width + x + 1], 1e-6)) - centre))
                total += Double(abs(log2(max(luminance[(y + 1) * width + x], 1e-6)) - centre))
                count += 2
            }
        }
        return total / Double(max(count, 1))
    }

    /// Dark holes: pixels the merge makes more than 40% darker than `truth`
    /// says, where `truth` is brighter than `sky`.
    static func holes(_ luminance: [Float], truth: [Float], sky: Float) -> Int {
        zip(luminance, truth).filter { merged, truth in truth >= sky && merged < 0.6 * truth }.count
    }

    /// Waves on a shore, 7 frames 1 stop apart (Nikon D200, tripod).
    func testCreteWavesComeFromOneExposure() async throws {
        let urls = try Self.bracket("empa-crete-seashore-1", extension: "NEF")
        let outcome = try await Self.mergeBothWays(urls, region: (200, 1900, 900, 600))
        print("Crete: sharpness \(outcome.none.sharpness) -> \(outcome.medium.sharpness), "
              + "masked \(outcome.medium.report.ghostMaskedFractions)")
        XCTAssertGreaterThan(outcome.medium.sharpness, 1.15 * outcome.none.sharpness)
        Self.checkShares(outcome, most: 0.4)
    }

    /// People walking through a market, 5 frames 1 stop apart, handheld:
    /// until alignment arrives the frames are up to 17 px apart, so a large
    /// share counts as moving.
    func testMarketMiresPeopleComeFromOneExposure() async throws {
        let urls = try Self.bracket("empa-market-mires-2", extension: "NEF")
        let outcome = try await Self.mergeBothWays(urls, region: (900, 1400, 900, 600))
        print("Market Mires: sharpness \(outcome.none.sharpness) -> \(outcome.medium.sharpness), "
              + "masked \(outcome.medium.report.ghostMaskedFractions)")
        XCTAssertGreaterThan(outcome.medium.sharpness, 1.1 * outcome.none.sharpness)
        Self.checkShares(outcome, most: 0.7)
    }

    /// Wind-blown birch leaves against a bright sky, 6 frames 2 stops apart
    /// (Canon 5D Mark II, tripod), the set where clip weights judged pixel by
    /// pixel punched dark holes into the sky.
    ///
    /// The truth for the sky is a merge of the two shortest exposures alone
    /// (1/320 and 1/1250 s): their sky isn't clipped, and the leaves barely
    /// move during them. A hole is the full merge more than 40% darker than
    /// that where it sees bright sky.
    func testIhrkeLeavesLeaveNoHolesInTheSky() async throws {
        let urls = try Self.bracket("ihrke-tripod-bracket", extension: "CR2")
        let region: Region = (2900, 500, 900, 600)
        let merger = try HDRTestSupport.merger()
        let analysis = try await merger.analyse(urls)
        let shortest = Array(analysis.frames.suffix(2))
        let shortAnalysis = try await merger.analyse(shortest.map(\.url))
        var truth = try await Self.merge(shortAnalysis, merger: merger, options: HDRMergeOptions(), region: region).luminance
        // The short merge is on its brighter frame's scale; the full merge on
        // the 1 s frame's, which saw 2^-relativeEV times more light.
        let gain = Float(pow(2, -shortest[0].relativeEV))
        truth = truth.map { $0 * gain }
        let sky = 0.5 * truth.sorted()[truth.count * 9 / 10]

        let unfeathered = try HDRTestSupport.merger(clipFeather: HDRClipFeather(erodeRadius: 0, sigma: 0))
        let before = try await Self.merge(analysis, merger: unfeathered, options: HDRMergeOptions(), region: region)
        let none = try await Self.merge(analysis, merger: merger, options: HDRMergeOptions(), region: region)
        let medium = try await Self.merge(analysis, merger: merger, options: HDRMergeOptions(deghost: .medium),
                                          region: region)
        let holes = [before, none, medium].map { Self.holes($0.luminance, truth: truth, sky: sky) }
        print("Ihrke: holes unfeathered \(holes[0]), feathered \(holes[1]), medium \(holes[2]); "
              + "masked \(medium.report.ghostMaskedFractions)")
        XCTAssertLessThan(holes[1], holes[0] / 3, "feathering removes most holes")
        XCTAssertLessThan(holes[2], holes[1], "deghosting removes more")
        let outcome = Outcome(none: (0, none.report), medium: (0, medium.report), reference: analysis.referenceIndex)
        Self.checkShares(outcome, most: 0.3)
    }

    /// Every frame but the reference has a share masked, none too much; the
    /// reference none; and deghosting costs no GPU memory to speak of.
    static func checkShares(_ outcome: Outcome, most: Double, file: StaticString = #filePath, line: UInt = #line) {
        let masked = outcome.medium.report.ghostMaskedFractions
        XCTAssertEqual(masked[outcome.reference], 0, file: file, line: line)
        for (i, share) in masked.enumerated() where i != outcome.reference {
            XCTAssertLessThan(share, most, "frame \(i)", file: file, line: line)
        }
        XCTAssertLessThan(Double(outcome.medium.report.peakGPUBytes), 1.1 * Double(outcome.none.report.peakGPUBytes),
                          file: file, line: line)
    }
}
