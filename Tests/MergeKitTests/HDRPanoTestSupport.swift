import Foundation
import RawCore
import XCTest
import simd
@testable import MergeKit

/// Synthetic **bracketed sweeps**: the panorama tests' scene painted on the
/// sphere, photographed at several exposures from each of several positions
/// and written as CFA DNGs, so the whole HDR panorama — grouping, the
/// per-position HDR merges, the stitch and the DNG — can be checked against
/// the truth with no private test files.
///
/// The scene, the camera's levels and the projection maths are
/// `PanoMergeTestSupport`'s; only the frame's size and its own DNG writer
/// are here.
enum HDRPanoTestSupport {
    /// The photos' size and lens: 1100 x 500 px at 700 px focal length is
    /// 76° x 39°, so 0.4 rad steps overlap by about half.
    static let width = 1100
    static let height = 500
    static let focalPixels = PanoMergeTestSupport.focalPixels

    /// What EXIF says, so the solver starts from the truth.
    static var focalMillimetres: Double {
        let diagonal = (Double(width * width + height * height)).squareRoot()
        return focalPixels * PanoramaFrameMetadata.fullFrameDiagonalMillimetres / diagonal
    }

    /// Edges about two pixels wide, so binning and warping don't alias.
    static var edge: Double { 2 / focalPixels }

    /// The exposures of one bracket: 4, 1 and 1/4, two stops apart, as the
    /// HDR tests use. At exposure 4 the bright half of the scene clips, so
    /// the merge has real work to do.
    static let exposures: [Double] = [4, 1, 0.25]

    /// One photo of a sweep.
    struct Frame {
        var shot: PanoMergeTestSupport.Shot
        var captureTime: Date
        var name: String
    }

    /// A bracketed sweep: `positions` positions `step` radians apart, each
    /// shot at every exposure of `exposures`.
    ///
    /// The timing is a camera's: the frames of a bracket one second apart,
    /// then `between` seconds to turn to the next position — which is what
    /// the grouper reads when the exposures alone can't tell.
    static func sweep(positions: Int, exposures: [Double] = HDRPanoTestSupport.exposures,
                      step: Double = 0.4, between: Double = 6) -> [Frame] {
        var frames: [Frame] = []
        var time = 0.0
        for position in 0..<positions {
            let yaw = (Double(position) - Double(positions - 1) / 2) * step
            for (index, exposure) in exposures.enumerated() {
                frames.append(Frame(shot: PanoMergeTestSupport.Shot(yaw: yaw, exposure: exposure),
                                    captureTime: Date(timeIntervalSince1970: 1_789_498_800 + time),
                                    name: String(format: "P%02d-%d.dng", position, index)))
                time += 1
            }
            time += between - 1
        }
        return frames
    }

    /// The sweep written once per test run and kept under `name`: painting
    /// photosites is slow in a debug build and several tests want the same
    /// photos.
    static func cached(_ name: String, _ frames: [Frame]) throws -> [URL] {
        try lock.withLock {
            if let made = cachedSweeps[name] { return made }
            let folder = cacheFolder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = try write(frames, to: folder)
            cachedSweeps[name] = urls
            return urls
        }
    }

    static func removeCachedPhotos() {
        lock.withLock {
            cachedSweeps = [:]
            try? FileManager.default.removeItem(at: cacheFolder)
        }
    }

    /// Writes one CFA DNG per frame into `folder`, in the order given.
    static func write(_ frames: [Frame], to folder: URL) throws -> [URL] {
        try frames.map { frame in
            let url = folder.appendingPathComponent(frame.name)
            try writeDNG(photosites(frame.shot), captureTime: frame.captureTime, exposure: frame.shot.exposure,
                         to: url)
            return url
        }
    }

    /// Recipe sources for `urls`, as the app would give them.
    static func sources(_ urls: [URL]) -> [MergeRecipe.Source] {
        urls.enumerated().map { index, url in
            MergeRecipe.Source(path: url.lastPathComponent, hash: String(format: "%016x", index + 1),
                               captureTime: 1_789_498_800 + Int64(index))
        }
    }

    // MARK: - The camera and the scene

    /// The true camera for a shot.
    static func camera(_ shot: PanoMergeTestSupport.Shot, frameIndex: Int = 0) -> PanoramaCamera {
        PanoramaCamera(frameIndex: frameIndex,
                       rotation: PanoBlendTestSupport.rotation(yaw: shot.yaw, pitch: shot.pitch, roll: shot.roll),
                       focalLengthPixels: focalPixels,
                       principalPoint: SIMD2(Double(width) / 2, Double(height) / 2),
                       width: width, height: height, exposureGain: 1 / shot.exposure)
    }

