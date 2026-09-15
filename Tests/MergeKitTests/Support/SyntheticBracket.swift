import Foundation
@testable import MergeKit

/// Bayer raw brackets made from a known scene, written as CFA DNGs that
/// LibRaw opens like any camera's raw, so the HDR merge can be checked
/// against the truth with no private test files.
///
/// **The camera.** Called a Nikon D750 (see `make`): an RGGB sensor,
/// 16-bit samples, black 600 in red and both greens and 640 in blue (so a
/// merge that ignores per-channel black
/// tints its shadows blue), white 15520, and 14,000 counts above black for
/// a scene radiance of 1 at exposure 1. A photosite reads
/// black + exposure x radiance x 14000, plus shot noise (one electron per
/// count) and 3 counts of read noise, rounded and clipped at white.
enum SyntheticBracket {
    /// A real camera's name: LibRaw takes a DNG's colour matrix from its
    /// own table by camera name (for a DNG it leaves the black and white
    /// levels as the file says), and without one the merge has no colour.
    static let make = "Nikon"
    static let model = "D750"
    static let white: UInt16 = 15520
    /// Black per colour: red, green, blue.
    static let black: (r: UInt16, g: UInt16, b: UInt16) = (600, 600, 640)
    static let countsPerUnit = 14_000.0
    static let readNoise = 3.0
    static let iso = 100.0
    static let aperture = 8.0

    /// Merge units (normalised raw units at unit white balance) per unit
    /// of scene radiance at exposure 1: counts over white minus the lowest black.
    static var normalisedPerUnit: Double { countsPerUnit / Double(white - black.r) }

    // MARK: - The scene

    /// Linear scene radiance, three camera-RGB values per pixel, row by row.
    struct Scene {
        let width: Int
        let height: Int
        let rgb: [Float]

        func radiance(x: Int, y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 3
            return SIMD3(rgb[i], rgb[i + 1], rgb[i + 2])
        }
    }

    /// Where the test scene's parts are, for 1200 x 800.
    enum Layout {
        /// Neutral, from 2^-9.5 to 2^2 left to right: 11.5 stops.
        static let ramp = (rows: 0..<240, low: -9.5, high: 2.0)
        /// Six uniform colour patches, 200 px wide.
        static let patchRows = 240..<420
        static let patches: [(level: Float, colour: SIMD3<Float>)] = [
            (0.02, SIMD3(1.0, 0.5, 0.25)), (0.1, SIMD3(0.3, 1.0, 0.4)), (0.5, SIMD3(0.2, 0.4, 1.0)),
            (1.5, SIMD3(1, 1, 1)), (3.0, SIMD3(0.8, 0.6, 0.2)), (0.008, SIMD3(0.25, 0.25, 0.9)),
        ]
        /// A sharp vertical edge from 0.03 to 2 at x = 300, and to the
        /// right of x = 600 a smooth texture for the alignment check.
        static let edgeRows = 420..<600
        /// Neutral shadows, 2^-10 to 2^-5 over x 0..<800, for colour casts.
        static let shadowRows = 600..<800
        static let shadowColumns = 0..<800
        /// A disc brighter than every frame can record.
        static let disc = (x: 1000, y: 700, radius: 70, level: Float(64))
    }

