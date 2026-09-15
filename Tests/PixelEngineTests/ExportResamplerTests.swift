import XCTest
import Metal
@testable import PixelEngine

/// Resized exports: the GPU's linear-light Lanczos resampler against a CPU
/// reference built from the same filter, and the property the filter is
/// for (fine detail averages instead of aliasing).
final class ExportResamplerTests: XCTestCase {
    nonisolated(unsafe) private static var sharedGPU: GPUContext?

    private func gpu() throws -> GPUContext {
        if let gpu = Self.sharedGPU { return gpu }
        let gpu = try GPUContext()
        Self.sharedGPU = gpu
        return gpu
    }

    func testFilterHasLanczosShape() {
        XCTAssertEqual(ExportResampler.weight(0), 1)
        for x in [1.0, 2.0, 3.0, 3.5, -3.0] { XCTAssertEqual(ExportResampler.weight(x), 0, accuracy: 1e-12) }
        XCTAssertLessThan(ExportResampler.weight(1.5), 0, "Lanczos has a negative lobe")
        XCTAssertEqual(ExportResampler.weight(0.7), ExportResampler.weight(-0.7))
        // Shrinking widens the filter; extreme reductions are capped.
        XCTAssertEqual(ExportResampler.filterScale(from: 334, to: 320), 320.0 / 334.0, accuracy: 1e-12)
        XCTAssertEqual(ExportResampler.filterScale(from: 100, to: 200), 1)
        XCTAssertGreaterThan(ExportResampler.filterScale(from: 10000, to: 10), 10.0 / 10000.0)
    }

    /// Random encoded pixels, resized on the GPU through the exporter, must
    /// match decode, rows, columns and encode done on the CPU in doubles.
    func testGPUResizeMatchesCPUReference() throws {
        let gpu = try gpu()
        let (w, h) = (37, 23)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float16 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float16(Float(seed >> 40) / Float(1 << 24))
        }
        var texels = [Float16](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) { for c in 0..<3 { texels[i * 4 + c] = next() } }
        let source = try texture(gpu, width: w, height: h, texels: texels)

        let image = try Exporter(gpu: gpu).cgImage(from: source, colorSpace: .sRGB, bitsPerComponent: 16,
                                                   maxLongEdge: 16)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 10)
        let actual = samples16(image)

        var worst = 0
        for c in 0..<3 {
            // Pass 1 at 1:1 samples texel centres exactly; it and the rows
            // pass land in half floats, rounded.
            let linear = (0..<h).map { y in (0..<w).map { x in half(decode(Double(texels[(y * w + x) * 4 + c]))) } }
            let rows = linear.map { reference($0, to: 16).map(half) }
            for x in 0..<16 {
                let column = reference(rows.map { $0[x] }, to: 10)
                for y in 0..<10 {
                    let expected = Int((encode(column[y]) * 65535).rounded())
                    worst = max(worst, abs(expected - Int(actual[(y * 16 + x) * 4 + c])))
                }
            }
        }
        print("resampler: worst difference from the CPU reference \(worst)/65535")
        // Apple GPUs land within 2; the paravirtual GPU on CI rounds its half
        // floats differently and lands at 10. A wrong filter is off by
        // thousands, so 16 still pins the algorithm.
        XCTAssertLessThanOrEqual(worst, 16)
    }

    /// A one-pixel black and white checkerboard is the finest detail there
    /// is. Shrunk properly, it becomes flat 50% linear grey (0.735
    /// encoded). A single bilinear tap per pixel instead picks up whatever
    /// texels it happens to land near, and averaging encoded values would
    /// give 0.5 encoded, far too dark.
    func testFinestDetailAveragesInLinearLight() throws {
        let gpu = try gpu()
        let (w, h) = (96, 64)
        var texels = [Float16](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where (x + y) % 2 == 0 { for c in 0..<3 { texels[(y * w + x) * 4 + c] = 0 } } }
        let source = try texture(gpu, width: w, height: h, texels: texels)

        let image = try Exporter(gpu: gpu).cgImage(from: source, colorSpace: .sRGB, bitsPerComponent: 16,
                                                   maxLongEdge: 37)
        let values = samples16(image)
        let grey = encode(0.5)
        var worst = 0.0
        // Away from the edges, where the repeated border shifts the balance.
        for y in 3..<(image.height - 3) {
            for x in 3..<(image.width - 3) {
                worst = max(worst, abs(Double(values[(y * image.width + x) * 4 + 1]) / 65535 - grey))
            }
        }
        print("resampler: checkerboard worst deviation from linear mid-grey \(worst)")
        XCTAssertLessThan(worst, 0.02)
    }

    /// Full-size exports keep the one-pass path; the resampler only runs
    /// when the size changes.
    func testFullSizeIsUnfiltered() throws {
        let gpu = try gpu()
        var texels = [Float16](repeating: 1, count: 8 * 8 * 4)
        for i in 0..<64 { texels[i * 4] = i % 2 == 0 ? 0 : 1 }
        let image = try Exporter(gpu: gpu).cgImage(from: try texture(gpu, width: 8, height: 8, texels: texels),
                                                   colorSpace: .sRGB, bitsPerComponent: 16, maxLongEdge: 8)
        let values = samples16(image)
        for i in 0..<64 { XCTAssertEqual(values[i * 4], i % 2 == 0 ? 0 : 65535) }
    }

    // MARK: - Helpers

    private func texture(_ gpu: GPUContext, width: Int, height: Int, texels: [Float16]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        texels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    /// The exporter's 16-bit RGBX samples, straight from the image's buffer.
    private func samples16(_ image: CGImage) -> [UInt16] {
        let data = image.dataProvider!.data! as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }.map { UInt16(littleEndian: $0) }
    }

    private func half(_ v: Double) -> Double { Double(Float16(Float(v))) }

    private func decode(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
    }

    private func encode(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c > 0.0031308 ? 1.055 * pow(c, 1 / 2.4) - 0.055 : c * 12.92
    }

    /// One axis on the CPU, exactly as `exportFilterAxis` does it.
    private func reference(_ samples: [Double], to: Int) -> [Double] {
        let from = samples.count
        let scale = Double(to) / Double(from)
        let filterScale = ExportResampler.filterScale(from: from, to: to)
        let radius = ExportResampler.support / filterScale
        return (0..<to).map { x in
            let centre = (Double(x) + 0.5) / scale
            var sum = 0.0, weights = 0.0
            for i in Int((centre - radius).rounded(.down))...Int((centre + radius).rounded(.up)) {
                let w = ExportResampler.weight((Double(i) + 0.5 - centre) * filterScale)
                guard w != 0 else { continue }
                sum += samples[min(max(i, 0), from - 1)] * w
                weights += w
            }
            return sum / weights
        }
    }
}
