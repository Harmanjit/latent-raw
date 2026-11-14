import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// The viewing overlays the present pass draws (PresentOverlays.swift):
/// the clipping overlay's options, focus peaking and raw clipping, and the
/// high-quality preview's sizing. All view-only: the defaults draw what
/// the presenter always drew.
final class ViewingOverlayTests: XCTestCase {

    // MARK: - Clipping options

    /// The standard options are the overlay as it was: the same pixels
    /// whether they are passed or left out, red at the top, blue at black.
    func testStandardOptionsDrawTheClassicOverlay() throws {
        let gpu = try GPUContext()
        let pixels: [Float] = [1, 0.4, 0.2,  0.5, 0.5, 0.5,  0, 0, 0,  0.001, 0, 0]
        let plain = try present(gpu, pixels, width: 4, clipping: .both)
        let standard = try present(gpu, pixels, width: 4, clipping: .both, overlays: PresentOverlays(clipping: .standard))
        XCTAssertEqual(plain, standard)
        XCTAssertEqual(Array(plain[0..<3]), [1, 0, 0])
        XCTAssertEqual(plain[8], 1, "black: blue")
        XCTAssertEqual(Array(plain[3..<6]), [0.5, 0.5, 0.5])
        XCTAssertEqual(ClippingOptions.standard.highlightLinear, 0.9955)
        XCTAssertEqual(ClippingOptions.standard.shadowLinear, 0.000152)
    }

    func testModesThresholdsAndSchemes() throws {
        let gpu = try GPUContext()
        // A pure red at the top, a near-white just under it, a dark grey.
        let pixels: [Float] = [1, 0, 0,  0.92, 0.92, 0.92,  0.002, 0.002, 0.002]

        let any = try present(gpu, pixels, width: 3, clipping: .highlights)
        XCTAssertEqual(Array(any[0..<3]), [1, 0, 0], "any channel: the red is clipped")
        XCTAssertEqual(Array(any[3..<6]), pixels[3..<6].map { Float(Float16($0)) }, "0.92 is under the line")

        let luminance = ClippingOptions(mode: .luminance)
        let byLuminance = try present(gpu, pixels, width: 3, clipping: .both,
                                      overlays: PresentOverlays(clipping: luminance))
        XCTAssertEqual(byLuminance[0], 1, "red's luminance is far from white: left alone")
        XCTAssertEqual(byLuminance[1], 0)

        let lower = ClippingOptions(shadowThreshold: 0.05, highlightThreshold: 0.95, scheme: .magentaCyan)
        let lowered = try present(gpu, pixels, width: 3, clipping: .both, overlays: PresentOverlays(clipping: lower))
        XCTAssertEqual(Array(lowered[3..<6]), [1, 0, 1], "95%: the near-white turns magenta")
        XCTAssertEqual(Array(lowered[6..<9]), [0, 1, 1], "5%: the dark grey turns cyan")

        let mono = try present(gpu, pixels, width: 3, clipping: .highlights,
                               overlays: PresentOverlays(clipping: ClippingOptions(scheme: .mono)))
        XCTAssertEqual(Array(mono[0..<3]), [0, 0, 0], "mono marks highlights black")

        let saturation = try present(gpu, pixels, width: 3, clipping: .highlights,
                                     overlays: PresentOverlays(clipping: ClippingOptions(mode: .saturation, highlightThreshold: 0.95,
                                                                                         scheme: .magentaCyan)))
        XCTAssertEqual(Array(saturation[0..<3]), [1, 0, 1], "a saturated channel at the top")
        XCTAssertEqual(Array(saturation[3..<6]), pixels[3..<6].map { Float(Float16($0)) }, "a near-white isn't saturated")
    }

    func testOptionsClampAndRoundTrip() throws {
        let wild = ClippingOptions(shadowThreshold: 0.5, highlightThreshold: 0.2)
        XCTAssertEqual(wild.shadowThreshold, 0.05)
        XCTAssertEqual(wild.highlightThreshold, 0.95)
        let data = try JSONEncoder().encode(ClippingOptions(mode: .saturation, scheme: .mono))
        XCTAssertEqual(try JSONDecoder().decode(ClippingOptions.self, from: data), ClippingOptions(mode: .saturation, scheme: .mono))
        XCTAssertLessThan(ClippingOptions(highlightThreshold: 0.95).highlightLinear, 0.9955)
        XCTAssertGreaterThan(ClippingOptions(shadowThreshold: 0.02).shadowLinear, 0.000152)
    }

    // MARK: - Focus peaking

    /// A hard edge is marked in the peaking colour; flat areas either side
    /// are untouched; off, nothing changes.
    func testFocusPeakingMarksEdgesOnly() throws {
        let gpu = try GPUContext()
        let width = 8
        var pixels: [Float] = []
        for _ in 0..<width { for x in 0..<width { let v: Float = x < 4 ? 0.05 : 0.9; pixels += [v, v, v] } }
        let peaking = PresentFocusPeaking(colour: SIMD3(0, 1, 0), sensitivity: .medium)
        let off = try present(gpu, pixels, width: width, height: width)
        XCTAssertEqual(off, pixels.map { Float(Float16($0)) })
        let on = try present(gpu, pixels, width: width, height: width, overlays: PresentOverlays(focusPeaking: peaking))
        func pixel(_ x: Int, _ y: Int) -> [Float] { Array(on[(y * width + x) * 3 ..< (y * width + x) * 3 + 3]) }
        XCTAssertEqual(pixel(3, 4), [0, 1, 0], "beside the edge: green")
        XCTAssertEqual(pixel(4, 4), [0, 1, 0])
        XCTAssertEqual(pixel(0, 4), off[(4 * width) * 3 ..< (4 * width) * 3 + 3].map { $0 }, "flat: untouched")
        XCTAssertEqual(pixel(7, 4), Array(off[(4 * width + 7) * 3 ..< (4 * width + 7) * 3 + 3]))
        XCTAssertLessThan(PresentFocusPeaking.Sensitivity.high.threshold, PresentFocusPeaking.Sensitivity.low.threshold)
    }

