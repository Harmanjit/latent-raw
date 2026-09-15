import XCTest
import CoreGraphics
import PixelEngine
import RawCore
import simd
@testable import MergeKit

/// The HDR dialog's preview (Phase 7): the merge made small from frames kept
/// in memory. It must look like the full merge reduced, never read the raw
/// files again once they are kept, keep its memory bounded, and draw the
/// deghost overlay where deghosting acted.
final class HDRPreviewTests: XCTestCase {
    /// A merger that keeps preview frames while analysing (as the dialog's
    /// does), on an unconstrained Mac with plenty of disk.
    private func merger(keepsPreviewFrames: Bool = true) throws -> HDRMerger {
        HDRMerger(gpu: try HDRTestSupport.gpu(), memoryPolicy: MemoryPolicy(physicalMemory: 16 << 30),
                  availableCapacity: { _ in nil }, keepsPreviewFrames: keepsPreviewFrames)
    }

    /// An image's pixels as 8-bit sRGB, four bytes each.
    struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            self.bytes = bytes
        }

        func rgb(_ x: Int, _ y: Int) -> SIMD3<Int> {
            let i = (y * width + x) * 4
            return SIMD3(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let c = SIMD3<Double>(rgb(x, y))
            return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        }

        var meanLuminance: Double {
            var sum = 0.0
            for y in 0..<height { for x in 0..<width { sum += luminance(x, y) } }
            return sum / Double(width * height)
        }
    }

    /// The full merge's DNG as Latent opens it, with default settings,
    /// binned to half size: the picture the preview stands in for.
    private func renderHalfSize(_ url: URL) throws -> CGImage {
        let gpu = try HDRTestSupport.gpu()
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        let rendered = try RenderPipeline(gpu: gpu).render(session, scale: .binned(quads: 1), parameters: parameters)
        return try Exporter(gpu: gpu).cgImage(from: rendered, colorSpace: .sRGB)
    }

    /// Mean and 99th-percentile difference (8-bit levels, largest channel)
    /// between `a` and `b` where `b` is smooth: nothing in its 5 x 5
    /// neighbourhood differs by more than `smooth` levels of luminance. At
    /// edges a demosaic on fewer pixels differs from one on more, as it should.
    private func difference(_ a: Pixels, _ b: Pixels, smooth: Double = 6) -> (mean: Double, p99: Int, count: Int) {
        var diffs: [Int] = []
        for y in 2..<(b.height - 2) {
            for x in 2..<(b.width - 2) {
                var low = Double.infinity, high = -Double.infinity
                for dy in -2...2 { for dx in -2...2 {
                    let l = b.luminance(x + dx, y + dy)
                    low = min(low, l); high = max(high, l)
                } }
                guard high - low <= smooth else { continue }
                let d = a.rgb(x, y) &- b.rgb(x, y)
                diffs.append(max(abs(d.x), abs(d.y), abs(d.z)))
            }
        }
        diffs.sort()
        let mean = Double(diffs.reduce(0, +)) / Double(max(1, diffs.count))
        return (mean, diffs.isEmpty ? 0 : diffs[diffs.count * 99 / 100], diffs.count)
    }

    // MARK: - Like the merge

    /// With no deghosting, and with deghosting of a moving square, the
    /// preview at half size matches the full merge's DNG rendered at half
    /// size wherever the picture is smooth.
    func testThePreviewMatchesTheFullMergeReduced() async throws {
        for (urls, options) in [(try HDRTestSupport.noisyBracket(), HDRMergeOptions()),
                                (try DeghostTests.movingSquareBracket(),
                                 HDRMergeOptions(referenceIndex: 1, deghost: .medium))] {
            let merger = try merger()
            let analysis = try await merger.analyse(urls, options: options)
            let preview = Pixels(try await merger.preview(analysis, options: options, longEdge: 600,
                                                          showDeghostOverlay: false))
            XCTAssertEqual([preview.width, preview.height], [600, 400])

            let folder = try Fixtures.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let result = try await merger.merge(analysis, options: options, sources: HDRTestSupport.sources(urls),
                                                to: folder.appendingPathComponent("merged-HDR.dng"),
                                                prepareSidecar: { _ in }, progress: { _ in })
            let full = Pixels(try renderHalfSize(result.url))
            XCTAssertEqual([full.width, full.height], [600, 400])
            let (mean, p99, count) = difference(preview, full)
            XCTAssertGreaterThan(count, 100_000, "most of the scene is smooth")
            XCTAssertLessThan(mean, 1.5, "\(options)")
            XCTAssertLessThanOrEqual(p99, 6, "\(options)")
        }
    }

    /// Picking another reference changes how the result opens: the DNG's
    /// BaselineExposure moves by the frames' difference in exposure, and the
    /// preview brightens or darkens with it.
    func testPickingTheReferenceChangesBaselineExposure() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let merger = try merger()
        let analysis = try await merger.analyse(urls)
        var baselines: [Double] = [], brightness: [Double] = []
        for reference in [0, 2] {
            let options = HDRMergeOptions(referenceIndex: reference)
            let folder = try Fixtures.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let result = try await merger.merge(analysis, options: options, sources: HDRTestSupport.sources(urls),
                                                to: folder.appendingPathComponent("merged-HDR.dng"),
                                                prepareSidecar: { _ in }, progress: { _ in })
            XCTAssertEqual(result.recipe.reference, reference)
            baselines.append(result.baselineExposure)
            let preview = try await merger.preview(analysis, options: options, longEdge: 300, showDeghostOverlay: false)
            brightness.append(Pixels(preview).meanLuminance)
        }
        XCTAssertEqual(baselines[1] - baselines[0], analysis.frames[2].relativeEV - analysis.frames[0].relativeEV,
                       accuracy: 0.01)
        XCTAssertEqual(baselines[1] - baselines[0], -4, accuracy: 0.02)
        XCTAssertGreaterThan(brightness[0], brightness[1] + 20, "the brightest frame's exposure opens brighter")
    }

    // MARK: - Memory and files

    /// Once the analysis has kept the frames, previews never open the raw
    /// files: they still work with the files gone. A merger that doesn't
    /// keep them reads them for the first preview.
    func testPreviewsDontReadTheRawFilesAgain() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var urls: [URL] = []
        for url in try DeghostTests.movingSquareBracket() {
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            urls.append(copy)
        }
        let keeping = try merger()
        let reading = try merger(keepsPreviewFrames: false)
        let analysis = try await keeping.analyse(urls)
        XCTAssertEqual(reading.previewCache.byteCount, 0)
        for url in urls { try FileManager.default.removeItem(at: url) }

        for options in [HDRMergeOptions(), HDRMergeOptions(referenceIndex: 2, deghost: .high, autoAlign: false)] {
            let image = try await keeping.preview(analysis, options: options, longEdge: 400, showDeghostOverlay: true)
            XCTAssertEqual(image.width, 400)
        }
        do {
            _ = try await reading.preview(analysis, options: HDRMergeOptions(), longEdge: 400, showDeghostOverlay: false)
            XCTFail("a merger that kept nothing has to read the files")
        } catch HDRMergeError.unreadable {
        }
    }

    /// One bracket's frames at most, at a bounded size, and nothing once
    /// released; a released merger reads the files again when asked.
    func testThePreviewCacheIsBoundedAndReleased() async throws {
        let merger = try merger()
        let clean = try HDRTestSupport.cleanBracket()
        let analysis = try await merger.analyse(clean)
        let frameBytes = 1200 * 800 * 2
        XCTAssertEqual(merger.previewCache.byteCount, 3 * frameBytes, "1200 x 800 frames are kept whole")

        _ = try await merger.preview(analysis, options: HDRMergeOptions(), longEdge: 300, showDeghostOverlay: false)
        XCTAssertEqual(merger.previewCache.byteCount, 3 * (frameBytes + 300 * 200 * 2), "plus one smaller size")
        _ = try await merger.preview(analysis, options: HDRMergeOptions(), longEdge: 600, showDeghostOverlay: false)
        XCTAssertEqual(merger.previewCache.byteCount, 3 * (frameBytes + 600 * 400 * 2), "which replaces the last")

        _ = try await merger.analyse(try HDRTestSupport.noisyBracket())
        XCTAssertEqual(merger.previewCache.byteCount, 3 * frameBytes, "another bracket lets the first go")

        merger.releasePreviews()
        XCTAssertEqual(merger.previewCache.byteCount, 0)
        _ = try await merger.preview(analysis, options: HDRMergeOptions(), longEdge: 1200, showDeghostOverlay: false)
        XCTAssertEqual(merger.previewCache.byteCount, 3 * frameBytes, "read again after release")

        // Real sensors are kept at most `previewCacheLongEdge` long.
        for (width, height) in [(5616, 3744), (6016, 4016), (3872, 2592), (8256, 5504), (9504, 6336), (12_000, 9_000)] {
            let factor = HDRMerger.previewFactor(width: width, height: height)
            let kept = HDRPreviewFrame.size(width: width, height: height, factor: factor)
            XCTAssertLessThanOrEqual(max(kept.width, kept.height), HDRMerger.previewCacheLongEdge, "\(width)")
            XCTAssertGreaterThan(max(kept.width, kept.height), HDRMerger.previewCacheLongEdge / 2, "\(width)")
            // Nine frames, the most a merge takes, and a quarter as much
            // again for the smaller size, stay under 160 MB.
            XCTAssertLessThan(9 * kept.width * kept.height * 2 * 5 / 4, 160_000_000, "\(width)")
        }
        XCTAssertEqual(HDRMerger.previewFactor(width: 5616, height: 3744), 2, "21 MP at half size")
    }

    /// A clipped photosite stays clipped when reduced; others are averaged.
    func testReducingKeepsClippingAndAveragesTheRest() throws {
        let (width, height) = (8, 4)
        // RGGB; every photosite 1000 except one red photosite at white.
        var samples = [UInt16](repeating: 1000, count: width * height)
        samples[2 * width + 2] = 15520
        samples[0] = 1004
        let summary = try XCTUnwrap(RawFile(path: try HDRTestSupport.cleanBracket()[0].path, metadataOnly: true).summary)
        let file = try XCTUnwrap(samples.withUnsafeBufferPointer {
            RawFile.bayerSource(width: width, height: height, like: summary, cameraToXYZ: nil, dataMaximum: 15520,
                                samples: $0)
        })
        let levels = HDRFrameLevels(channelBlack: SIMD4(repeating: 600), white: 15520, clipRaw: 0.98 * 15520)
        let reduced = try XCTUnwrap(HDRPreviewFrame.reduce(file, url: URL(fileURLWithPath: "/x.dng"),
                                                           levels: levels, factor: 2))
        XCTAssertEqual([reduced.file.summary.rawWidth, reduced.file.summary.rawHeight], [4, 2])
        let out = Array(try XCTUnwrap(reduced.file.sensorPlane).samples)
        // Red of the first quad: (1004 + 1000 + 15520 + 1000) is clipped, so white.
        XCTAssertEqual(out[0], 15520)
        // Its greens and blue: plain means.
        XCTAssertEqual(Array(out[1...1]) + [out[4], out[5]], [1000, 1000, 1000])
        // The second quad's red: (1000 x 4) / 4.
        XCTAssertEqual(out[2], 1000)
        XCTAssertEqual(reduced.file.summary.cfaPattern, summary.cfaPattern)
        XCTAssertEqual(reduced.file.summary.whiteLevel, summary.whiteLevel)
    }

    // MARK: - The overlay

    /// Deghosting a moving square, with the middle frame as the reference:
    /// the overlay outlines and tints where each square was, in the
    /// reference frame's colour (it shows there), and leaves the rest alone.
    func testTheOverlayMarksTheMovingSquare() async throws {
        let urls = try DeghostTests.movingSquareBracket()
        let merger = try merger()
        let analysis = try await merger.analyse(urls)
        let options = HDRMergeOptions(referenceIndex: 1, deghost: .medium)
        let plain = Pixels(try await merger.preview(analysis, options: options, longEdge: 600, showDeghostOverlay: false))
        let overlaid = Pixels(try await merger.preview(analysis, options: options, longEdge: 600,
                                                       showDeghostOverlay: true))
        XCTAssertEqual([overlaid.width, overlaid.height], [600, 400])

        // Preview pixels are half the scene's: the squares span x 105..<195
        // and y 150..<170, and deghosting widens and feathers that by about
        // 12 preview pixels (medium's 3 quarter-size pixels plus 2 of
        // feathering, on frames reduced twice).
        let band = (x: 80..<220, y: 125..<195)
        var inside = 0, outside = 0, white = 0, black = 0
        for y in 0..<400 {
            for x in 0..<600 where plain.rgb(x, y) != overlaid.rgb(x, y) {
                if band.x.contains(x), band.y.contains(y) { inside += 1 } else { outside += 1 }
                if overlaid.rgb(x, y) == SIMD3(255, 255, 255) { white += 1 }
                if overlaid.rgb(x, y) == SIMD3(0, 0, 0) { black += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 1500, "the squares are covered")
        XCTAssertEqual(outside, 0, "and nothing else")
        XCTAssertGreaterThan(white, 100, "outlined in white")
        XCTAssertGreaterThan(black, 100, "and black")

        // Each square's centre is tinted 40% towards the reference frame's colour.
        let tint = HDRDeghostOverlay.colour(forFrame: 1)
        let colour = SIMD3<Double>(Double(tint.red), Double(tint.green), Double(tint.blue))
        for column in DeghostTests.squareColumns {
            let (x, y) = ((column + DeghostTests.squareSize / 2) / 2, (DeghostTests.squareRow + DeghostTests.squareSize / 2) / 2)
            let base = SIMD3<Double>(plain.rgb(x, y))
            let want = base * 0.6 + colour * 0.4
            let got = SIMD3<Double>(overlaid.rgb(x, y))
            XCTAssertLessThan(simd_length(got - want), 3, "square at \(column): \(got) vs \(want)")
        }

        // Without a Deghost level there is nothing to draw.
        let none = HDRMergeOptions(referenceIndex: 1)
        let a = try await merger.preview(analysis, options: none, longEdge: 300, showDeghostOverlay: false)
        let b = try await merger.preview(analysis, options: none, longEdge: 300, showDeghostOverlay: true)
        XCTAssertEqual(Pixels(a).bytes, Pixels(b).bytes)
    }

    /// The palette isn't red alone: seven colours, told apart by more than hue.
    func testTheOverlayPalette() {
        XCTAssertEqual(HDRDeghostOverlay.palette.count, 7)
        XCTAssertEqual(HDRDeghostOverlay.paletteNames.count, 7)
        XCTAssertEqual(HDRDeghostOverlay.colourName(forFrame: 8), HDRDeghostOverlay.colourName(forFrame: 1))
        XCTAssertEqual(Set(HDRDeghostOverlay.palette.map { "\($0.red),\($0.green),\($0.blue)" }).count, 7)
    }

    // MARK: - Scaling to reduced frames

    /// A reduced plan moves a reduced point where the full plan moves the
    /// full point; feathering and deghosting shrink with the frames.
    func testReducedSettingsCoverTheSameScene() {
        let h = simd_double3x3(rows: [SIMD3(1.001, 0.002, 6.5), SIMD3(-0.001, 0.999, -3.25), SIMD3(1e-7, 0, 1)])
        let plan = HDRMergeAlignment.Plan(frames: [.aligned(shiftPixels: 7), .reference],
                                          homographies: [h, Homography.identity])
        let reduced = plan.reduced(by: 4)
        let point = SIMD2<Double>(1000, 600)
        let full = Homography.apply(h, point)
        let small = Homography.apply(reduced.homographies[0], point / 4)
        XCTAssertEqual(small.x, full.x / 4, accuracy: 1e-9)
        XCTAssertEqual(small.y, full.y / 4, accuracy: 1e-9)
        XCTAssertTrue(Homography.isIdentity(reduced.homographies[1]))

        XCTAssertEqual(HDRClipFeather.standard.reduced(by: 1), .standard)
        XCTAssertEqual(HDRClipFeather.standard.reduced(by: 3), HDRClipFeather(erodeRadius: 1, sigma: 0.5))
        // At half size, the calibrated counts: 65% of the share, rounded up.
        let medium = DeghostAmount.medium.settings!
        let medium2 = medium.reduced(by: 2)
        XCTAssertEqual([medium2.patchRadius, medium2.patchCount, medium2.dilateRadius], [2, 3, 2])
        XCTAssertEqual(medium2.featherSigma, 1)
        XCTAssertEqual(medium2.gapStops, medium.gapStops)
        let low2 = DeghostAmount.low.settings!.reduced(by: 2)
        XCTAssertEqual([low2.patchRadius, low2.patchCount, low2.dilateRadius], [2, 5, 1])
        let high2 = DeghostAmount.high.settings!.reduced(by: 2)
        XCTAssertEqual([high2.patchRadius, high2.patchCount, high2.dilateRadius], [2, 2, 2])
        let medium4 = medium.reduced(by: 4)
        XCTAssertEqual([medium4.patchRadius, medium4.patchCount], [1, 1])
        XCTAssertEqual(medium.reduced(by: 1), medium)
    }

    // MARK: - Warnings for a picked reference

    /// Which frames can't be lined up depends on the reference: beyond a
    /// rejected link from it. The analysis says so for any reference.
    func testWarningsFollowThePickedReference() {
        func link(accepted: Bool, shift: Double) -> AlignmentResult {
            let h = simd_double3x3(rows: [SIMD3(1, 0, shift), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
            return AlignmentResult(homography: accepted ? h : Homography.identity, estimatedHomography: h,
                                   maxCornerShift: shift, ncc: accepted ? 0.99 : 0.5, overlapFraction: 1,
                                   scaleChange: 0, converged: true, accepted: accepted,
                                   rejection: accepted ? nil : .lowCorrelation(ncc: 0.5))
        }
        // Frame 0 -> 1 lined up (3 px); 1 -> 2 rejected, and 5 px apart.
        let alignment = HDRMergeAlignment(links: [link(accepted: true, shift: 3), link(accepted: false, shift: 5)],
                                          chainOrder: [0, 1, 2], neighbourShiftPixels: [nil, 5],
                                          width: 1200, height: 800)
        let frames = (0..<3).map { i in
            HDRMergeFrame(url: URL(fileURLWithPath: "/\(i).NEF"), exposureSeconds: 1, iso: 100, aperture: 8,
                          relativeEV: Double(-2 * i), exifRelativeEV: Double(-2 * i), clippedFraction: 0)
        }
        let analysis = HDRMergeAnalysis(frames: frames, referenceIndex: 1, width: 1200, height: 800,
                                        exposureRangeStops: 4,
                                        warnings: [.smallExposureRange(stops: 0.5),
                                                   .frameCouldNotBeAligned(frameIndex: 2, leftOut: true)],
                                        estimatedOutputBytes: 1, alignment: alignment)
        XCTAssertEqual(analysis.warnings(reference: 1), analysis.warnings, "the analysis's own reference")
        XCTAssertEqual(analysis.warnings(reference: 0), [.smallExposureRange(stops: 0.5),
                                                         .frameCouldNotBeAligned(frameIndex: 2, leftOut: true)])
        // From frame 2 both others are beyond the rejected link; leaving both
        // out would leave one frame, so they merge unaligned.
        XCTAssertEqual(analysis.warnings(reference: 2), [.smallExposureRange(stops: 0.5),
                                                         .frameCouldNotBeAligned(frameIndex: 0, leftOut: false),
                                                         .frameCouldNotBeAligned(frameIndex: 1, leftOut: false)])
        XCTAssertEqual(analysis.alignmentShifts(reference: 0)[0], 0)
        XCTAssertEqual(analysis.alignmentShifts(reference: 0)[1] ?? 0, 3, accuracy: 0.01)
        XCTAssertNil(analysis.alignmentShifts(reference: 0)[2])
    }

    // MARK: - Auto Settings

    /// Auto Settings is Auto Adjust of the merged DNG opened with no edit:
    /// the stored stack holds exactly its exposure, contrast and white
    /// balance, and nothing else changes.
    func testAutoSettingsIsAutoAdjustOfTheResult() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let (_, result, _, folder) = try await HDRTestSupport.merge(urls, merger: try merger(keepsPreviewFrames: false))
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpu = try HDRTestSupport.gpu()
        let edit = try HDRAutoSettings.edit(forPhotoAt: result.url, gpu: gpu)

        let session = try ImageSession(file: try RawFile(path: result.url.path), gpu: gpu)
        var defaults = EditParameters()
        defaults.whiteBalance = session.asShotWhiteBalance
        let suggestion = try AutoAdjust.suggest(for: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu,
                                                current: defaults)
        XCTAssertEqual(edit.suggestion, suggestion)
        let json = try XCTUnwrap(edit.editStackJSON, "the synthetic scene needs an adjustment")
        let stored = try EditStack.decode(json: json).parameters(defaults: defaults)
        XCTAssertEqual(stored.exposureEV, suggestion.exposureEV)
        XCTAssertEqual(stored.contrast, suggestion.contrast)
        if let whiteBalance = suggestion.whiteBalance { XCTAssertEqual(stored.whiteBalance, whiteBalance) }
        var rest = stored
        rest.exposureEV = defaults.exposureEV
        rest.contrast = defaults.contrast
        rest.whiteBalance = defaults.whiteBalance
        XCTAssertTrue(EditStack.isDefault(rest, relativeTo: defaults), "nothing else is set")
    }
}
