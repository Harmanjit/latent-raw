import Foundation
import RawCore
import XCTest
import simd
@testable import MergeKit

/// Synthetic panoramas: photos of a scene painted on the sphere, written as
/// CFA DNGs that LibRaw opens like any camera's raw, so the whole merge —
/// reading the photos, the geometry, the blend, the DNG — can be checked
/// against the truth with no private test files.
///
/// The camera is `SyntheticBracket`'s "Nikon D750" (RGGB, black 600/600/640,
/// white 15520, 14,000 counts for a radiance of 1 at exposure 1), turned by
/// a known yaw, pitch and roll for each shot, one second apart.
enum PanoMergeTestSupport {
    struct Shot {
        var yaw: Double
        var pitch = 0.0
        var roll = 0.0
        /// The photo's exposure: photosites read `radiance x this x 14000`
        /// counts above black, and EXIF says so.
        var exposure = 1.0
    }

    /// The photos' size and lens. 900 x 600 px at 700 px focal length is
    /// 65° x 46°, so 0.4 rad steps overlap by about half.
    static let width = 900
    static let height = 600
    static let focalPixels = 700.0
    /// What EXIF says, so the solver starts from the truth: f_px x sensor
    /// diagonal in mm / diagonal in px, full frame.
    static var focalMillimetres: Double {
        let diagonal = (Double(width * width + height * height)).squareRoot()
        return focalPixels * PanoramaFrameMetadata.fullFrameDiagonalMillimetres / diagonal
    }

    /// Edges about two pixels wide, so binning and warping don't alias.
    static var edge: Double { 2 / focalPixels }

    /// The true camera for a shot, as `PanoramaCamera` describes it.
    static func camera(_ shot: Shot, frameIndex: Int) -> PanoramaCamera {
        PanoramaCamera(frameIndex: frameIndex,
                       rotation: PanoBlendTestSupport.rotation(yaw: shot.yaw, pitch: shot.pitch, roll: shot.roll),
                       focalLengthPixels: focalPixels,
                       principalPoint: SIMD2(Double(width) / 2, Double(height) / 2),
                       width: width, height: height, exposureGain: 1 / shot.exposure)
    }

    /// A row of `count` photos turning right in `step` radian steps, centred
    /// on straight ahead.
    static func row(count: Int, step: Double = 0.4, exposures: [Double] = []) -> [Shot] {
        (0..<count).map { index in
            let yaw = (Double(index) - Double(count - 1) / 2) * step
            return Shot(yaw: yaw, exposure: exposures.indices.contains(index) ? exposures[index] : 1)
        }
    }

    /// The photos for `shots`, written once per test run and kept in a
    /// shared folder under `name`: painting a scene into photosites is slow
    /// in a debug build, and several tests want the same set.
    static func cached(_ name: String, _ shots: [Shot]) throws -> [URL] {
        try cacheLock.withLock {
            if let made = cachedPhotos[name] { return made }
            let folder = cacheFolder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = try write(shots, to: folder)
            cachedPhotos[name] = urls
            return urls
        }
    }

