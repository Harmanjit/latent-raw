# Linear DNG test fixtures

Small floating-point LinearRaw DNGs, the kind of file Photo Merge writes,
for the tests that open linear sources (`LinearDNGFileTests`,
`LinearSourceRenderTests`, `LensRegionTests`, and MLKit's
`AIDenoiseLinearSourceTests`).
`LinearFixtures.swift` describes each file and holds the pixel values it was
written with, so the tests check what comes back against what went in.

| File | Size | Layout | What it is for |
|---|---|---|---|
| `merge-hdr-64x48.dng` | 64 x 48 | strips | A merge: `latent:Merge` XMP (hdr, clip level 0.5, lens not applied, shift 1), BaselineExposure +2, JPEG preview, lens EXIF |
| `merge-panorama-64x48.dng` | 64 x 48 | strips | `latent:Merge` with lens applied: the lens EXIF must be ignored |
| `plain-64x48.dng` | 64 x 48 | strips | No XMP, BaselineExposure -0.5, NaN/negative/infinity/65504 samples to clean |
| `orientation6-64x48.dng` | 64 x 48 | strips | Orientation 6 |
| `ramp-1200x800.dng` | 1200 x 800 | 512 px tiles, deflate | Several tiles; the render tests' main image |
| `tiles512-600x512.dng` | 600 x 512 | 512 px tiles, uncompressed | The merge contract's own layout, with a partial tile |
| `integer16-64x48.dng` | 64 x 48 | strips | 16-bit integer LinearRaw, black 100/200/300, white 16383 |

All are float16 camera RGB for a Nikon D750 (the golden NEF's camera
matrix and as-shot white balance), except the integer one.

## How they were made

With the writer from Photo Merge's Phase 0 DNG spike (its
`Sources/DNGKit`), which the spike showed LibRaw reads back bit for bit.
The spike is not part of this repository. Its production port is
`Sources/MergeKit/DNG` (`LinearRawDNGWriter`), which has a different API,
so the generator below does not build against this repository as it
stands; it is kept as the record of what each file holds. It was compiled
in a throwaway package together with the spike's three writer files,
linked in, so the fixtures are exactly what that writer produces plus the
few tags it doesn't write itself (lens EXIF, per-channel black):

```sh
# SPIKE is a checkout of the DNG spike.
mkdir -p /tmp/fixturegen/Sources/fixturegen && cd /tmp/fixturegen
for f in LinearRawDNG TIFFWriter FloatDeflate; do
  ln -sf "$SPIKE/Sources/DNGKit/$f.swift" Sources/fixturegen/$f.swift
done
cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "fixturegen", platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "fixturegen", path: "Sources/fixturegen",
                                swiftSettings: [.swiftLanguageMode(.v5)])])
SWIFT
# Save the generator below as Sources/fixturegen/main.swift, then:
swift run fixturegen <this folder>
```

Regenerating changes the files only if the generator or the writer changed,
and porting the generator to `LinearRawDNGWriter` is such a change; if
either did, `LinearFixtures.swift` has to agree.

## A LibRaw quirk the layout works around

LibRaw 0.22.2 misreads a tiled floating-point DNG whose image is narrower
or shorter than one tile: it decides such a file isn't tiled
(`tile_stripe_data_t::init` in `src/decoders/fp_dng.cpp`) and reads the
padded tile as if it were rows of the image, so everything after the
first row comes back wrong. That is why the 64 x 48 files use strips, and
why `tiles512-600x512.dng` is the smallest image with the contract's
512 px tiles. A merge smaller than 512 px on either side must be written
with strips (or smaller tiles).

## The generator

