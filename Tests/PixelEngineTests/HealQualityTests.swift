import XCTest
import Metal
import simd
@testable import PixelEngine

/// The heal patch on synthetic skin, sky and a horizon, measured against
/// the same scene without the blemish. Runs the real kernels on a small
/// camera-linear texture, and compares them with the rim-ratio heal
/// Latent used before (one colour ratio measured on the two rims),
/// reimplemented on the CPU. Ported from minivu's RetouchHealQualityTests.
final class HealQualityTests: XCTestCase {
    static let width = 384, height = 256

    /// Value noise in about -1...1 with features `cell` pixels across.
    static func noise(_ x: Int, _ y: Int, cell: Double, seed: UInt32) -> Double {
        func hash(_ i: Int, _ j: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263) ^ seed
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Double(h ^ (h >> 16)) / Double(UInt32.max) * 2 - 1
        }
        let fx = Double(x) / cell, fy = Double(y) / cell
        let i = Int(fx.rounded(.down)), j = Int(fy.rounded(.down))
        let tx = fx - Double(i), ty = fy - Double(j)
        let top = hash(i, j) * (1 - tx) + hash(i + 1, j) * tx
        let bottom = hash(i, j + 1) * (1 - tx) + hash(i + 1, j + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    struct Scene: Sendable {
        let name: String
        /// Linear colour of the clean scene.
        let clean: @Sendable (Int, Int) -> SIMD3<Double>
        let blemishCentre: (x: Int, y: Int)
        let blemishRadius: Double
        let blemishTint: SIMD3<Double>
        let sourceCentre: (x: Int, y: Int)
        let brushRadius: Double
    }

    static let skin = Scene(
        name: "skin",
        clean: { x, y in
            // Light from the right, falling off to a third; pores at 3 px.
            let shade = 0.35 + 0.65 * Double(x) / Double(width - 1)
            let pores = 1 + 0.10 * noise(x, y, cell: 3, seed: 7) + 0.04 * noise(x, y, cell: 11, seed: 3)
            return SIMD3(0.55, 0.36, 0.27) * shade * pores
        },
        blemishCentre: (130, 128), blemishRadius: 7, blemishTint: SIMD3(0.7, 0.45, 0.45),
        sourceCentre: (250, 140), brushRadius: 13)

    static let sky = Scene(
        name: "sky",
        clean: { x, y in
            // Brightening ever faster towards the horizon, past 1 (an HDR
            // sunset), with a little grain.
            let level = 0.3 + 1.4 * pow(Double(y) / Double(height - 1), 2.5)
            let grain = 1 + 0.02 * noise(x, y, cell: 2, seed: 11)
            return SIMD3(0.12, 0.28, 0.75) * level * grain
        },
        blemishCentre: (200, 190), blemishRadius: 8, blemishTint: SIMD3(0.45, 0.45, 0.5),
        sourceCentre: (110, 120), brushRadius: 14)

    static let edge = Scene(
        name: "edge",
        clean: { x, y in
            // A soft horizon: bright sky over a dark hillside, meeting across
            // the blemish; the source is plain mid-tone ground with grain.
            let t = smoothstep(118, 138, Double(y))
            let sky = SIMD3(0.5, 0.6, 0.8), hill = SIMD3(0.08, 0.1, 0.06)
            let clean = sky * (1 - t) + hill * t
            let ground = SIMD3(0.25, 0.22, 0.18)
            let grain = 1 + 0.06 * noise(x, y, cell: 2, seed: 5)
            return (x < 200 && y > 180 ? ground : clean) * grain
        },
        blemishCentre: (260, 128), blemishRadius: 8, blemishTint: SIMD3(0.5, 0.5, 0.5),
        sourceCentre: (100, 220), brushRadius: 14)

    static func blemished(_ scene: Scene, _ x: Int, _ y: Int) -> SIMD3<Double> {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        let dx = Double(x - scene.blemishCentre.x), dy = Double(y - scene.blemishCentre.y)
        let d = (dx * dx + dy * dy).squareRoot()
        // A soft-edged spot.
        let w = 1 - smoothstep(scene.blemishRadius - 1.5, scene.blemishRadius + 0.5, d)
        let c = scene.clean(x, y)
        return c * (SIMD3(repeating: 1) - w * (SIMD3(repeating: 1) - scene.blemishTint))
    }

    static func patch(_ scene: Scene, mode: HealPatch.Mode = .heal) -> HealPatch {
        let size = SIMD2<Float>(Float(width), Float(height))
        // Pixel centres, so the circle sits where the CPU reference puts it.
        return HealPatch(target: (SIMD2(Float(scene.blemishCentre.x), Float(scene.blemishCentre.y)) + 0.5) / size,
                         source: (SIMD2(Float(scene.sourceCentre.x), Float(scene.sourceCentre.y)) + 0.5) / size,
                         radius: Float(scene.brushRadius) / Float(min(width, height)), feather: 0.35, mode: mode)
    }

    /// The previous heal (Heal.metal before the ratio field): the source
    /// scaled by the ratio of the two rims' means (ring 0.7r...r),
    /// feathered over the outer 35%.
    static func rimRatio(_ scene: Scene) -> (Int, Int) -> SIMD3<Double> {
        let r = scene.brushRadius
        let offset = (x: scene.sourceCentre.x - scene.blemishCentre.x, y: scene.sourceCentre.y - scene.blemishCentre.y)
        var target = SIMD3<Double>(), source = SIMD3<Double>(), n = 0.0
        for dy in -Int(r)...Int(r) {
            for dx in -Int(r)...Int(r) {
                let d = Double(dx * dx + dy * dy).squareRoot()
                guard d >= 0.7 * r, d <= r else { continue }
                target += blemished(scene, scene.blemishCentre.x + dx, scene.blemishCentre.y + dy)
                source += blemished(scene, scene.sourceCentre.x + dx, scene.sourceCentre.y + dy)
                n += 1
            }
        }
        let ratio = simd_clamp(target / simd_max(source, SIMD3(repeating: 1e-4)), SIMD3(repeating: 0.25),
                               SIMD3(repeating: 4))
        return { x, y in
            let dx = Double(x - scene.blemishCentre.x), dy = Double(y - scene.blemishCentre.y)
            let d = (dx * dx + dy * dy).squareRoot()
            let c = blemished(scene, x, y)
            guard d < r else { return c }
            let v = blemished(scene, x + offset.x, y + offset.y) * ratio
            let w = 1 - smoothstep(0.65 * r, r, d)
            return c + (v - c) * w
        }
    }

    struct Score: CustomStringConvertible {
        /// Root mean square error inside the brush, sRGB-encoded 0...255
        /// units. Every heal copies the same source texture, so this
        /// includes the unavoidable difference between two patches of pores.
        let rms: Double
        /// The worst error of the 7 x 7 average around any point of the
        /// brush: a tone or colour mismatch, the blotch or seam the eye
        /// notices, with the texture averaged out.
        let tone: Double
        var description: String { String(format: "rms %.2f, tone %.2f", rms, tone) }
    }

    static func encode(_ c: Double) -> Double {
        let a = abs(c)
        let e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return (c < 0 ? -e : e) * 255
    }

    static func score(_ scene: Scene, result: (Int, Int) -> SIMD3<Double>) -> Score {
        func encoded(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(encode(c.x), encode(c.y), encode(c.z)) }
        let r = scene.brushRadius
        var sum = 0.0, n = 0.0, tone = 0.0
        let reach = Int(r) + 1
        for dy in -reach...reach {
            for dx in -reach...reach {
                let x = scene.blemishCentre.x + dx, y = scene.blemishCentre.y + dy
                guard Double(dx * dx + dy * dy).squareRoot() <= r else { continue }
                let e = encoded(result(x, y)) - encoded(scene.clean(x, y))
                sum += simd_length_squared(e) / 3
                n += 1
                var local = SIMD3<Double>()
                for oy in -3...3 { for ox in -3...3 {
                    local += encoded(result(x + ox, y + oy)) - encoded(scene.clean(x + ox, y + oy))
                } }
                tone = max(tone, simd_reduce_max(simd_abs(local / 49)))
            }
        }
        return Score(rms: (sum / n).squareRoot(), tone: tone)
    }

    /// A camera-linear texture of `pixel`, for the heal stage to read.
    static func texture(width w: Int, height h: Int, gpu: GPUContext,
                        _ pixel: (Int, Int) -> SIMD3<Double>) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let tex = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        var px = [Float16](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = pixel(x, y), i = (y * w + x) * 4
                px[i] = Float16(c.x); px[i + 1] = Float16(c.y); px[i + 2] = Float16(c.z)
            }
        }
        px.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8)
        }
        return tex
    }

    /// Runs the heal stage over `input` as RenderPipeline does, and reads
    /// the result back as a pixel lookup that repeats the edge.
    static func healed(_ input: MTLTexture, patches: [HealPatch], sensorSize: SIMD2<Float>,
                       tileOrigin: SIMD2<Float> = .zero, binSpan: Float = 1,
                       gpu: GPUContext) throws -> (Int, Int) -> SIMD3<Double> {
        let output = try XCTUnwrap(gpu.makePrivateTexture(width: input.width, height: input.height,
                                                          pixelFormat: .rgba16Float))
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        try HealStage.encode(patches: patches, input: input, output: output, sensorSize: sensorSize,
                             tileOrigin: tileOrigin, binSpan: binSpan, gpu: gpu, commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertNotEqual(cmd.status, .error)
        let px = try TextureReadback.float16Pixels(of: output, gpu: gpu)
        let w = input.width, h = input.height
        return { x, y in
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
            return SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
        }
    }

    /// On an evenly lit area the ratio field and the rim ratio are about
    /// equally good; where the light or colour changes across the patch,
    /// one ratio for the whole patch can't be right on both sides, and
    /// the ratio field is several times better.
    func testRatioFieldMatchesOrBeatsTheRimRatio() throws {
        let gpu = try GPUContext()
        let size = SIMD2<Float>(Float(Self.width), Float(Self.height))
        for scene in [Self.skin, Self.sky, Self.edge] {
            let input = try Self.texture(width: Self.width, height: Self.height, gpu: gpu) { Self.blemished(scene, $0, $1) }
            let ours = Self.score(scene, result: try Self.healed(input, patches: [Self.patch(scene)], sensorSize: size, gpu: gpu))
            let untouched = Self.score(scene) { Self.blemished(scene, $0, $1) }
            let rim = Self.score(scene, result: Self.rimRatio(scene))
            print("heal quality \(scene.name): blemished \(untouched); ratio field \(ours); rim ratio \(rim)")
            XCTAssertLessThan(ours.rms, untouched.rms / 2, scene.name)
            XCTAssertLessThan(ours.rms, rim.rms * 1.1, "\(scene.name): \(ours) vs rim ratio \(rim)")
            XCTAssertLessThan(ours.tone, rim.tone * 1.1, "\(scene.name): \(ours) vs rim ratio \(rim)")
            if scene.name == "edge" {
                XCTAssertLessThan(ours.tone, rim.tone / 3, "\(scene.name): \(ours) vs rim ratio \(rim)")
            }
        }
    }

    /// Patches apply in order: a clone whose source is an earlier patch's
    /// target copies what that patch put there, not the blemish under it.
    func testLaterPatchReadsEarlierPatch() throws {
        let gpu = try GPUContext()
        let w = 96, h = 64
        let size = SIMD2<Float>(Float(w), Float(h))
        // Three flat squares: red where the first clone reads, green where
        // it writes, blue where the second clone writes.
        let input = try Self.texture(width: w, height: h, gpu: gpu) { x, _ in
            x < 32 ? SIMD3(0.6, 0.1, 0.1) : x < 64 ? SIMD3(0.1, 0.6, 0.1) : SIMD3(0.1, 0.1, 0.6)
        }
        let first = HealPatch(target: SIMD2(48, 32) / size, source: SIMD2(16, 32) / size,
                              radius: 10 / 64, feather: 0, mode: .clone)
        let second = HealPatch(target: SIMD2(80, 32) / size, source: SIMD2(48, 32) / size,
                               radius: 5 / 64, feather: 0, mode: .clone)
        let out = try Self.healed(input, patches: [first, second], sensorSize: size, gpu: gpu)
        XCTAssertEqual(out(48, 32).x, 0.6, accuracy: 1e-3, "first patch copies red")
        XCTAssertEqual(out(80, 32).x, 0.6, accuracy: 1e-3, "second patch copies the first patch's red")
        XCTAssertEqual(out(90, 10).z, 0.6, accuracy: 1e-3, "outside both patches untouched")
    }

    /// A tile grown only for the patches that can change the view heals
    /// the view exactly as the whole frame does, although a later patch
    /// that reads outside it lands in the tile, and so does a heal at the
    /// sensor edge whose reach was cut at the edge.
    func testTileLeavingOutLaterPatchesMatchesFullResolution() throws {
        let gpu = try GPUContext()
        let w = 256, h = 128
        let size = SIMD2<Float>(Float(w), Float(h)), sensor = CGSize(width: w, height: h)
        let gradient: (Int, Int) -> SIMD3<Double> = { x, y in SIMD3(Double(x) / 256, 0.2 + Double(y) / 512, 0.3) }
        let cases: [[HealPatch]] = [
            // The second clone writes where the first reads, after it has read.
            [HealPatch(target: SIMD2(40, 64) / size, source: SIMD2(100, 64) / size, radius: 10 / 128, feather: 0, mode: .clone),
             HealPatch(target: SIMD2(104, 64) / size, source: SIMD2(220, 64) / size, radius: 10 / 128, feather: 0, mode: .clone)],
            // A heal whose surroundings run off the left edge.
            [HealPatch(target: SIMD2(14, 64) / size, source: SIMD2(60, 64) / size, radius: 12 / 128, mode: .heal)],
        ]
        for patches in cases {
            let full = try Self.healed(try Self.texture(width: w, height: h, gpu: gpu, gradient),
                                       patches: patches, sensorSize: size, gpu: gpu)
            let visible = patches[0].targetBounds(sensorSize: sensor).insetBy(dx: 2, dy: 2)
            let grown = HealPatch.regionIncludingSources(visible, patches: patches, sensorSize: sensor)
            XCTAssertGreaterThanOrEqual(grown.minX, 0)
            XCTAssertLessThan(grown.maxX, 200, "the second clone's source isn't needed")
            let tx = Int(grown.minX.rounded(.down)), ty = Int(grown.minY.rounded(.down))
            let tw = Int(grown.maxX.rounded(.up)) - tx, th = Int(grown.maxY.rounded(.up)) - ty
            let tile = try Self.healed(try Self.texture(width: tw, height: th, gpu: gpu) { gradient($0 + tx, $1 + ty) },
                                       patches: patches, sensorSize: size, tileOrigin: SIMD2(Float(tx), Float(ty)), gpu: gpu)
            var worst = 0.0
            for y in Int(visible.minY)..<Int(visible.maxY) {
                for x in Int(visible.minX)..<Int(visible.maxX) {
                    worst = max(worst, simd_reduce_max(simd_abs(tile(x - tx, y - ty) - full(x, y))))
                }
            }
            XCTAssertLessThan(worst, 1e-3, "tile agrees with the whole frame over the view (\(patches.count) patches)")
        }
    }

    /// A tile grown by `regionIncludingSources` heals exactly as the whole
    /// frame does, and a 2 x 2 binned render matches the full-resolution
    /// heal averaged down, so the preview predicts the export.
    func testTileAndBinnedRendersMatchFullResolution() throws {
        let gpu = try GPUContext()
        let scene = Self.edge
        let w = Self.width, h = Self.height
        let size = SIMD2<Float>(Float(w), Float(h))
        let patch = Self.patch(scene)
        let full = try Self.healed(try Self.texture(width: w, height: h, gpu: gpu) { Self.blemished(scene, $0, $1) },
                                   patches: [patch], sensorSize: size, gpu: gpu)

        // A tile that only just covers the patch's target, grown for the heal.
        let visible = patch.targetBounds(sensorSize: CGSize(width: w, height: h)).insetBy(dx: 4, dy: 4)
        let grown = HealPatch.regionIncludingSources(visible, patches: [patch], sensorSize: CGSize(width: w, height: h))
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        XCTAssertTrue(grown.contains(patch.sourceBounds(sensorSize: CGSize(width: w, height: h))))
        let tx = Int(grown.minX.rounded(.down)), ty = Int(grown.minY.rounded(.down))
        let tw = Int(grown.maxX.rounded(.up)) - tx, th = Int(grown.maxY.rounded(.up)) - ty
        let tile = try Self.healed(try Self.texture(width: tw, height: th, gpu: gpu) { Self.blemished(scene, $0 + tx, $1 + ty) },
                                   patches: [patch], sensorSize: size, tileOrigin: SIMD2(Float(tx), Float(ty)), gpu: gpu)
        var worstTile = 0.0
        for y in Int(visible.minY)..<Int(visible.maxY) {
            for x in Int(visible.minX)..<Int(visible.maxX) {
                worstTile = max(worstTile, simd_reduce_max(simd_abs(tile(x - tx, y - ty) - full(x, y))))
            }
        }
        XCTAssertLessThan(worstTile, 1e-3, "tile agrees with the whole frame")

        let binned = try Self.healed(try Self.texture(width: w / 2, height: h / 2, gpu: gpu) { x, y in
            (Self.blemished(scene, 2 * x, 2 * y) + Self.blemished(scene, 2 * x + 1, 2 * y)
             + Self.blemished(scene, 2 * x, 2 * y + 1) + Self.blemished(scene, 2 * x + 1, 2 * y + 1)) / 4
        }, patches: [patch], sensorSize: size, binSpan: 2, gpu: gpu)
        var sum = 0.0, n = 0.0
        let r = Int(scene.brushRadius) / 2
        for dy in -r...r {
            for dx in -r...r {
                let x = scene.blemishCentre.x / 2 + dx, y = scene.blemishCentre.y / 2 + dy
                let down = (full(2 * x, 2 * y) + full(2 * x + 1, 2 * y) + full(2 * x, 2 * y + 1) + full(2 * x + 1, 2 * y + 1)) / 4
                let e = binned(x, y) - down
                sum += simd_reduce_max(simd_abs(SIMD3(Self.encode(e.x + down.x) - Self.encode(down.x),
                                                      Self.encode(e.y + down.y) - Self.encode(down.y),
                                                      Self.encode(e.z + down.z) - Self.encode(down.z))))
                n += 1
            }
        }
        print("heal binned vs full: mean worst-channel difference \(sum / n) (0...255 encoded)")
        XCTAssertLessThan(sum / n, 3, "binned heal predicts the full-resolution one")
    }
}
