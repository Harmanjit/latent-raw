import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

/// RCD at the frame edge: the kernels run on synthetic CFA frames through
/// `RenderPipeline.encodeRCD`, and the sample NEF checks the same at full
/// resolution and through a perspective-corrected render.
final class DemosaicBorderTests: XCTestCase {
    /// LibRaw `filters` low bytes for the four Bayer orders, each with the
    /// second green as 1 and as 3.
    static let orders: [(String, UInt8)] = [
        ("RGGB", 0x94), ("RGGB/G2", 0xB4), ("BGGR", 0x16), ("BGGR/G2", 0x36),
        ("GRBG", 0x61), ("GRBG/G2", 0xE1), ("GBRG", 0x49), ("GBRG/G2", 0xC9),
    ]

    /// The RGB channel of photosite (x, y), second green folded onto green.
    static func colour(_ order: UInt8, _ x: Int, _ y: Int) -> Int {
        let c = Int(order >> (UInt8(((y & 1) << 1) | (x & 1)) * 2)) & 3
        return c == 3 ? 1 : c
    }

    static func cfaTexture(_ values: [Float], width: Int, height: Int, gpu: GPUContext) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height,
                                                         mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        let tex = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        values.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return tex
    }

    enum Method { case rcd, bilinear }

    /// Demosaics a CFA frame with the pipeline's own passes.
    static func demosaic(_ values: [Float], width: Int, height: Int, order: UInt8, method: Method,
                         gpu: GPUContext) throws -> [Float16] {
        let pipeline = RenderPipeline(gpu: gpu)
        let cfa = try cfaTexture(values, width: width, height: height, gpu: gpu)
        let cmd = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        func make(_ format: MTLPixelFormat) throws -> MTLTexture {
            try XCTUnwrap(gpu.makePrivateTexture(width: width, height: height, pixelFormat: format))
        }
        let out: MTLTexture
        switch method {
        case .rcd: out = try pipeline.encodeRCD(cmdBuffer: cmd, cfa: cfa, order: order) { f, _ in try make(f) }
        case .bilinear: out = try pipeline.encodeBilinear(cmdBuffer: cmd, cfa: cfa, order: order,
                                                           output: try make(.rgba16Float))
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return try TextureReadback.float16Pixels(of: out, gpu: gpu)
    }

    /// A flat colour field, every CFA order, even and odd frame sizes: RCD
    /// must hand back that colour at every pixel, the outermost rows,
    /// columns and corners included. Clamped neighbourhood reads used to
    /// leave one channel of the edge pixel at about half (blue along the
    /// top and left, red along the bottom and right for RGGB).
    func testFlatFrameKeepsItsColourToTheEdge() throws {
        let gpu = try GPUContext()
        let colour: [Float] = [0.3, 0.5, 0.2]
        for (name, order) in Self.orders {
            for (w, h) in [(64, 48), (63, 47), (6, 5)] {
                var cfa = [Float](repeating: 0, count: w * h)
                for y in 0..<h { for x in 0..<w { cfa[y * w + x] = colour[Self.colour(order, x, y)] } }
                for method in [Method.rcd, .bilinear] {
                    let px = try Self.demosaic(cfa, width: w, height: h, order: order, method: method, gpu: gpu)
                    // Per channel, the mean over each side's outermost line
                    // and each corner, against the frame's centre pixel.
                    let centre = (h / 2 * w + w / 2) * 4
                    let regions: [(String, [(Int, Int)])] = [
                        ("top", (0..<w).map { ($0, 0) }), ("bottom", (0..<w).map { ($0, h - 1) }),
                        ("left", (0..<h).map { (0, $0) }), ("right", (0..<h).map { (w - 1, $0) }),
                        ("second row from bottom", (0..<w).map { ($0, h - 2) }),
                        ("corners", [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]),
                    ]
                    for (region, points) in regions {
                        for c in 0..<3 {
                            let mean = points.map { Float(px[($0.1 * w + $0.0) * 4 + c]) }.reduce(0, +)
                                / Float(points.count)
                            XCTAssertEqual(Float(px[centre + c]), colour[c], accuracy: 1e-3,
                                           "\(method) \(name) \(w)x\(h) centre channel \(c)")
                            XCTAssertEqual(mean / Float(px[centre + c]), 1, accuracy: 1e-3,
                                           "\(method) \(name) \(w)x\(h) \(region) channel \(c)")
                        }
                    }
                }
            }
        }
    }

    /// What the edge handling is: RCD of the frame extended by its own
    /// mirror image about the edge photosites. Demosaicing the frame must
    /// match demosaicing an explicitly mirrored, larger frame and cropping
    /// it back, at every pixel including the edges, on a noise frame
    /// where every directional decision matters. This pins the diagonal
    /// statistics' swap under a one-axis mirror as well as the reads.
    func testEdgesAreRCDOfTheMirroredFrame() throws {
        let gpu = try GPUContext()
        let w = 40, h = 30, pad = 16
        let order: UInt8 = 0x94
        let frame = Self.noiseFrame(width: w, height: h, order: order)
        let pw = w + 2 * pad, ph = h + 2 * pad
        func mirror(_ i: Int, _ n: Int) -> Int { i < 0 ? -i : (i >= n ? 2 * (n - 1) - i : i) }
        var padded = [Float](repeating: 0, count: pw * ph)
        for y in 0..<ph { for x in 0..<pw {
            padded[y * pw + x] = frame[mirror(y - pad, h) * w + mirror(x - pad, w)]
        } }
        let direct = try Self.demosaic(frame, width: w, height: h, order: order, method: .rcd, gpu: gpu)
        let viaPadding = try Self.demosaic(padded, width: pw, height: ph, order: order, method: .rcd, gpu: gpu)
        var worst: (diff: Float, x: Int, y: Int) = (0, 0, 0)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            let d = abs(Float(direct[(y * w + x) * 4 + c]) - Float(viaPadding[((y + pad) * pw + x + pad) * 4 + c]))
            if d > worst.diff { worst = (d, x, y) }
        } } }
        XCTAssertLessThan(worst.diff, 1e-3, "differs from the mirrored frame's RCD at (\(worst.x), \(worst.y))")
    }

    /// The edge handling reaches no further in than RCD's own reach: a crop
    /// demosaiced on its own is bit-identical to the same pixels of the
    /// whole frame from `reach` pixels in. So the interior of every render
    /// is exactly what it was before the edges were fixed.
    func testEdgeHandlingStaysWithinRCDsReach() throws {
        let gpu = try GPUContext()
        let w = 96, h = 80, reach = 11
        let order: UInt8 = 0x94
        let frame = Self.noiseFrame(width: w, height: h, order: order)
        // An even origin keeps the crop's CFA order.
        let (cx, cy, cw, ch) = (14, 12, 60, 50)
        var crop = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch { for x in 0..<cw { crop[y * cw + x] = frame[(y + cy) * w + x + cx] } }
        let whole = try Self.demosaic(frame, width: w, height: h, order: order, method: .rcd, gpu: gpu)
        let part = try Self.demosaic(crop, width: cw, height: ch, order: order, method: .rcd, gpu: gpu)
        var deepest = -1
        for y in 0..<ch { for x in 0..<cw {
            let a = (y * cw + x) * 4, b = ((y + cy) * w + x + cx) * 4
            if (0..<3).contains(where: { part[a + $0] != whole[b + $0] }) {
                deepest = max(deepest, min(x, y, cw - 1 - x, ch - 1 - y))
            }
        } }
        XCTAssertLessThan(deepest, reach, "a crop differs from the whole frame \(deepest) px in")
    }

    /// A CFA frame of the three channels' own value noise, so the
    /// directional decisions vary from pixel to pixel.
    static func noiseFrame(width w: Int, height h: Int, order: UInt8) -> [Float] {
        var seed: UInt32 = 12345
        var frame = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = Float(seed >> 8) / Float(1 << 24)
            let base: Float = [0.4, 0.6, 0.3][Self.colour(order, x, y)]
            frame[y * w + x] = base * (0.5 + n)
        } }
        return frame
    }

    /// The sample NEF at full resolution: the outermost two rows and
    /// columns carry the same colour through RCD as through the bilinear
    /// demosaic, which only ever averages photosites inside the frame.
    func testSensorEdgesMatchBilinearColour() throws {
        let path = TestAssets.path("HSB_6548.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance
        func camera(_ method: DemosaicMethod) throws -> (px: [Float16], w: Int, h: Int) {
            parameters.demosaic = method
            let tex = try pipeline.renderCameraRGB(session, scale: .full, parameters: parameters)
            return (try TextureReadback.float16Pixels(of: tex, gpu: gpu), tex.width, tex.height)
        }
        let rcd = try camera(.rcd), bilinear = try camera(.bilinear)
        let w = rcd.w, h = rcd.h
        let lines: [(String, [(Int, Int)])] = [0, 1].flatMap { d in [
            ("top+\(d)", (0..<w).map { ($0, d) }), ("bottom-\(d)", (0..<w).map { ($0, h - 1 - d) }),
            ("left+\(d)", (0..<h).map { (d, $0) }), ("right-\(d)", (0..<h).map { (w - 1 - d, $0) }),
        ] }
        for (name, points) in lines {
            let ratios = (0..<3).map { c -> Double in
                let a = points.reduce(0.0) { $0 + Double(rcd.px[($1.1 * w + $1.0) * 4 + c]) }
                let b = points.reduce(0.0) { $0 + Double(bilinear.px[($1.1 * w + $1.0) * 4 + c]) }
                return a / b
            }
            for (c, r) in ratios.enumerated() {
                XCTAssertEqual(r, 1, accuracy: 0.02, "\(name) channel \(c): RCD/bilinear \(r)")
            }
        }
    }

    /// HSB_6548.NEF with the user's edit (vertical perspective -0.16, lens
    /// profile), rendered at full resolution as for export. The perspective
    /// stage fills what it pulls in from outside the sensor by repeating
    /// the edge pixel, so the top band and the wedges down the upper left
    /// and right are the sensor's outermost row and columns stretched. With
    /// RCD's edge pixel short of one channel they came out yellow-green
    /// along the top, green on the left and cyan on the right over a blue
    /// sky. Their chromaticity must match the sky just inside the frame.
    func testPerspectiveFillKeepsTheEdgeColour() throws {
        let path = TestAssets.path("HSB_6548.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let json = #"""
        {"modules":{"curve":{"points":[[0,0],[1,1]]},"demosaic":{"method":"rcd"},"denoise":{"color":0,"luminance":0},"exposure":{"ev":0.52461964},"highlights":{"strength":1,"threshold":0.85},"hsl":{"hue":[0,0,0,0,0,0,0,0],"luminance":[0,0,0,0,0,0,0,0],"saturation":[-0.6845703,0,0,0,0,0,0,0]},"lens":{"distortion":true,"lensfunDb":"2026-09-11","manualDistortion":0,"manualVignetting":0,"profile":"Nikkor AF-S 50mm f\/1.4G","tca":true,"vignetting":true},"perspective":{"horizontal":0,"vertical":-0.1632744},"presence":{"clarity":-0.005859375,"dehaze":0.05910766,"texture":-0.22327304},"sharpen":{"amount":0,"radius":1,"threshold":0.01},"splittoning":{"balance":0,"highlightHue":45,"highlightSaturation":0,"shadowHue":215,"shadowSaturation":0},"tone":{"contrast":1.3529111,"grey":0.19962643,"method":"sigmoid"},"vibrance":{"amount":0.16618693},"whitebalance":{"mode":"custom","temperature":9442.879,"tint":-3.695066}},"process":"1.0","schema":1}
        """#
        let edit = try EditStack.decode(json: json).parameters()
        XCTAssertFalse(edit.perspective.isIdentity)
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        try XCTSkipUnless(session.lensCorrection != nil, "lens profile not in this Lensfun database")
        let pipeline = RenderPipeline(gpu: gpu)
        let tex = try pipeline.render(session, scale: .full, parameters: edit)
        let px = try TextureReadback.float16Pixels(of: tex, gpu: gpu)
        let w = tex.width, h = tex.height

        // Mean chromaticity (each channel's share of the sum) over a band.
        func chroma(_ xs: Range<Int>, _ ys: Range<Int>) -> [Double] {
            var sum = [Double](repeating: 0, count: 3)
            for y in ys { for x in xs { for c in 0..<3 { sum[c] += Double(px[(y * w + x) * 4 + c]) } } }
            let total = sum.reduce(0, +)
            return sum.map { $0 / total }
        }
        // Fractions of the frame, read off the render: the fill runs about
        // 3.5% down the top, and 3% into each side at the top, narrowing
        // to nothing by 45% of the way down.
        func xr(_ a: Double, _ b: Double) -> Range<Int> { Int(a * Double(w))..<Int(b * Double(w)) }
        func yr(_ a: Double, _ b: Double) -> Range<Int> { Int(a * Double(h))..<Int(b * Double(h)) }
        let checks: [(String, fill: [Double], sky: [Double])] = [
            ("top", chroma(xr(0.1, 0.9), yr(0, 0.02)), chroma(xr(0.1, 0.9), yr(0.05, 0.08))),
            ("left", chroma(xr(0, 0.006), yr(0.05, 0.2)), chroma(xr(0.04, 0.07), yr(0.05, 0.2))),
            ("right", chroma(xr(0.994, 1), yr(0.05, 0.15)), chroma(xr(0.93, 0.96), yr(0.05, 0.15))),
        ]
        for (name, fill, sky) in checks {
            let d = zip(fill, sky).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(d, 0.02, "\(name) fill chromaticity \(fill) against the sky's \(sky)")
        }
    }
}