    // MARK: - Raw clipping

    func testRawClipMaskMarksChannelsAtTheClipLevel() throws {
        let gpu = try GPUContext()
        let input = try XCTUnwrap(makeTexture(gpu, width: 3, height: 1, pixels: [2.0, 0.5, 0.5,  0.5, 0.5, 0.5,  0.5, 1.0, 0.1]))
        let mask = try XCTUnwrap(makeMask(gpu, width: 3, height: 1))
        let commands = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        try RawClipping.encodeMask(input: input, output: mask, clipLevel: SIMD3(2.0, 1.0, 1.5), gpu: gpu, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(readMask(mask), [255, 0, 255], "red at its level, green at its level; the middle pixel is not")
    }

    /// Drawn in magenta where the layer's mask says, only when asked for.
    func testRawClippingOverlayDrawsTheMask() throws {
        let gpu = try GPUContext()
        let pixels: [Float] = [0.5, 0.5, 0.5,  0.5, 0.5, 0.5]
        let maskTexture = try XCTUnwrap(makeMask(gpu, width: 2, height: 1, bytes: [255, 0]))
        let on = try present(gpu, pixels, width: 2, overlays: PresentOverlays(rawClipping: true), rawMask: maskTexture)
        XCTAssertEqual(Array(on[0..<3]), [1, 0, 1])
        XCTAssertEqual(Array(on[3..<6]), [0.5, 0.5, 0.5])
        let off = try present(gpu, pixels, width: 2, rawMask: maskTexture)
        XCTAssertEqual(Array(off[0..<3]), [0.5, 0.5, 0.5], "not asked for: nothing")
    }

    /// On the golden raw: asking for the mask leaves the render itself bit
    /// for bit as it was, and the mask lines up with it.
    func testRawClipMaskOnARealImage() throws {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var parameters = EditParameters()
        parameters.exposureEV = 2
        let plain = try TextureReadback.float16Pixels(
            of: pipeline.render(session, scale: .binned(quads: 8), parameters: parameters, output: .edrDisplay(headroom: 1)),
            gpu: gpu)
        var output = RenderOutput.edrDisplay(headroom: 1)
        output.rawClipMask = true
        let rendered = try pipeline.render(session, scale: .binned(quads: 8), parameters: parameters, output: output)
        let withMask = try TextureReadback.float16Pixels(of: rendered, gpu: gpu)
        XCTAssertTrue(plain == withMask, "the mask is a side output only")
        let mask = try XCTUnwrap(session.rawClipMask(preview: true))
        XCTAssertEqual(mask.width, rendered.width)
        XCTAssertEqual(mask.height, rendered.height)
        XCTAssertEqual(mask.pixelFormat, .r8Unorm)
    }

    // MARK: - High-quality preview

    func testHighQualityPreviewSize() {
        let shrunk = HighQualityPreview.targetSize(width: 6000, height: 4000, longEdge: 1500)
        XCTAssertEqual([shrunk.width, shrunk.height], [1500, 1000])
        let kept = HighQualityPreview.targetSize(width: 6000, height: 4000, longEdge: 9000)
        XCTAssertEqual([kept.width, kept.height], [6000, 4000], "never enlarged")
        let tiny = HighQualityPreview.targetSize(width: 3, height: 2, longEdge: 0)
        XCTAssertEqual([tiny.width, tiny.height], [1, 1])
    }

    // MARK: - Helpers

    private func present(_ gpu: GPUContext, _ pixels: [Float], width: Int, height: Int = 1,
                         clipping: ClippingIndicators = [], overlays: PresentOverlays = .none,
                         rawMask: MTLTexture? = nil) throws -> [Float] {
        let presenter = Presenter(gpu: gpu)
        let size = CGSize(width: width, height: height)
        let source = try XCTUnwrap(makeTexture(gpu, width: width, height: height, pixels: pixels))
        let target = try XCTUnwrap(makeTexture(gpu, width: width, height: height,
                                               pixels: [Float](repeating: 0, count: pixels.count)))
        var layer = PresentLayer(texture: source, coverage: CGRect(origin: .zero, size: size))
        layer.rawClipMask = rawMask
        let commands = try XCTUnwrap(presenter.encode(
            base: layer, tile: nil, transform: .fit(imageSize: size, drawableSize: size),
            frame: CropFrame(sensorSize: size), into: target,
            backgroundLevel: 0, displayHeadroom: 1, clipping: clipping, overlays: overlays))
        commands.commit()
        commands.waitUntilCompleted()
        return readRGB(target)
    }

    private func makeTexture(_ gpu: GPUContext, width: Int, height: Int, pixels rgb: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return nil }
        var half = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<width * height {
            for c in 0..<3 { half[i * 4 + c] = Float16(rgb[i * 3 + c]) }
        }
        half.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func makeMask(_ gpu: GPUContext, width: Int, height: Int, bytes: [UInt8]? = nil) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return nil }
        if let bytes {
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width)
            }
        }
        return texture
    }

    private func readMask(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    private func readRGB(_ texture: MTLTexture) -> [Float] {
        var half = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (0..<texture.width * texture.height).flatMap { i in (0..<3).map { Float(half[i * 4 + $0]) } }
    }
}
