import XCTest
import simd
@testable import MergeKit

/// Real brackets from TestAssets/merge (not in the repository; skipped when
/// missing). Each prints what alignment found, neighbour by neighbour and
/// carried to the middle frame.
final class AlignRealBracketTests: XCTestCase {
    /// Aligns a bracket's neighbours and chains them to the middle frame.
    private func alignBracket(_ folder: String) throws -> (results: [AlignmentResult], links: [AlignmentResult],
                                                          images: [AlignmentImage]) {
        let (images, names) = try AlignTestSupport.realBracket(folder)
        let reference = (images.count - 1) / 2
        let aligner = FrameAligner()
        var links: [AlignmentResult] = []
        for k in 0..<(images.count - 1) {
            let start = Date()
            let link = aligner.align(moving: images[k], reference: images[k + 1], model: .hdr)
            let seconds = Date().timeIntervalSince(start)
            links.append(link)
            // At the finest level, where a fraction of a pixel shows: the
            // estimate must match better than leaving the frame where it is.
            let aligned = aligner.score(link.estimatedHomography, moving: images[k], reference: images[k + 1],
                                        finestLevel: true).ncc
            let unaligned = aligner.score(Homography.identity, moving: images[k], reference: images[k + 1],
                                          finestLevel: true).ncc
            XCTAssertGreaterThan(aligned, unaligned, "aligning must match better than not aligning")
            let centre = SIMD2(Double(images[k].fullWidth), Double(images[k].fullHeight)) / 2
            let shift = Homography.apply(link.estimatedHomography, centre) - centre
            print(String(format: "align-real | %@ | %@ -> %@ | shift (%.2f, %.2f) px | rotation %.3f deg | scale %+.4f%% | corners %.2f px | NCC %.4f (finest level %.4f, unaligned %.4f) | overlap %.3f | %@ | %.2f s",
                         folder, names[k], names[k + 1], shift.x, shift.y,
                         Homography.rotationDegrees(link.estimatedHomography, at: centre), 100 * link.scaleChange,
                         link.maxCornerShift, link.ncc, aligned, unaligned, link.overlapFraction,
                         link.accepted ? "accepted" : "rejected \(String(describing: link.rejection))", seconds))
        }
        let results = FrameAligner.chain(links, reference: reference, width: images[reference].fullWidth,
                                         height: images[reference].fullHeight)
        for (index, result) in results.enumerated() {
            print(String(format: "align-real | %@ | %@ to reference %@ | corners %.2f px | warp %@",
                         folder, names[index], names[reference], result.maxCornerShift, result.needsWarp ? "yes" : "no"))
        }
        return (results, links, images)
    }

    /// Handheld (frames up to about 17 px apart), people walking: every
    /// neighbour pair aligns, and nothing moved implausibly far.
    func testEmpaMarketMires() throws {
        let (results, links, _) = try alignBracket("empa-market-mires-2")
        for link in links {
            XCTAssertTrue(link.accepted, String(describing: link.rejection))
            XCTAssertLessThan(link.maxCornerShift, 60)
            XCTAssertLessThan(abs(link.scaleChange), 0.005)
        }
        XCTAssertTrue(results.contains { $0.needsWarp }, "a handheld bracket needs warping")
    }

    /// A tripod bracket with wind in the leaves. A tripod still moves a
    /// little between exposures (half a pixel to a pixel here, a few
    /// hundredths of a degree), so the frames come out near the identity
    /// but not at it.
    func testIhrkeTripod() throws {
        let (results, links, images) = try alignBracket("ihrke-tripod-bracket")
        for link in links { XCTAssertTrue(link.accepted, String(describing: link.rejection)) }
        assertNearIdentity(results, images[0])
    }

    /// A tripod bracket of moving waves, near the identity too. Checked by
    /// hand when this was written: the local shifts of textured, still
    /// patches of each frame agreed with the homography within 0.1 px.
    func testEmpaCreteSeashore() throws {
        let (results, links, images) = try alignBracket("empa-crete-seashore-1")
        for link in links { XCTAssertTrue(link.accepted, String(describing: link.rejection)) }
        assertNearIdentity(results, images[0])
    }

    /// Within 2 px at the centre, 0.1 degrees, 0.1% scale and 5 px at the corners.
    private func assertNearIdentity(_ results: [AlignmentResult], _ frame: AlignmentImage,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let centre = SIMD2(Double(frame.fullWidth), Double(frame.fullHeight)) / 2
        for result in results {
            let h = result.estimatedHomography
            XCTAssertLessThan(simd_distance(Homography.apply(h, centre), centre), 2, file: file, line: line)
            XCTAssertLessThan(abs(Homography.rotationDegrees(h, at: centre)), 0.1, file: file, line: line)
            XCTAssertLessThan(abs(result.scaleChange), 0.001, file: file, line: line)
            XCTAssertLessThan(result.maxCornerShift, 5, file: file, line: line)
        }
    }
}
