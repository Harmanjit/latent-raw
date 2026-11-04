import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// Flat-field correction (FlatField.swift): the gain map from a reference,
/// where the reference is kept, the stored module, and the stage on the
/// GPU.
final class FlatFieldTests: XCTestCase {
    // MARK: - The gain map

    /// A synthetic reference whose corners fall off and turn blue: the
    /// map lifts each channel back to the centre's level, so the cast goes
    /// with the vignetting.
    func testGainMapUndoesFalloffAndCast() throws {
        let w = 300, h = 200
        var pixels = [Float](repeating: 0, count: w * h * 4)
        func falloff(_ x: Int, _ y: Int) -> Float {
            let u = (Float(x) + 0.5) / Float(w) - 0.5, v = (Float(y) + 0.5) / Float(h) - 0.5
            return 1 - 0.8 * (u * u + v * v)   // 0.74 in the corners
        }
        for y in 0..<h {
            for x in 0..<w {
                let f = falloff(x, y)
                let i = (y * w + x) * 4
                // Red falls off faster than blue: a blue cast in the corners.
                pixels[i] = 0.4 * f * f; pixels[i + 1] = 0.5 * f; pixels[i + 2] = 0.3 * f.squareRoot(); pixels[i + 3] = 1
            }
        }
        let map = try FlatFieldGainMap.make(cameraRGB: pixels, width: w, height: h, clipLevel: SIMD3(1, 1, 1),
                                            aspect: 1.5, name: "flat.NEF")
        XCTAssertEqual(map.width, 64)
        XCTAssertEqual(map.height, 43)
        let centre = map.gain(x: map.width / 2, y: map.height / 2)
        XCTAssertEqual(centre.x, 1, accuracy: 0.02)
        XCTAssertEqual(centre.y, 1, accuracy: 0.02)
        let corner = map.gain(x: 1, y: 1)
        // Corrected corner = reference x gain, which is the centre's value.
        XCTAssertGreaterThan(corner.x, corner.y, "red is lifted most")
        XCTAssertGreaterThan(corner.y, corner.z)
        let f = falloff(w * 1 / map.width + 2, h * 1 / map.height + 2)
        XCTAssertEqual(corner.y, 1 / f, accuracy: 0.05)
        XCTAssertTrue(map.fits(aspect: 6016.0 / 4016.0))
        XCTAssertFalse(map.fits(aspect: 1), "another sensor shape")
    }

    func testReferenceTooDarkOrClippedIsRefused() {
        let w = 64, h = 48
        let dark = [Float](repeating: 0.001, count: w * h * 4)
        XCTAssertThrowsError(try FlatFieldGainMap.make(cameraRGB: dark, width: w, height: h, clipLevel: SIMD3(1, 1, 1),
                                                       aspect: 1.33, name: "a")) {
            XCTAssertEqual($0 as? FlatFieldError, .tooDark("a"))
        }
        let clipped = [Float](repeating: 1, count: w * h * 4)
        XCTAssertThrowsError(try FlatFieldGainMap.make(cameraRGB: clipped, width: w, height: h, clipLevel: SIMD3(1, 1, 1),
                                                       aspect: 1.33, name: "b")) {
            XCTAssertEqual($0 as? FlatFieldError, .overexposed("b"))
        }
    }

    // MARK: - Where the reference is

    func testRelativePathRoundTrips() {
        let photo = URL(fileURLWithPath: "/Volumes/Shoot/2026/Day 1/DSC_0107.NEF")
        let cases: [(String, String)] = [
            ("/Volumes/Shoot/2026/Day 1/flat.NEF", "flat.NEF"),
            ("/Volumes/Shoot/2026/Flats/flat.NEF", "../Flats/flat.NEF"),
            ("/Volumes/Shoot/2026/Day 1/Flats/f.dng", "Flats/f.dng"),
        ]
        for (reference, relative) in cases {
            let ref = URL(fileURLWithPath: reference)
            XCTAssertEqual(FlatFieldCorrection.relativePath(from: photo, to: ref), relative)
            let correction = FlatFieldCorrection(reference: relative, hash: "sha256:00")
            XCTAssertEqual(correction.referenceURL(forPhoto: photo).path, reference)
        }
        // Nothing shared but the root: kept absolute.
        let other = URL(fileURLWithPath: "/tmp/flat.NEF")
        XCTAssertEqual(FlatFieldCorrection.relativePath(from: photo, to: other), "/tmp/flat.NEF")
        XCTAssertEqual(FlatFieldCorrection(reference: "/tmp/flat.NEF", hash: "sha256:00")
            .referenceURL(forPhoto: photo).path, "/tmp/flat.NEF")
    }

    func testHashNamesTheBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flat-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try FlatFieldCorrection.hash(ofFileAt: url),
                       "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - The stored module

    /// No correction, no key: an edit that never used it encodes exactly as
    /// before. With one, it round-trips, and a hand-edited amount is clamped.
    func testStackRoundTripAndNeutralEncoding() throws {
        let plain = try EditStack(parameters: EditParameters()).encodeJSON()
        XCTAssertFalse(plain.contains("flatfield"))

        var p = EditParameters()
        p.flatField = FlatFieldCorrection(reference: "../Flats/flat.NEF", hash: "sha256:abcd", amount: 0.6)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"flatfield\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.flatField, p.flatField)
        XCTAssertNotEqual(back, EditParameters(), "it counts as an edit")

        let wild = json.replacingOccurrences(of: "\"amount\":0.6", with: "\"amount\":7")
        XCTAssertEqual(try EditStack.decode(json: wild).parameters().flatField?.amount, 1)
        let nameless = json.replacingOccurrences(of: "sha256:abcd", with: "md5:abcd")
        XCTAssertNil(try EditStack.decode(json: nameless).parameters().flatField, "a hash that names no file")
    }

