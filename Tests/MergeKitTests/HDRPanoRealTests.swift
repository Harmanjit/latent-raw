import Foundation
import PixelEngine
import RawCore
import XCTest
@testable import MergeKit

/// An HDR panorama made from real photons.
///
/// **Nobody has shot a real HDR panorama for Latent** — none is freely
/// licensed and Harman hasn't taken one — so this makes the closest thing
/// there is: overlapping windows cut out of the real Ihrke tripod bracket
/// (6 Canon CR2s of one high-contrast scene). Every window is cut from all
/// six exposures, so each window is a genuine bracket of real sensor data,
/// with real noise, real clipping and real black levels; the windows
/// overlap, so together they are a sweep.
///
/// **What this can and can't check.** The photons, the bracket exposures
/// and the merging are real. The geometry is not: windows of one frame are
/// related by a translation, which is a rotation about the camera's centre
/// only in the limit of a long lens, so the files claim a long lens (see
/// `focalMillimetres`) and the residual is under a pixel. So this shows
/// that grouping, six-frame per-position merges and the stitch hold up on
/// real data and produce one coherent image; it does **not** show that
/// Latent handles the parallax, the changing light and the hand-held
/// rotation of a real HDR panorama. Only a real set can, and
/// docs/wiki/Photo-Merge.md says so.
///
/// Skipped when TestAssets/merge is missing (as it is on CI).
final class HDRPanoRealTests: XCTestCase {
    /// The window cut from each frame, and how far apart the windows are.
    /// 1600 x 1000 tiles as 4 x 2, which LibRaw reads back correctly (see
    /// `HDRPanoTestSupport`), and 900 px apart leaves 44% overlap.
    static let windowWidth = 1600
    static let windowHeight = 1000
    static let windowStep = 900
    static let positions = 3
    /// Where the first window starts on the sensor (even, so the Bayer quad
    /// keeps its phase).
    static let windowOrigin = (x: 1000, y: 1200)

