import Foundation

/// The linear DNG fixtures in Fixtures/LinearDNG (see the README there for
/// how they were made), and the pixel values they were written with, so
/// tests can check what comes back without trusting the reader.
enum LinearFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/LinearDNG")

    /// 64 x 48, strips, JPEG preview, `latent:Merge` XMP: kind hdr, clip
    /// level 0.5, lens not applied, baseline shift 1. BaselineExposure +2.
    /// Lens EXIF for a Nikon 35 mm f/1.8.
    static let mergeHDR = "merge-hdr-64x48.dng"
    /// 64 x 48, strips, `latent:Merge`: panorama, clip level 1, lens applied.
    /// Same lens EXIF, which must be ignored.
    static let mergePanorama = "merge-panorama-64x48.dng"
    /// 64 x 48, strips, no XMP, BaselineExposure -0.5, with values the
    /// plane has to clean in the first two pixels (`plainSpecials`).
    static let plain = "plain-64x48.dng"
    /// 64 x 48, strips, Orientation 6, no lens EXIF.
    static let orientation6 = "orientation6-64x48.dng"
    /// 1200 x 800, deflate-compressed 512 px tiles, no lens EXIF.
    static let ramp = "ramp-1200x800.dng"
    /// 600 x 512, the merge contract's layout: 512 px uncompressed tiles,
    /// with a partial tile on the right. The top-left 600 x 512 of `ramp`.
    static let tiles512 = "tiles512-600x512.dng"
    /// 64 x 48, 16-bit integer samples (`integer16Pattern`), black 100,
    /// 200 and 300 per channel, white 16383.
    static let integer16 = "integer16-64x48.dng"

    static func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    /// Nikon D750 (the golden NEF's camera), as the fixtures record it.
    static let cameraToXYZ: [Float] = [0.9020, -0.2890, -0.0715, -0.4535, 1.2436, 0.2348, -0.0934, 0.1919, 0.7086]
    static let cameraMultipliers: [Float] = [2.078125, 1, 1.207031]

    /// The value at `(x, y)` of the 64 x 48 fixtures, RGB.
    static func pattern64x48(x: Int, y: Int) -> (Float16, Float16, Float16) {
        if y >= 40 && x < 16 { return (0.49, 0.49, 0.49) }
        if y >= 40 && x >= 16 && x < 32 { return (0.51, 0.51, 0.51) }
        return (Float16(x) / 64, Float16(y) / 64, Float16(x + y) / 128)
    }

    /// The two grey patches in the 64 x 48 fixtures' bottom rows, either
    /// side of the merge fixture's clip level of 0.5: 0.49 and 0.51 in
    /// every channel, a highlight just short of clipping and one clipped.
    static let belowClipPatch = (x: 8, y: 44)
    static let aboveClipPatch = (x: 24, y: 44)

    /// What the plain fixture stores in its first two pixels, and what the
    /// plane must hold for them: NaN and negative become 0; 2 and 65504
    /// stay (a linear DNG from elsewhere may exceed 1); the smallest
    /// subnormal stays. Infinity arrives as 65504: LibRaw itself turns a
    /// half-float infinity into the largest finite value as it decodes.
    static let plainSpecialsStored: [Float16] = [.nan, -0.25, .infinity, 2, 65504, Float16(bitPattern: 0x0001)]
    static let plainSpecialsCleaned: [Float16] = [0, 0, 65504, 2, 65504, Float16(bitPattern: 0x0001)]

    /// The value at `(x, y)` of the 1200 x 800 fixture, RGB.
    static func ramp(x: Int, y: Int) -> (Float16, Float16, Float16) {
        if x >= 100 && x < 300 && y >= 100 && y < 300 { return (0.25, 0.5, 0.125) }
        return (Float16(x % 256) / 256, Float16(y % 256) / 256, Float16((x / 8 + y / 8) % 128) / 128)
    }

    /// The stored 16-bit samples of the integer fixture, RGB.
    static func integer16Pattern(x: Int, y: Int) -> (UInt16, UInt16, UInt16) {
        (UInt16(100 + x * 200), UInt16(200 + y * 300), UInt16(300 + (x + y) * 100))
    }
}