    /// Copy and paste never carry it (it names a file beside the photo);
    /// a paste leaves the target's own alone.
    func testCopyPasteLeavesItAlone() {
        var own = EditParameters()
        own.flatField = FlatFieldCorrection(reference: "flat.NEF", hash: "sha256:01")
        var other = EditParameters()
        other.flatField = FlatFieldCorrection(reference: "other.NEF", hash: "sha256:02")
        let merged = EditStack(parameters: own).merged(with: EditStack(parameters: other),
                                                      groups: Set(EditGroup.allCases))
        XCTAssertEqual(merged.modules.flatfield?.hash, "sha256:01")
        XCTAssertNil(EditStack(parameters: other).restricted(to: Set(EditGroup.allCases)).modules.flatfield)
    }

    func testCacheKeepsMapsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flatfield-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let map = FlatFieldGainMap(width: 2, height: 2, gains: Array(repeating: 1.5, count: 12), aspect: 1.5)
        FlatFieldCache(directory: dir).store(map, for: "sha256:feed")
        XCTAssertEqual(FlatFieldCache(directory: dir).gainMap(for: "sha256:feed"), map, "a new process reads it back")
        XCTAssertNil(FlatFieldCache(directory: dir).gainMap(for: "sha256:beef"))
    }

    // MARK: - On the GPU

    private func open() throws -> (ImageSession, RenderPipeline, GPUContext) {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        return (session, RenderPipeline(gpu: gpu), gpu)
    }

    private func render(_ session: ImageSession, _ pipeline: RenderPipeline, _ gpu: GPUContext,
                        _ p: EditParameters, scale: RenderScale = .binned(quads: 8))
        throws -> (pixels: [Float16], width: Int, height: Int) {
        let texture = try pipeline.render(session, scale: scale, parameters: p, output: .sceneLinear)
        return (try TextureReadback.float16Pixels(of: texture, gpu: gpu), texture.width, texture.height)
    }

    /// The median ratio of `b`'s green to `a`'s over the columns `xs`.
    private func ratio(_ a: (pixels: [Float16], width: Int, height: Int),
                       _ b: (pixels: [Float16], width: Int, height: Int), xs: Range<Int>) -> Float {
        var ratios: [Float] = []
        for y in 0..<a.height {
            for x in xs {
                let i = (y * a.width + x) * 4 + 1
                let va = Float(a.pixels[i]), vb = Float(b.pixels[i])
                if va > 0.01, va < 0.8 { ratios.append(vb / va) }
            }
        }
        ratios.sort()
        return ratios.isEmpty ? .nan : ratios[ratios.count / 2]
    }

    /// A map darkening the right half by a stop: the left of the render is
    /// untouched, the right halved; Amount mixes towards none; and a
    /// full-resolution region on the right agrees with the preview.
    func testStageAppliesTheMapWhereItLies() throws {
        let (session, pipeline, gpu) = try open()
        let s = session.file.summary
        let hash = "sha256:test-\(UUID().uuidString)"
        var gains = [Float]()
        for _ in 0..<2 { for x in 0..<4 { gains += Array(repeating: x < 2 ? 1 : 0.5, count: 3) } }
        FlatFieldCache.shared.store(FlatFieldGainMap(width: 4, height: 2, gains: gains,
                                                     aspect: Float(s.rawWidth) / Float(s.rawHeight)),
                                    for: hash, persist: false)
        let plain = EditParameters()
        var flat = plain
        flat.flatField = FlatFieldCorrection(reference: "flat.NEF", hash: hash, amount: 1)
        let a = try render(session, pipeline, gpu, plain), b = try render(session, pipeline, gpu, flat)
        let left = 0..<(a.width / 4), right = (a.width * 3 / 4)..<a.width
        XCTAssertEqual(ratio(a, b, xs: left), 1, accuracy: 0.02)
        XCTAssertEqual(ratio(a, b, xs: right), 0.5, accuracy: 0.03)

        var half = flat
        half.flatField?.amount = 0.5
        XCTAssertEqual(ratio(a, try render(session, pipeline, gpu, half), xs: right), 0.75, accuracy: 0.03)

        var off = flat
        off.flatField?.amount = 0
        XCTAssertEqual(try render(session, pipeline, gpu, off).pixels, a.pixels, "Amount 0 skips the stage")

        var unknown = flat
        unknown.flatField?.hash = "sha256:no-map-on-this-mac"
        XCTAssertEqual(try render(session, pipeline, gpu, unknown).pixels, a.pixels, "no map, no stage")

        let region = RenderScale.region(x: s.rawWidth * 7 / 8, y: s.rawHeight / 2, width: 256, height: 256)
        let ra = try render(session, pipeline, gpu, plain, scale: region)
        let rb = try render(session, pipeline, gpu, flat, scale: region)
        XCTAssertEqual(ratio(ra, rb, xs: 0..<ra.width), 0.5, accuracy: 0.03)
    }
}