    /// The lens the windows claim. Cutting a window out of a photo shifts
    /// the image plane; a panorama turns the camera. The two agree to
    /// within about `step x (width / 2)² / f²` pixels, so a long lens makes
    /// the difference vanish: at f = 24,000 px the windows are 2.1° apart
    /// and the residual is under a pixel.
    static let focalPixels = 24_000.0
    static var focalMillimetres: Double {
        let diagonal = (Double(windowWidth * windowWidth + windowHeight * windowHeight)).squareRoot()
        return focalPixels * PanoramaFrameMetadata.fullFrameDiagonalMillimetres / diagonal
    }

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try Fixtures.temporaryFolder()
        _ = PanoramaFrameStore.removeScratchOfThisProcess()
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try super.tearDownWithError()
    }

    func testWindowsCutFromTheIhrkeBracketMergeIntoOneCoherentImage() async throws {
        let sources = try ihrkeFrames()
        let written = try writeWindows(from: sources)
        XCTAssertEqual(written.count, Self.positions * sources.count)

        let gpu = try HDRTestSupport.gpu()
        let merger = HDRPanoramaMerger(hdr: HDRMerger(gpu: gpu, memoryPolicy: MemoryPolicy(physicalMemory: 16 << 30)),
                                       panorama: PanoramaMerger(gpu: gpu), scratchRoot: folder,
                                       availableCapacity: { _ in nil })
        let options = HDRPanoramaOptions()
        let analysisStarted = Date()
        let analysis = try await merger.analyse(written, options: options)
        let analysisSeconds = Date().timeIntervalSince(analysisStarted)

        // Grouped into one position per window, each holding every exposure.
        XCTAssertEqual(analysis.grouping.positions.count, Self.positions)
        XCTAssertEqual(analysis.grouping.positions.map(\.frames.count),
                       Array(repeating: sources.count, count: Self.positions))
        XCTAssertFalse(analysis.grouping.isUneven)
        XCTAssertFalse(analysis.panorama.frames.contains(where: \.leftOut), "every window should be placed")

        let destination = folder.appendingPathComponent("ihrke-HDRPano.dng")
        let sidecar = HDRPanoMergeTests.RecipeBox()
        let peak = HDRPanoMergeTests.PeakMemory(device: gpu.device)
        let mergeStarted = Date()
        _ = try await merger.merge(analysis, options: options,
                                   sources: HDRPanoTestSupport.sources(analysis.photos.map(\.url)),
                                   to: destination, prepareSidecar: { sidecar.store($0) },
                                   progress: { _ in peak.sample() })
        let mergeSeconds = Date().timeIntervalSince(mergeStarted)

        let recipe = try XCTUnwrap(sidecar.recipe)
        XCTAssertEqual(recipe.kind, .hdrPanorama)
        XCTAssertEqual(recipe.sources.count, Self.positions * sources.count)
        // A single frame clips at 1.0; an HDR panorama of a 6-stop bracket
        // holds far more than that, and records where it really clips.
        XCTAssertGreaterThan(recipe.clipLevel, 2, "the result should hold highlights one frame can't")

        let merged = try PanoMergeTestSupport.read(destination)
        let expectedWidth = Self.windowWidth + (Self.positions - 1) * Self.windowStep
        XCTAssertEqual(Double(merged.width), Double(expectedWidth), accuracy: 0.06 * Double(expectedWidth),
                       "the stitch should cover the windows and little else")

        // One coherent image: inside the Auto Crop rectangle nothing is
        // uncovered, and no column stands out as a seam. A seam shows as a
        // spike in how much neighbouring columns differ; a real edge in the
        // scene is spread over many columns, so the spike is what is looked
        // for.
        let crop = cropRect(analysis.panorama, merged: merged)
        var uncovered = 0
        for y in stride(from: Int(crop.minY), to: Int(crop.maxY), by: 3) {
            for x in stride(from: Int(crop.minX), to: Int(crop.maxX), by: 3)
            where merged.isUncovered(x, y) { uncovered += 1 }
        }
        XCTAssertEqual(uncovered, 0, "the Auto Crop rectangle must hold only real pixels")

        var columnDifference: [Double] = []
        for x in stride(from: Int(crop.minX), to: Int(crop.maxX) - 1, by: 1) {
            var total = 0.0, samples = 0
            for y in stride(from: Int(crop.minY) + 4, to: Int(crop.maxY) - 4, by: 3) {
                let here = merged.pixel(x, y), next = merged.pixel(x + 1, y)
                let scale = max(1e-6, (here.x + here.y + here.z + next.x + next.y + next.z) / 6)
                total += abs((next.x + next.y + next.z - here.x - here.y - here.z) / 3) / scale
                samples += 1
            }
            if samples > 0 { columnDifference.append(total / Double(samples)) }
        }
        let sorted = columnDifference.sorted()
        let median = sorted[sorted.count / 2], worst = sorted[sorted.count - 1]
        print("hdrpano-real | \(merged.width) x \(merged.height) px from \(Self.positions) windows x "
              + "\(sources.count) exposures | clip \(String(format: "%.1f", recipe.clipLevel)) | "
              + "column step median \(String(format: "%.4f", median)), worst \(String(format: "%.4f", worst)) "
              + "(x\(String(format: "%.1f", worst / max(median, 1e-9)))) | "
              + "analyse \(String(format: "%.1f s", analysisSeconds)), "
              + "merge \(String(format: "%.1f s", mergeSeconds)), "
              + "peak GPU \(String(format: "%.0f MB", Double(peak.bytes) / 1e6))")
        XCTAssertGreaterThan(median, 0, "a real scene has detail")
        XCTAssertLessThan(worst / median, 12, "a seam would stand out as one column unlike its neighbours")

        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(), 0, "the stitch left scratch files behind")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("Latent-HDRPano-") }
        XCTAssertEqual(left, [], "the intermediate HDRs must be removed")
    }

    // MARK: - Cutting the windows

    /// The Ihrke bracket's frames, in the order the folder holds them.
    private func ihrkeFrames() throws -> [URL] {
        let directory = TestAssets.url("merge").appendingPathComponent("ihrke-tripod-bracket")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("TestAssets/merge/ihrke-tripod-bracket is missing")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "cr2" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.count >= 3 else { throw XCTSkip("the Ihrke bracket has too few frames") }
        return urls
    }

    /// Cuts `positions` overlapping windows out of every frame and writes
    /// each as a CFA DNG, timed like a bracketed sweep: the exposures of
    /// one window a second apart, the windows 30 seconds apart.
    ///
    /// The photosites are rescaled from the camera's black and white levels
    /// into the test camera's, so the files can claim the camera the test
    /// writer knows (the scene and its range are unchanged; only the units
    /// are). Returns the files in capture order.
    private func writeWindows(from sources: [URL]) throws -> [URL] {
        var windows: [[URL]] = Array(repeating: [], count: Self.positions)
        for (exposureIndex, source) in sources.enumerated() {
            try autoreleasepool {
                let file = try RawFile(path: source.path)
                let summary = file.summary
                guard case .bayer(let order) = summary.cfaPattern else {
                    throw XCTSkip("\(source.lastPathComponent) isn't a Bayer raw")
                }
                // The window is written as RGGB, so it starts on the
                // sensor's red photosite whatever order the camera uses
                // (the Ihrke Canon is GBRG).
                guard let phase = Self.rggbOffset(order: order) else {
                    throw XCTSkip("\(source.lastPathComponent) has an unusual CFA order (\(order))")
                }
                let plane = try XCTUnwrap(file.sensorPlane)
                let planeWidth = summary.rawWidth, planeHeight = summary.rawHeight
                let black = summary.channelBlackLevels
                let range = max(1, summary.whiteLevel - max(black.x, max(black.y, black.z)))
                let scale = Double(SyntheticBracket.white - SyntheticBracket.black.r) / Double(range)
                for position in 0..<Self.positions {
                    let originX = Self.windowOrigin.x + position * Self.windowStep + phase.dx
                    let originY = Self.windowOrigin.y + phase.dy
                    guard originX + Self.windowWidth <= planeWidth,
                          originY + Self.windowHeight <= planeHeight else {
                        throw XCTSkip("the Ihrke frames are smaller than the windows this test cuts")
                    }
                    var raw = [UInt16](repeating: 0, count: Self.windowWidth * Self.windowHeight)
                    let samples = plane.samples
                    let blacks = [Double(black.x), Double(black.y), Double(black.z)]
                    let whites = [Double(SyntheticBracket.black.r), Double(SyntheticBracket.black.g),
                                  Double(SyntheticBracket.black.b)]
                    for y in 0..<Self.windowHeight {
                        let sourceRow = (originY + y) * planeWidth + originX
                        let targetRow = y * Self.windowWidth
                        for x in 0..<Self.windowWidth {
                            // The window starts on an even row and column,
                            // so a pixel's colour in the window is its
                            // colour on the sensor.
                            let colour = (y & 1 == 0) ? (x & 1 == 0 ? 0 : 1) : (x & 1 == 0 ? 1 : 2)
                            let value = (Double(samples[sourceRow + x]) - blacks[colour]) * scale + whites[colour]
                            raw[targetRow + x] = UInt16(min(max(value.rounded(), 0),
                                                            Double(SyntheticBracket.white)))
                        }
                    }
                    let name = String(format: "W%02d-E%02d.dng", position, exposureIndex)
                    let url = folder.appendingPathComponent(name)
                    try Self.writeWindowDNG(raw, shutter: summary.shutter, iso: summary.iso,
                                            aperture: summary.aperture,
                                            captureTime: Date(timeIntervalSince1970: 1_789_498_800
                                                + Double(position) * 30 + Double(exposureIndex)),
                                            to: url)
                    windows[position].append(url)
                }
            }
        }
        return windows.flatMap { $0 }
    }

    /// Where a window must start on a sensor of this CFA order for its own
    /// top-left photosite to be red, so it can be written as RGGB: nil for
    /// an order that has no such corner.
    ///
    /// The order packs one colour (0 red, 1 green, 2 blue, 3 the second
    /// green) per photosite of the quad, in the order (0,0), (1,0), (0,1),
    /// (1,1) — LibRaw's `filters` byte.
    static func rggbOffset(order: UInt8) -> (dx: Int, dy: Int)? {
        func colour(_ x: Int, _ y: Int) -> Int {
            let index = (y & 1) * 2 + (x & 1)
            let value = Int((order >> (2 * index)) & 3)
            return value == 3 ? 1 : value                     // the second green is green
        }
        for dy in 0...1 {
            for dx in 0...1 where colour(dx, dy) == 0 && colour(dx + 1, dy) == 1
                && colour(dx, dy + 1) == 1 && colour(dx + 1, dy + 1) == 2 {
                return (dx, dy)
            }
        }
        return nil
    }

    /// A CFA DNG of one window, claiming the test camera and the long lens
    /// the note on `focalPixels` explains, with the real frame's exposure.
    static func writeWindowDNG(_ raw: [UInt16], shutter: Double, iso: Double, aperture: Double,
                               captureTime: Date, to url: URL) throws {
        var ifd0 = TIFFDirectory()
        ifd0.set(TIFFTag.newSubfileType, long: 0)
        ifd0.set(TIFFTag.imageWidth, long: UInt32(windowWidth))
        ifd0.set(TIFFTag.imageLength, long: UInt32(windowHeight))
        ifd0.set(TIFFTag.bitsPerSample, short: 16)
        ifd0.set(TIFFTag.compression, short: 1)
        ifd0.set(TIFFTag.photometricInterpretation, short: 32803)
        ifd0.set(TIFFTag.make, ascii: SyntheticBracket.make)
        ifd0.set(TIFFTag.model, ascii: SyntheticBracket.model)
        ifd0.set(TIFFTag.orientation, short: 1)
        ifd0.set(TIFFTag.samplesPerPixel, short: 1)
        ifd0.set(TIFFTag.rowsPerStrip, long: UInt32(windowHeight))
        ifd0.set(TIFFTag.stripOffsets, .imageChunkOffsets)
        ifd0.set(TIFFTag.stripByteCounts, .imageChunkByteCounts)
        ifd0.set(TIFFTag.planarConfiguration, short: 1)
        ifd0.set(TIFFTag.software, ascii: "Latent tests")
        ifd0.set(SyntheticBracket.CFATag.repeatPatternDim, .shorts([2, 2]))
        ifd0.set(SyntheticBracket.CFATag.pattern, .bytes([0, 1, 1, 2]))
        ifd0.set(TIFFTag.dngVersion, .bytes([1, 4, 0, 0]))
        ifd0.set(TIFFTag.dngBackwardVersion, .bytes([1, 1, 0, 0]))
        ifd0.set(TIFFTag.uniqueCameraModel, ascii: "\(SyntheticBracket.make) \(SyntheticBracket.model)")
        ifd0.set(SyntheticBracket.CFATag.planeColor, .bytes([0, 1, 2]))
        ifd0.set(SyntheticBracket.CFATag.layout, short: 1)
        ifd0.set(SyntheticBracket.CFATag.blackLevelRepeatDim, .shorts([2, 2]))
        ifd0.set(TIFFTag.blackLevel, .shorts([SyntheticBracket.black.r, SyntheticBracket.black.g,
                                              SyntheticBracket.black.g, SyntheticBracket.black.b]))
        ifd0.set(TIFFTag.whiteLevel, .shorts([SyntheticBracket.white]))
        ifd0.set(TIFFTag.colorMatrix1, .srationals(try MergeDNGMetadata.colorMatrix(fromCamXYZ: Fixtures.d750CamXYZ)
            .map { TIFFSRational($0, denominator: 10_000)! }))
        ifd0.set(TIFFTag.asShotNeutral,
                 .rationals(try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: Fixtures.d750Multipliers)
                     .map { TIFFRational($0, denominator: 1_000_000)! }))
        ifd0.set(TIFFTag.calibrationIlluminant1, short: 21)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = Fixtures.utc
        var exif = TIFFDirectory()
        exif.set(TIFFTag.exifVersion, .undefined(Array("0231".utf8)))
        exif.set(TIFFTag.exposureTime, .rationals([DNGTagValues.exposureTimeRational(max(shutter, 1e-5))!]))
        exif.set(TIFFTag.fNumber, .rationals([TIFFRational(max(aperture, 1), denominator: 100)!]))
        exif.set(TIFFTag.isoSpeedRatings, short: UInt16(max(50, min(iso, 25_600))))
        exif.set(TIFFTag.focalLength, .rationals([TIFFRational(focalMillimetres, denominator: 100)!]))
        exif.set(TIFFTag.dateTimeOriginal, ascii: formatter.string(from: captureTime))
        ifd0.set(TIFFTag.exifIFD, .directories([exif]))

        let bytes = raw.withUnsafeBytes { Array($0) }
        ifd0.imageData = LinearRawDNGWriter.singleChunk(bytes)
        var layout = try TIFFLayout(topLevel: [ifd0])
        try? FileManager.default.removeItem(at: url)
        _ = try LinearRawDNGWriter.write(&layout, toNewFileAt: url)
    }

    /// The rectangle of the output every pixel of which came from a photo.
    private func cropRect(_ analysis: PanoramaMergeAnalysis, merged: PanoMergeTestSupport.Merged) -> CGRect {
        let scale = analysis.outputSize.scale
        let crop = analysis.layout.autoCropRect
        return CGRect(x: (crop.minX * scale).rounded(.up), y: (crop.minY * scale).rounded(.up),
                      width: (crop.width * scale).rounded(.down), height: (crop.height * scale).rounded(.down))
            .intersection(CGRect(x: 0, y: 0, width: merged.width, height: merged.height))
    }
}