    /// The scene as this shot's sensor records it, RGGB, no noise, clipped
    /// at white like a real sensor.
    static func photosites(_ shot: PanoMergeTestSupport.Shot) -> [UInt16] {
        let camera = camera(shot)
        let blacks = [Double(SyntheticBracket.black.r), Double(SyntheticBracket.black.g),
                      Double(SyntheticBracket.black.b)]
        var raw = [UInt16](repeating: 0, count: width * height)
        let edge = edge, width = width
        raw.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let colour = (y & 1 == 0) ? (x & 1 == 0 ? 0 : 1) : (x & 1 == 0 ? 1 : 2)
                    let direction = PanoramaMath.direction(framePixel: SIMD2(Double(x) + 0.5, Double(y) + 0.5),
                                                           camera: camera)
                    let radiance = PanoMergeTestSupport.radiance(direction, edge: edge)
                    let signal = radiance[colour] * shot.exposure * SyntheticBracket.countsPerUnit
                    out[y * width + x] = UInt16(min(max((blacks[colour] + signal).rounded(), 0),
                                                    Double(SyntheticBracket.white)))
                }
            }
        }
        return raw
    }

    /// What the merged panorama should hold at canvas point `p` (scale 1),
    /// in the merge's own units at exposure 1. An HDR panorama's pixels are
    /// this times one constant: each position's merge is relative to the
    /// brightest frame of its own bracket, and the DNG writer divides by a
    /// power of two on top.
    static func truth(canvasPixel p: SIMD2<Double>, canvas: PanoramaCanvas) -> SIMD3<Double>? {
        guard let direction = PanoramaMath.direction(canvasPixel: p, canvas: canvas) else { return nil }
        return PanoMergeTestSupport.radiance(direction, edge: edge) * SyntheticBracket.normalisedPerUnit
    }

    /// How the stitched panorama compares with the scene it was made from,
    /// sampled over `rect` of the output.
    ///
    /// What is checked is that the one unknown constant really is *one*
    /// constant: the spread of the ratio, and how much it differs between
    /// the left and right thirds — a stitch that didn't even the positions
    /// out shows as a step there.
    struct SceneComparison {
        /// The median of merged / true, over every sample and colour.
        let scale: Double
        /// The p90 of |ratio / scale − 1|: how far from one constant it is.
        let spread: Double
        /// The median ratio in the left and right thirds of `rect`.
        let leftScale: Double
        let rightScale: Double
        let samples: Int

        /// The difference between the thirds, as a share.
        var sideStep: Double { abs(leftScale - rightScale) / scale }
    }

    static func compare(_ merged: PanoMergeTestSupport.Merged, with analysis: PanoramaMergeAnalysis,
                        over rect: CGRect, step: Int = 5) -> SceneComparison {
        var ratios: [Double] = [], left: [Double] = [], right: [Double] = []
        let scale = analysis.outputSize.scale
        let third = rect.minX + rect.width / 3, twoThirds = rect.minX + 2 * rect.width / 3
        for y in stride(from: Int(rect.minY) + 8, to: Int(rect.maxY) - 8, by: step) {
            for x in stride(from: Int(rect.minX) + 8, to: Int(rect.maxX) - 8, by: step) {
                let canvasPixel = (SIMD2(Double(x), Double(y)) + 0.5) / scale
                guard let truth = truth(canvasPixel: canvasPixel, canvas: analysis.layout.canvas) else { continue }
                let pixel = merged.pixel(x, y)
                for c in 0..<3 where truth[c] > 0 {
                    let ratio = pixel[c] / truth[c]
                    ratios.append(ratio)
                    if Double(x) < third { left.append(ratio) } else if Double(x) > twoThirds { right.append(ratio) }
                }
            }
        }
        func median(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            return values.sorted()[values.count / 2]
        }
        let scaleFactor = median(ratios)
        var spread = ratios.map { abs($0 / max(scaleFactor, 1e-12) - 1) }.sorted()
        if spread.isEmpty { spread = [0] }
        return SceneComparison(scale: scaleFactor, spread: spread[spread.count * 9 / 10],
                               leftScale: median(left), rightScale: median(right), samples: ratios.count / 3)
    }

    // MARK: - The file

    /// A CFA DNG of `raw`, as `PanoMergeTestSupport.writeDNG` writes one but
    /// at this support's own size.
    static func writeDNG(_ raw: [UInt16], captureTime: Date, exposure: Double, to url: URL) throws {
        var ifd0 = TIFFDirectory()
        ifd0.set(TIFFTag.newSubfileType, long: 0)
        ifd0.set(TIFFTag.imageWidth, long: UInt32(width))
        ifd0.set(TIFFTag.imageLength, long: UInt32(height))
        ifd0.set(TIFFTag.bitsPerSample, short: 16)
        ifd0.set(TIFFTag.compression, short: 1)
        ifd0.set(TIFFTag.photometricInterpretation, short: 32803) // CFA
        ifd0.set(TIFFTag.make, ascii: SyntheticBracket.make)
        ifd0.set(TIFFTag.model, ascii: SyntheticBracket.model)
        ifd0.set(TIFFTag.orientation, short: 1)
        ifd0.set(TIFFTag.samplesPerPixel, short: 1)
        ifd0.set(TIFFTag.rowsPerStrip, long: UInt32(height))
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
        exif.set(TIFFTag.exposureTime, .rationals([DNGTagValues.exposureTimeRational(exposure / 60)!]))
        exif.set(TIFFTag.fNumber, .rationals([TIFFRational(SyntheticBracket.aperture, denominator: 100)!]))
        exif.set(TIFFTag.isoSpeedRatings, short: UInt16(SyntheticBracket.iso))
        exif.set(TIFFTag.focalLength, .rationals([TIFFRational(focalMillimetres, denominator: 100)!]))
        exif.set(TIFFTag.dateTimeOriginal, ascii: formatter.string(from: captureTime))
        ifd0.set(TIFFTag.exifIFD, .directories([exif]))

        let bytes = raw.withUnsafeBytes { Array($0) }
        ifd0.imageData = LinearRawDNGWriter.singleChunk(bytes)
        var layout = try TIFFLayout(topLevel: [ifd0])
        try? FileManager.default.removeItem(at: url)
        _ = try LinearRawDNGWriter.write(&layout, toNewFileAt: url)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSweeps: [String: [URL]] = [:]
    private static let cacheFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MergeKitTests-HDRPano-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)
}