    /// Deletes what `cached` wrote (the tests' class teardown).
    static func removeCachedPhotos() {
        cacheLock.withLock {
            cachedPhotos = [:]
            try? FileManager.default.removeItem(at: cacheFolder)
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedPhotos: [String: [URL]] = [:]
    private static let cacheFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MergeKitTests-PanoMerge-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    /// Writes one DNG per shot into `folder`, named `pano-0.dng` upwards and
    /// stamped a second apart in capture order. Returns them in that order.
    static func write(_ shots: [Shot], to folder: URL, name: String = "pano") throws -> [URL] {
        try shots.enumerated().map { index, shot in
            let raw = photosites(shot, frameIndex: index)
            let url = folder.appendingPathComponent("\(name)-\(index).dng")
            try writeDNG(raw, captureTime: captureTime(index), exposure: shot.exposure, to: url)
            return url
        }
    }

    static func captureTime(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_789_498_800 + Double(index))
    }

    /// The scene as this shot's sensor records it, RGGB, no noise (so the
    /// merge can be compared with the scene itself).
    static func photosites(_ shot: Shot, frameIndex: Int) -> [UInt16] {
        let camera = camera(shot, frameIndex: frameIndex)
        let blacks = [Double(SyntheticBracket.black.r), Double(SyntheticBracket.black.g),
                      Double(SyntheticBracket.black.b)]
        var raw = [UInt16](repeating: 0, count: width * height)
        let edge = edge
        raw.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let colour = (y & 1 == 0) ? (x & 1 == 0 ? 0 : 1) : (x & 1 == 0 ? 1 : 2)
                    let direction = PanoramaMath.direction(framePixel: SIMD2(Double(x) + 0.5, Double(y) + 0.5),
                                                           camera: camera)
                    let radiance = Self.radiance(direction, edge: edge)
                    let signal = radiance[colour] * shot.exposure * SyntheticBracket.countsPerUnit
                    out[y * width + x] = UInt16(min(max((blacks[colour] + signal).rounded(), 0),
                                                    Double(SyntheticBracket.white)))
                }
            }
        }
        return raw
    }

    /// What the merged panorama should hold at canvas point `p` (scale 1):
    /// the scene's radiance in the merge's own units (counts above black
    /// over the sensor's range).
    static func truth(canvasPixel p: SIMD2<Double>, canvas: PanoramaCanvas) -> SIMD3<Double>? {
        guard let direction = PanoramaMath.direction(canvasPixel: p, canvas: canvas) else { return nil }
        return radiance(direction, edge: edge) * SyntheticBracket.normalisedPerUnit
    }

    // MARK: - The scene

    /// One of the marks scattered over the sphere.
    struct Mark {
        let theta: Double
        let phi: Double
        let radius: Double
        let colour: SIMD3<Double>
    }

    /// Bright marks at scattered, never-repeating places, so that no two
    /// parts of the sky look alike and every photo has plenty to match on: a
    /// periodic scene (stripes, a checkerboard) lets the aligner lock onto
    /// the wrong period, which is a property of the scene, not of the merge.
    ///
    /// One large and one small mark per cell of a 28 x 10 grid over the
    /// whole sphere the tests use, each jittered inside its cell, so no part
    /// of it is empty. Sorted by longitude, so a pixel only looks at the few
    /// marks near it.
    static let marks: [Mark] = {
        var marks: [Mark] = []
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(1 << 53)
        }
        let columns = 28, rows = 10
        for column in 0..<columns {
            for row in 0..<rows {
                let theta = -2.4 + 4.8 * (Double(column) + next()) / Double(columns)
                let phi = -0.75 + 1.5 * (Double(row) + next()) / Double(rows)
                for large in [true, false] {
                    marks.append(Mark(theta: theta + (large ? 0 : 0.04), phi: phi + (large ? 0 : 0.03),
                                      radius: large ? 0.020 + 0.020 * next() : 0.004 + 0.004 * next(),
                                      colour: SIMD3(0.10 + 0.35 * next(), 0.10 + 0.35 * next(),
                                                    0.10 + 0.35 * next())))
                }
            }
        }
        return marks.sorted { $0.theta < $1.theta }
    }()

    /// How far from a mark's centre it can still be seen, at most.
    static let markReach = (marks.map(\.radius).max() ?? 0) + 0.02

    /// Linear camera RGB seen in direction `d`: a smooth, non-repeating
    /// background, darker below the horizon, with soft-edged marks over it.
    /// Values stay between 0.02 and 0.95. `edge` is how wide a mark's edge
    /// is, in radians.
    static func radiance(_ d: SIMD3<Double>, edge: Double) -> SIMD3<Double> {
        let horizontal = (d.x * d.x + d.z * d.z).squareRoot()
        let theta = atan2(d.x, d.z), phi = atan2(-d.y, horizontal)
        func soft(_ t: Double) -> Double { 0.5 + 0.5 * tanh(t / edge) }
        var rgb = SIMD3(0.20 + 0.09 * sin(0.8 * theta + 0.3) + 0.05 * cos(1.1 * phi),
                        0.18 + 0.08 * cos(0.6 * theta - 0.7) + 0.06 * sin(0.9 * phi + 0.2),
                        0.22 + 0.09 * sin(0.5 * theta + 1.1) - 0.05 * cos(0.8 * phi))
        // A ground half, darker, with the horizon as one long edge.
        rgb *= 1 - 0.45 * soft(-phi - 0.12)
        // The marks near this longitude (they are sorted by it).
        var low = 0, high = marks.count
        while low < high {
            let middle = (low + high) / 2
            if marks[middle].theta < theta - markReach { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < marks.count, marks[index].theta <= theta + markReach {
            let mark = marks[index]
            index += 1
            guard abs(phi - mark.phi) < mark.radius + 8 * edge else { continue }
            let distance = ((theta - mark.theta) * (theta - mark.theta)
                            + (phi - mark.phi) * (phi - mark.phi)).squareRoot()
            rgb += mark.colour * soft(mark.radius - distance)
        }
        return simd_clamp(rgb, SIMD3(repeating: 0.02), SIMD3(repeating: 0.95))
    }

    // MARK: - The file

    /// A CFA DNG of `raw`, like `SyntheticBracket.writeDNG` but with this
    /// frame's capture time, shutter and focal length, which the panorama's
    /// ordering and geometry need.
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

    // MARK: - Reading a merge back

    /// The merged DNG's pixels in the merge's own units (the file's, times
    /// 2^baselineShift), with what the file says about itself.
    struct Merged {
        let width: Int
        let height: Int
        let rgb: [Float]
        let info: LinearMergeInfo
        let baselineExposure: Float
        let orientation: Int

        func pixel(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = (y * width + x) * 3
            return SIMD3(Double(rgb[i]), Double(rgb[i + 1]), Double(rgb[i + 2]))
        }

        /// True where every channel is exactly zero: a pixel no photo covered.
        func isUncovered(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 3
            return rgb[i] == 0 && rgb[i + 1] == 0 && rgb[i + 2] == 0
        }
    }

    static func read(_ url: URL) throws -> Merged {
        let file = try RawFile(path: url.path)
        guard case .linearRGB = file.summary.cfaPattern else {
            throw XCTSkip("\(url.lastPathComponent) didn't open as a linear source")
        }
        let plane = try XCTUnwrap(file.linearPlane)
        let info = try XCTUnwrap(file.summary.mergeInfo)
        let scale = Float(sign: .plus, exponent: info.baselineShift, significand: 1)
        let samples = plane.samples
        var rgb = [Float](repeating: 0, count: plane.width * plane.height * 3)
        for i in 0..<(plane.width * plane.height) {
            for c in 0..<3 { rgb[i * 3 + c] = Float(samples[i * 4 + c]) * scale }
        }
        return Merged(width: plane.width, height: plane.height, rgb: rgb, info: info,
                      baselineExposure: file.summary.baselineExposure, orientation: file.summary.orientation)
    }

    // MARK: - Running a merge

    /// The sources a merge records, for photos that need no real hashes.
    static func sources(_ analysis: PanoramaMergeAnalysis) -> [MergeRecipe.Source] {
        analysis.frames.map {
            MergeRecipe.Source(path: $0.url.lastPathComponent, hash: "0000000000000000",
                               captureTime: Int64($0.captureTime.timeIntervalSince1970))
        }
    }

    /// Lets a test hand a task to code that runs inside it before that code
    /// starts (so a progress callback can cancel its own merge).
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false

        func open() { lock.withLock { opened = true } }
        var isOpen: Bool { lock.withLock { opened } }

        func wait() async {
            while !isOpen { await Task.yield() }
        }
    }

    /// A task a callback can cancel, set after the task is made.
    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        private(set) var cancelledAt: Double?

        func hold(_ task: Task<Void, Error>) { lock.withLock { self.task = task } }

        func cancel(at fraction: Double) {
            let task: Task<Void, Error>? = lock.withLock {
                guard cancelledAt == nil else { return nil }
                cancelledAt = fraction
                return self.task
            }
            task?.cancel()
        }
    }
}
