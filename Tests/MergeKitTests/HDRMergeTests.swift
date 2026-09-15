import XCTest
import CoreGraphics
import ImageIO
import PixelEngine
import RawCore
@testable import MergeKit

/// The merged pixels against the scene they were made from, and the DNG
/// they're saved in.
final class HDRMergeTests: XCTestCase {
    /// Noiseless frames at 4, 1 and 1/4: wherever any frame recorded the
    /// scene unclipped, the merge must give its radiance within 1%.
    func testMergedRadianceMatchesTheScene() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let (analysis, result, _, folder) = try await HDRTestSupport.merge(urls)
        defer { try? FileManager.default.removeItem(at: folder) }
        let merged = try HDRTestSupport.readBack(result.url)
        let scene = HDRTestSupport.scene
        XCTAssertEqual([merged.width, merged.height], [scene.width, scene.height])
        for (frame, want) in zip(analysis.frames, [0.0, -2, -4]) {
            XCTAssertEqual(frame.relativeEV, want, accuracy: 0.005)
        }

        let smooth = Self.smoothPixels(scene, radius: 6, step: 3)
        var tested = 0, worst = 0.0, failures = 0
        for (x, y) in smooth {
            let radiance = scene.radiance(x: x, y: y)
            // Unclipped in the darkest frame (so in some frame), by a margin.
            let darkestRaw = Double(radiance.max()) * 0.25 * SyntheticBracket.countsPerUnit + 640
            guard darkestRaw < 0.95 * Double(SyntheticBracket.white) else { continue }
            let want = SyntheticBracket.mergeUnits(radiance, brightest: 4)
            // At least 200 counts in the brightest frame, so quantisation
            // (half a count) stays well under the tolerance.
            guard want.min() >= 200 / Double(SyntheticBracket.white - 600) else { continue }
            let got = SIMD3<Double>(merged.pixel(x, y))
            let error = Self.relativeError(got, want)
            tested += 1
            worst = max(worst, error)
            if error > 0.01 { failures += 1 }
        }
        XCTAssertGreaterThan(tested, 40_000)
        XCTAssertEqual(failures, 0, "pixels more than 1% off (worst \(worst))")
    }

    func testNoNaNInfinityOrNegativeValues() async throws {
        let (_, result, _, folder) = try await HDRTestSupport.merge(try HDRTestSupport.noisyBracket())
        defer { try? FileManager.default.removeItem(at: folder) }
        let merged = try HDRTestSupport.readBack(result.url)
        XCTAssertFalse(merged.rgb.contains { !$0.isFinite || $0 < 0 })
    }

    /// The disc is clipped in every frame: it must come from the darkest
    /// frame, whose clipped photosites read white.
    func testDiscClippedEverywhereEqualsTheDarkestFrame() async throws {
        let (analysis, result, _, folder) = try await HDRTestSupport.merge(try HDRTestSupport.cleanBracket())
        defer { try? FileManager.default.removeItem(at: folder) }
        let merged = try HDRTestSupport.readBack(result.url)
        let scale = pow(2, -(analysis.frames.last?.relativeEV ?? 0))
        let range = Double(SyntheticBracket.white - 600)
        let want = SIMD3<Double>(Double(SyntheticBracket.white - 600), Double(SyntheticBracket.white - 600),
                                 Double(SyntheticBracket.white - 640)) / range * scale
        let disc = SyntheticBracket.Layout.disc
        var checked = 0
        for y in (disc.y - 60)...(disc.y + 60) {
            for x in (disc.x - 60)...(disc.x + 60) where (x - disc.x) * (x - disc.x) + (y - disc.y) * (y - disc.y) <= 3600 {
                let got = SIMD3<Double>(merged.pixel(x, y))
                XCTAssertLessThan(Self.relativeError(got, want), 0.002, "(\(x), \(y)): \(got) vs \(want)")
                checked += 1
                if Self.relativeError(got, want) >= 0.002 { return }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// Across the 11.5-stop ramp the merge hands over from frame to frame
    /// twice; neither handover may show as a step.
    func testRampHasNoSteps() async throws {
        for (label, urls, tolerance, step) in [("clean", try HDRTestSupport.cleanBracket(), 0.01, 0.003),
                                               ("noisy", try HDRTestSupport.noisyBracket(), 0.02, 0.01)] {
            let (_, result, _, folder) = try await HDRTestSupport.merge(urls)
            defer { try? FileManager.default.removeItem(at: folder) }
            let merged = try HDRTestSupport.readBack(result.url)
            // Each 8-column block's mean green over 200 rows, in stops from the truth.
            let block = 8
            var means: [Double] = [], errors: [Double] = []
            for x0 in stride(from: 16, to: merged.width - 16 - block, by: block) {
                var got = 0.0, want = 0.0
                for x in x0..<(x0 + block) {
                    want += SyntheticBracket.mergeUnits(HDRTestSupport.scene.radiance(x: x, y: 100), brightest: 4).y * 200
                    for y in 20..<220 { got += Double(merged.pixel(x, y).y) }
                }
                means.append(got)
                // Only where the brightest frame has at least 200 counts.
                errors.append(want / Double(block * 200) * Double(SyntheticBracket.white - 600) >= 200
                              ? log2(got / want) : .nan)
            }
            for i in 1..<means.count {
                XCTAssertGreaterThan(means[i], means[i - 1], "\(label): not increasing at block \(i)")
            }
            let valid = errors.enumerated().filter { !$0.element.isNaN }
            XCTAssertGreaterThan(valid.count, 100)
            for (i, error) in valid {
                XCTAssertLessThan(abs(error), tolerance, "\(label): block \(i) is \(error) stops off")
                if i > 0, !errors[i - 1].isNaN {
                    XCTAssertLessThan(abs(error - errors[i - 1]), step, "\(label): a step at block \(i)")
                }
            }
        }
    }

    /// Blue's black level is 40 counts above red's and green's: the neutral
    /// shadows must stay neutral.
    func testUnequalBlackLevelsLeaveShadowsNeutral() async throws {
        let (_, result, _, folder) = try await HDRTestSupport.merge(try HDRTestSupport.noisyBracket())
        defer { try? FileManager.default.removeItem(at: folder) }
        let merged = try HDRTestSupport.readBack(result.url)
        for x0 in stride(from: 40, to: 760, by: 120) {
            var sum = SIMD3<Double>()
            for y in 610..<790 { for x in x0..<(x0 + 120) { sum += SIMD3<Double>(merged.pixel(x, y)) } }
            XCTAssertEqual(sum.x / sum.y, 1, accuracy: 0.02, "red cast at x \(x0)")
            XCTAssertEqual(sum.z / sum.y, 1, accuracy: 0.02, "blue cast at x \(x0)")
        }
    }

    /// The DNG opens through LibRaw as a linear source carrying its merge
    /// info, opening at the reference frame's exposure.
    func testResultReopensAsALinearHDRMerge() async throws {
        let urls = try HDRTestSupport.cleanBracket()
        let merger = try HDRTestSupport.merger()
        for override in [nil, 0] as [Int?] {
            let (analysis, result, _, folder) = try await HDRTestSupport.merge(
                urls, merger: merger, options: HDRMergeOptions(referenceIndex: override))
            defer { try? FileManager.default.removeItem(at: folder) }
            let reference = override ?? analysis.referenceIndex
            let file = try RawFile(path: result.url.path)
            XCTAssertEqual(file.summary.sourceKind, .linearRGB)
            let info = try XCTUnwrap(file.summary.mergeInfo)
            XCTAssertEqual(info.kind, "hdr")
            XCTAssertFalse(info.lensApplied)
            XCTAssertEqual(info.baselineShift, result.normalisation.shift)
            let shift = Double(result.normalisation.shift)
            let expectedBaseline = analysis.frames[reference].relativeEV + shift
            XCTAssertEqual(Double(file.summary.baselineExposure), expectedBaseline, accuracy: 1e-5)
            XCTAssertEqual(result.baselineExposure, expectedBaseline, accuracy: 1e-9)
            XCTAssertEqual(result.recipe.reference, reference)
            XCTAssertEqual(result.recipe.kind, .hdr)
            XCTAssertEqual(result.recipe.sources, HDRTestSupport.sources(analysis.frames.map(\.url)))
            XCTAssertEqual(result.recipe.options, override.map { ["referenceIndex": .number(Double($0))] } ?? [:])
            // Clipped in every frame at 98% of the darkest frame's white, on
            // the brightest frame's scale, then divided as the pixels were.
            XCTAssertEqual(Double(info.clipLevel), 0.98 * pow(2, analysis.exposureRangeStops - shift), accuracy: 1e-3)
            XCTAssertEqual(file.summary.cameraModel, SyntheticBracket.model)
            XCTAssertEqual(file.summary.orientation, 0)
        }
    }

    /// The DNG's preview is the merge as Latent renders the DNG itself.
    func testPreviewMatchesLatentsRenderOfTheDNG() async throws {
        let (_, result, _, folder) = try await HDRTestSupport.merge(try HDRTestSupport.cleanBracket())
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = try XCTUnwrap(try Self.largestJPEGPreview(in: result.url))
        XCTAssertEqual([jpeg.width, jpeg.height], [1200, 800])

        let gpu = try HDRTestSupport.gpu()
        let file = try RawFile(path: result.url.path)
        let session = try ImageSession(file: file, gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        let texture = try RenderPipeline(gpu: gpu).render(session, scale: .full, parameters: parameters)
        let rendered = try Exporter(gpu: gpu).cgImage(from: texture, colorSpace: .sRGB)
        let a = try Self.rgbBytes(jpeg), b = try Self.rgbBytes(rendered, width: jpeg.width, height: jpeg.height)
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        let meanDifference = Double(total) / Double(a.count)
        XCTAssertLessThan(meanDifference, 3, "mean difference in 8-bit levels")
    }

    // MARK: - Helpers

    /// The largest of the three channels' |got - want| / want.
    static func relativeError(_ got: SIMD3<Double>, _ want: SIMD3<Double>) -> Double {
        let e = (got - want) / want
        return max(abs(e.x), abs(e.y), abs(e.z))
    }

    /// Pixels on a `step` grid whose `radius` neighbourhood holds no edge:
    /// no neighbour's green radiance more than 0.2 stops from the centre's.
    /// Demosaicing, and the widened clip mask, only disturb pixels near edges.
    static func smoothPixels(_ scene: SyntheticBracket.Scene, radius: Int, step: Int) -> [(Int, Int)] {
        let w = scene.width, h = scene.height
        var logGreen = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { logGreen[i] = log2(max(scene.rgb[i * 3 + 1], 1e-9)) }
        let logs = logGreen
        let rows = Array(stride(from: radius, to: h - radius, by: step))
        var found = [[(Int, Int)]](repeating: [], count: rows.count)
        found.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: rows.count) { r in
                let y = rows[r]
                var list: [(Int, Int)] = []
                for x in stride(from: radius, to: w - radius, by: step) {
                    let centre = logs[y * w + x]
                    var smooth = true
                    outer: for dy in -radius...radius {
                        for dx in -radius...radius where abs(logs[(y + dy) * w + x + dx] - centre) > 0.2 {
                            smooth = false
                            break outer
                        }
                    }
                    if smooth { list.append((x, y)) }
                }
                out[r] = list
            }
        }
        return found.flatMap { $0 }
    }

    /// The JPEG preview the writer puts in SubIFD 1, decoded.
    static func largestJPEGPreview(in url: URL) throws -> CGImage? {
        let reader = try TestTIFFReader(url: url)
        let ifd0 = try reader.directory(at: reader.firstDirectoryOffset())
        let subIFDs = try reader.integers(XCTUnwrap(ifd0[330]))
        guard subIFDs.count == 2 else { return nil }
        let preview = try reader.directory(at: subIFDs[1])
        let offset = try reader.integers(XCTUnwrap(preview[273]))[0]
        let count = try reader.integers(XCTUnwrap(preview[279]))[0]
        let data = Data(reader.bytes[offset..<(offset + count)])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 8-bit RGB of `image`, drawn at `width x height` when given.
    static func rgbBytes(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> [UInt8] {
        let w = width ?? image.width, h = height ?? image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { rgb[i * 3 + c] = data[i * 4 + c] } }
        return rgb
    }
}