```swift
// fixturegen <output folder>
//
// Writes the linear DNG fixtures for Latent's Tests/PixelEngineTests/
// Fixtures/LinearDNG. Compiled together with the Photo Merge DNG spike's
// writer (its Sources/DNGKit/*.swift, symlinked in, not copied), so the
// files are exactly what that writer produces, plus the few tags the spike
// doesn't write (lens EXIF, per-channel black).

import CoreGraphics
import Foundation
import ImageIO

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Nikon D750, as LibRaw reports TestAssets/golden_nikon_d750_cc0.nef.
let camXYZ: [Double] = [0.9020, -0.2890, -0.0715, -0.4535, 1.2436, 0.2348, -0.0934, 0.1919, 0.7086]
let camMul: [Double] = [2.078125, 1, 1.207031]

enum ExtraTag {
    static let focalLength: UInt16 = 37386
    static let lensSpecification: UInt16 = 42034
    static let lensMake: UInt16 = 42035
    static let lensModel: UInt16 = 42036
    static let focalLengthIn35mmFilm: UInt16 = 41989
}

func metadata(baselineExposure: Double = 0, orientation: UInt16 = 1, xmp: String? = nil) -> DNGMetadata {
    var m = DNGMetadata()
    m.make = "Nikon"
    m.model = "D750"
    m.uniqueCameraModel = "Nikon D750"
    m.software = "Latent 0.1.0 (test fixture)"
    m.colorMatrix1 = camXYZ
    m.calibrationIlluminant1 = 21
    m.asShotNeutral = [camMul[1] / camMul[0], 1, camMul[1] / camMul[2]]
    m.baselineExposure = baselineExposure
    m.whiteLevel = 1
    m.orientation = orientation
    m.exposureTime = 1.0 / 30
    m.fNumber = 1.8
    m.iso = 100
    m.xmp = xmp
    return m
}

func xmpPacket(json: String) -> String {
    """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:latent="https://github.com/Harmanjit/latent-raw/ns/1.0/">
       <latent:Merge><![CDATA[\(json)]]></latent:Merge>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
}

func mergeJSON(kind: String, clipLevel: Double, lensApplied: Bool, baselineShift: Int) -> String {
    """
    {"version":1,"kind":"\(kind)","algorithmVersion":"1","clipLevel":\(clipLevel),\
    "lensApplied":\(lensApplied),"baselineShift":\(baselineShift),"reference":1,\
    "options":{"deghost":"none","futureOption":[1,2,3]},\
    "sources":[{"path":"DSC_0001.NEF","hash":"0123456789abcdef","captureTime":1789473600},\
    {"path":"DSC_0002.NEF","hash":"fedcba9876543210","captureTime":1789473601}],\
    "someFutureKey":{"nested":true}}
    """
}

/// The 64 x 48 pattern: exact Float16 ramps, plus two patches in the
/// bottom rows either side of 0.5 for the highlight clip test.
func pattern64x48() -> [Float16] {
    let w = 64, h = 48
    var px = [Float16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 3
            var rgb: (Float16, Float16, Float16) = (Float16(x) / 64, Float16(y) / 64, Float16(x + y) / 128)
            if y >= 40 && x < 16 { rgb = (0.49, 0.49, 0.49) }
            if y >= 40 && x >= 16 && x < 32 { rgb = (0.51, 0.51, 0.51) }
            px[i] = rgb.0; px[i + 1] = rgb.1; px[i + 2] = rgb.2
        }
    }
    return px
}

/// The 1200 x 800 pattern: exact ramps repeating every 256 pixels and a
/// flat patch.
func pattern1200x800() -> [Float16] {
    let w = 1200, h = 800
    var px = [Float16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 3
            if x >= 100 && x < 300 && y >= 100 && y < 300 {
                px[i] = 0.25; px[i + 1] = 0.5; px[i + 2] = 0.125
            } else {
                px[i] = Float16(x % 256) / 256
                px[i + 1] = Float16(y % 256) / 256
                px[i + 2] = Float16((x / 8 + y / 8) % 128) / 128
            }
        }
    }
    return px
}

func thumbnail(_ px: [Float16], width: Int, height: Int, factor: Int) -> RGB8Image {
    let tw = width / factor, th = height / factor
    var rgb = [UInt8](repeating: 0, count: tw * th * 3)
    for y in 0..<th { for x in 0..<tw { for c in 0..<3 {
        let v = Float(px[((y * factor) * width + x * factor) * 3 + c])
        rgb[(y * tw + x) * 3 + c] = UInt8(max(0, min(255, (v.isFinite ? v : 0) * 255)))
    } } }
    return RGB8Image(width: tw, height: th, pixels: rgb)
}

func jpeg(_ image: RGB8Image) -> (data: Data, width: Int, height: Int) {
    let provider = CGDataProvider(data: Data(image.pixels) as CFData)!
    let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24,
                     bytesPerRow: image.width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    precondition(CGImageDestinationFinalize(dest))
    return (out as Data, image.width, image.height)
}

/// Writes `dng`, letting `adjust` change the IFD tree first.
func write(_ dng: LinearRawDNG, _ name: String, lens: Bool = true,
           adjust: (_ ifd0: TIFFIFD, _ raw: TIFFIFD) -> Void = { _, _ in }) throws {
    let ifd0 = try dng.makeIFD0()
    guard case .ifdOffsets(let subIFDs)? = ifd0.entries[Tag.subIFDs],
          case .ifdOffsets(let exifIFDs)? = ifd0.entries[Tag.exifIFD] else { fatalError("no sub IFDs") }
    if lens {
        // A Nikon AF-S 35mm f/1.8G ED at the golden NEF's focal length and
        // aperture (its own lens is a Tamron SP 35mm f/1.8), so Lensfun has
        // a profile to match when the merge hasn't applied one already.
        let exif = exifIFDs[0]
        exif.set(ExtraTag.focalLength, .rationals([TIFFRational(35, 1)]))
        exif.set(ExtraTag.focalLengthIn35mmFilm, short: 35)
        exif.set(ExtraTag.lensSpecification, .rationals([TIFFRational(35, 1), TIFFRational(35, 1),
                                                         TIFFRational(18, 10), TIFFRational(18, 10)]))
        exif.set(ExtraTag.lensMake, ascii: "Nikon")
        exif.set(ExtraTag.lensModel, ascii: "AF-S Nikkor 35mm f/1.8G ED")
    }
    adjust(ifd0, subIFDs[0])
    let url = outDir.appendingPathComponent(name)
    try TIFFFile([ifd0]).write(to: url)
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote \(name): \(size) bytes")
}

let small = pattern64x48()

// 1. A merge: a JPEG preview, latent:Merge XMP, clip level 0.5, one stop
//    of normalisation folded into a BaselineExposure of +2. Strips, not the contract's 512 px tiles: LibRaw
//    0.22.2 misreads a tiled image narrower or shorter than one tile
//    (fixture 7 covers the tiled layout).
do {
    var dng = LinearRawDNG(width: 64, height: 48, pixels: small)
    dng.layout = .strips(rowsPerStrip: 16)
    dng.metadata = metadata(baselineExposure: 2, xmp: xmpPacket(json: mergeJSON(
        kind: "hdr", clipLevel: 0.5, lensApplied: false, baselineShift: 1)))
    dng.thumbnail = thumbnail(small, width: 64, height: 48, factor: 2)
    dng.jpegPreview = jpeg(thumbnail(small, width: 64, height: 48, factor: 1))
    try write(dng, "merge-hdr-64x48.dng")
}

// 2. A panorama: lens correction already applied, lens EXIF still present.
do {
    var dng = LinearRawDNG(width: 64, height: 48, pixels: small)
    dng.layout = .strips(rowsPerStrip: 48)
    dng.metadata = metadata(xmp: xmpPacket(json: mergeJSON(
        kind: "panorama", clipLevel: 1, lensApplied: true, baselineShift: 0)))
    try write(dng, "merge-panorama-64x48.dng")
}

// 3. A linear DNG from elsewhere: no XMP, a negative BaselineExposure, and
//    values the plane must clean (NaN, negative, infinity, above 1).
do {
    var px = small
    px[0] = .nan; px[1] = -0.25; px[2] = .infinity
    px[3] = 2; px[4] = 65504; px[5] = Float16(bitPattern: 0x0001)
    var dng = LinearRawDNG(width: 64, height: 48, pixels: px)
    dng.layout = .strips(rowsPerStrip: 16)
    dng.metadata = metadata(baselineExposure: -0.5)
    try write(dng, "plain-64x48.dng")
}

// 4. Orientation 6 (rotate 90° clockwise to view).
do {
    var dng = LinearRawDNG(width: 64, height: 48, pixels: small)
    dng.layout = .strips(rowsPerStrip: 48)
    dng.metadata = metadata(orientation: 6)
    try write(dng, "orientation6-64x48.dng", lens: false)
}

// 5. A larger image, deflate-compressed tiles, for render tests.
do {
    var dng = LinearRawDNG(width: 1200, height: 800, pixels: pattern1200x800())
    dng.layout = .tiles(size: 512)
    dng.compression = .deflate(.floatingPoint)
    dng.metadata = metadata()
    try write(dng, "ramp-1200x800.dng", lens: false)
}

// 6. 16-bit integer LinearRaw, as other converters write, with a black
//    level per channel and a 14-bit white. The samples are the Float16
//    array's bit patterns, which the writer copies byte for byte.
do {
    var px = [Float16](repeating: 0, count: 64 * 48 * 3)
    for y in 0..<48 { for x in 0..<64 {
        let i = (y * 64 + x) * 3
        px[i] = Float16(bitPattern: UInt16(100 + x * 200))
        px[i + 1] = Float16(bitPattern: UInt16(200 + y * 300))
        px[i + 2] = Float16(bitPattern: UInt16(300 + (x + y) * 100))
    } }
    var dng = LinearRawDNG(width: 64, height: 48, pixels: px)
    dng.layout = .strips(rowsPerStrip: 48)
    dng.metadata = metadata()
    dng.metadata.whiteLevel = 16383
    try write(dng, "integer16-64x48.dng", lens: false) { _, raw in
        raw.set(Tag.sampleFormat, .shorts([1, 1, 1]))
        raw.set(50713, .shorts([1, 1]))  // BlackLevelRepeatDim
        raw.set(Tag.blackLevel, .shorts([100, 200, 300]))
    }
}


// 7. The contract's layout: 512 px uncompressed tiles, with a partial tile
//    on the right. 600 x 512 is about the smallest image that has one.
do {
    let w = 600, h = 512
    let ramp = pattern1200x800()
    var px = [Float16](repeating: 0, count: w * h * 3)
    for y in 0..<h { for x in 0..<w { for c in 0..<3 { px[(y * w + x) * 3 + c] = ramp[(y * 1200 + x) * 3 + c] } } }
    var dng = LinearRawDNG(width: w, height: h, pixels: px)
    dng.layout = .tiles(size: 512)
    dng.metadata = metadata()
    try write(dng, "tiles512-600x512.dng", lens: false)
}
```