    /// The test scene at `width x height` (laid out for 1200 x 800, scaled
    /// for other sizes), moved right by `shiftX` pixels.
    static func scene(width: Int = 1200, height: Int = 800, shiftX: Int = 0) -> Scene {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        let sx = Double(width) / 1200, sy = Double(height) / 800
        rgb.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let value = sceneRadiance(x: (Double(x - shiftX) + 0.5) / sx, y: (Double(y) + 0.5) / sy)
                    let i = (y * width + x) * 3
                    out[i] = value.x; out[i + 1] = value.y; out[i + 2] = value.z
                }
            }
        }
        return Scene(width: width, height: height, rgb: rgb)
    }

    /// The scene at a point of the 1200 x 800 layout.
    static func sceneRadiance(x: Double, y: Double) -> SIMD3<Float> {
        let row = Int(y.rounded(.down)), column = x
        if Layout.ramp.rows.contains(row) {
            let t = min(max(column / 1199, 0), 1)
            return SIMD3(repeating: Float(pow(2, Layout.ramp.low + (Layout.ramp.high - Layout.ramp.low) * t)))
        }
        if Layout.patchRows.contains(row) {
            let patch = Layout.patches[min(max(Int(column / 200), 0), Layout.patches.count - 1)]
            return patch.colour * patch.level
        }
        if Layout.edgeRows.contains(row) {
            if column < 300 { return SIMD3(repeating: 0.03) }
            if column < 600 { return SIMD3(repeating: 2) }
            let t = 0.5 + 0.25 * sin(0.05 * column + 0.3 * sin(0.031 * y)) + 0.25 * sin(0.043 * y + 0.7 * cos(0.017 * column))
            return SIMD3(0.9, 1, 0.8) * Float(0.05 * pow(2, 3 * t))
        }
        let d = Layout.disc
        let dx = column - Double(d.x), dy = y - Double(d.y)
        if dx * dx + dy * dy <= Double(d.radius * d.radius) { return SIMD3(repeating: d.level) }
        if column < Double(Layout.shadowColumns.upperBound) {
            return SIMD3(repeating: Float(pow(2, -10 + 5 * min(max(column / 799, 0), 1))))
        }
        return SIMD3(repeating: 0.01)
    }

    // MARK: - Frames

    /// One frame of a bracket.
    struct Frame {
        /// True exposure: radiance x this x `countsPerUnit` counts.
        let exposure: Double
        /// What the EXIF says the shutter was, in seconds.
        let exifShutter: Double
        var orientation: UInt16 = 1
        var make = SyntheticBracket.make
        var model = SyntheticBracket.model
        var shiftX = 0
        /// The WhiteLevel the file declares. Photosites still clip at
        /// `SyntheticBracket.white`; a higher tag makes a sensor that
        /// saturates below its nominal white, as some cameras do.
        var whiteLevelTag = SyntheticBracket.white
        /// Rectangles painted over the scene in this frame only: something
        /// that moved, for the deghosting tests.
        var patches: [Patch] = []
    }

    /// A uniform rectangle of scene radiance.
    struct Patch {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let radiance: SIMD3<Float>

        func contains(x px: Int, y py: Int) -> Bool {
            (x..<(x + width)).contains(px) && (y..<(y + height)).contains(py)
        }
    }

    /// `scene` with `patches` painted over it.
    static func painting(_ patches: [Patch], over scene: Scene) -> Scene {
        guard !patches.isEmpty else { return scene }
        var rgb = scene.rgb
        for patch in patches {
            for y in max(0, patch.y)..<min(scene.height, patch.y + patch.height) {
                for x in max(0, patch.x)..<min(scene.width, patch.x + patch.width) {
                    let i = (y * scene.width + x) * 3
                    rgb[i] = patch.radiance.x; rgb[i + 1] = patch.radiance.y; rgb[i + 2] = patch.radiance.z
                }
            }
        }
        return Scene(width: scene.width, height: scene.height, rgb: rgb)
    }

    /// Frames at the given true exposures, with EXIF telling the truth
    /// (shutter = exposure / 60 at ISO 100, f/8).
    static func frames(_ exposures: [Double]) -> [Frame] {
        exposures.map { Frame(exposure: $0, exifShutter: $0 / 60) }
    }

    /// The raw photosites of `scene` exposed at `exposure`, RGGB.
    static func photosites(of scene: Scene, exposure: Double, noise: Bool, seed: UInt64) -> [UInt16] {
        let w = scene.width, h = scene.height
        var raw = [UInt16](repeating: 0, count: w * h)
        let blacks = [Double(black.r), Double(black.g), Double(black.b)]
        raw.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: h) { y in
                var random = SplitMix64(seed: seed &+ UInt64(y) &* 0x9E37_79B9_7F4A_7C15)
                for x in 0..<w {
                    // RGGB: red at even row and column, blue at odd both.
                    let colour = (y & 1 == 0) ? (x & 1 == 0 ? 0 : 1) : (x & 1 == 0 ? 1 : 2)
                    let signal = Double(scene.rgb[(y * w + x) * 3 + colour]) * exposure * countsPerUnit
                    var value = blacks[colour] + signal
                    if noise {
                        value += random.gaussian() * (max(signal, 0) + readNoise * readNoise).squareRoot()
                    }
                    out[y * w + x] = UInt16(min(max(value.rounded(), 0), Double(white)))
                }
            }
        }
        return raw
    }

    /// Writes `frames` of `scene` as DNGs named `<name>-<index>.dng` in
    /// `folder`, returning their URLs in the order given.
    static func write(_ frames: [Frame], of scene: Scene, noise: Bool, to folder: URL,
                      name: String = "frame") throws -> [URL] {
        var shiftedScenes: [Int: Scene] = [0: scene]
        return try frames.enumerated().map { index, frame in
            let source: Scene
            if let cached = shiftedScenes[frame.shiftX] {
                source = cached
            } else {
                source = self.scene(width: scene.width, height: scene.height, shiftX: frame.shiftX)
                shiftedScenes[frame.shiftX] = source
            }
            let raw = photosites(of: painting(frame.patches, over: source), exposure: frame.exposure, noise: noise,
                                 seed: UInt64(index + 1) * 7919)
            let url = folder.appendingPathComponent("\(name)-\(index).dng")
            try writeDNG(raw, width: scene.width, height: scene.height, frame: frame, to: url)
            return url
        }
    }

    /// Radiance in merge units (relative to the brightest frame's white)
    /// for a scene radiance, when the brightest frame's exposure is `brightest`.
    static func mergeUnits(_ radiance: SIMD3<Float>, brightest: Double) -> SIMD3<Double> {
        SIMD3<Double>(radiance) * brightest * normalisedPerUnit
    }

    // MARK: - The DNG

    /// A CFA DNG: one uncompressed strip of 16-bit photosites.
    static func writeDNG(_ raw: [UInt16], width: Int, height: Int, frame: Frame, to url: URL) throws {
        var ifd0 = TIFFDirectory()
        ifd0.set(TIFFTag.newSubfileType, long: 0)
        ifd0.set(TIFFTag.imageWidth, long: UInt32(width))
        ifd0.set(TIFFTag.imageLength, long: UInt32(height))
        ifd0.set(TIFFTag.bitsPerSample, short: 16)
        ifd0.set(TIFFTag.compression, short: 1)
        ifd0.set(TIFFTag.photometricInterpretation, short: 32803)   // CFA
        ifd0.set(TIFFTag.make, ascii: frame.make)
        ifd0.set(TIFFTag.model, ascii: frame.model)
        ifd0.set(TIFFTag.orientation, short: frame.orientation)
        ifd0.set(TIFFTag.samplesPerPixel, short: 1)
        ifd0.set(TIFFTag.rowsPerStrip, long: UInt32(height))
        ifd0.set(TIFFTag.stripOffsets, .imageChunkOffsets)
        ifd0.set(TIFFTag.stripByteCounts, .imageChunkByteCounts)
        ifd0.set(TIFFTag.planarConfiguration, short: 1)
        ifd0.set(TIFFTag.software, ascii: "Latent tests")
        ifd0.set(CFATag.repeatPatternDim, .shorts([2, 2]))
        ifd0.set(CFATag.pattern, .bytes([0, 1, 1, 2]))                // RGGB
        ifd0.set(TIFFTag.dngVersion, .bytes([1, 4, 0, 0]))
        ifd0.set(TIFFTag.dngBackwardVersion, .bytes([1, 1, 0, 0]))
        ifd0.set(TIFFTag.uniqueCameraModel, ascii: "\(frame.make) \(frame.model)")
        ifd0.set(CFATag.planeColor, .bytes([0, 1, 2]))
        ifd0.set(CFATag.layout, short: 1)
        ifd0.set(CFATag.blackLevelRepeatDim, .shorts([2, 2]))
        ifd0.set(TIFFTag.blackLevel, .shorts([black.r, black.g, black.g, black.b]))
        ifd0.set(TIFFTag.whiteLevel, .shorts([frame.whiteLevelTag]))
        ifd0.set(TIFFTag.colorMatrix1, .srationals(try MergeDNGMetadata.colorMatrix(fromCamXYZ: Fixtures.d750CamXYZ)
            .map { TIFFSRational($0, denominator: 10_000)! }))
        ifd0.set(TIFFTag.asShotNeutral, .rationals(try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: Fixtures.d750Multipliers)
            .map { TIFFRational($0, denominator: 1_000_000)! }))
        ifd0.set(TIFFTag.calibrationIlluminant1, short: 21)

        var exif = TIFFDirectory()
        exif.set(TIFFTag.exifVersion, .undefined(Array("0231".utf8)))
        exif.set(TIFFTag.exposureTime, .rationals([DNGTagValues.exposureTimeRational(frame.exifShutter)!]))
        exif.set(TIFFTag.fNumber, .rationals([TIFFRational(aperture, denominator: 100)!]))
        exif.set(TIFFTag.isoSpeedRatings, short: UInt16(iso))
        exif.set(TIFFTag.dateTimeOriginal, ascii: "2026:09:15 12:00:00")
        ifd0.set(TIFFTag.exifIFD, .directories([exif]))

        let bytes = raw.withUnsafeBytes { Array($0) }
        ifd0.imageData = LinearRawDNGWriter.singleChunk(bytes)
        var layout = try TIFFLayout(topLevel: [ifd0])
        try? FileManager.default.removeItem(at: url)
        _ = try LinearRawDNGWriter.write(&layout, toNewFileAt: url)
    }

    enum CFATag {
        static let repeatPatternDim: UInt16 = 33421
        static let pattern: UInt16 = 33422
        static let planeColor: UInt16 = 50710
        static let layout: UInt16 = 50711
        static let blackLevelRepeatDim: UInt16 = 50713
    }
}

/// A small, fast, seedable random generator (Vigna's SplitMix64), so
/// every run makes the same noise.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1).
    mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / Double(1 << 53) }

    /// Standard normal, by Box-Muller.
    mutating func gaussian() -> Double {
        (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}
