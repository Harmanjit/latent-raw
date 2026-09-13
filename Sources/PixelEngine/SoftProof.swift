import Foundation
import CoreGraphics
import Accelerate
import Metal
import simd
import ColorKit

/// What to simulate on screen (DESIGN.md §14 phase 6, "ICC soft-proofing").
public enum SoftProofTarget: Equatable, Sendable {
    case sRGB
    case displayP3
    /// A profile file: a printer/paper profile, or any ICC.
    case icc(URL)

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .icc(let url): return url.deletingPathExtension().lastPathComponent
        }
    }
}

/// A 3D lookup table that turns display-referred working-space colour
/// into "what that colour will look like after it's been squeezed into
/// the target", plus a flag for colours the target can't reproduce.
///
/// Why a table: an ICC profile can be an arbitrary curve-and-lattice
/// transform, far too slow to evaluate per pixel on the GPU. But it's
/// smooth, so sampling it on a 33×33×33 grid and interpolating between
/// the samples is accurate to well below what the eye can see. Building
/// the table costs a few milliseconds once; applying it costs one
/// texture fetch per pixel.
///
/// The table maps *into and back out of* the target: working → target
/// (clipping to the target's gamut) → working. The result is still in
/// the working space so the rest of the display path is unchanged; only
/// colours the target couldn't hold have moved. The alpha channel is 1
/// where a colour was clipped by more than a just-noticeable amount,
/// which drives the gamut warning.
public final class SoftProofLUT: @unchecked Sendable {
    public static let size = 33
    public let id = UUID()
    public let target: SoftProofTarget
    /// RGBA float16, index ((b * size + g) * size + r) * 4.
    public let entries: [Float16]

    /// Fraction of grid colours the target can't reproduce — a sense of
    /// how much the two gamuts differ.
    public let outOfGamutFraction: Double

    private init(target: SoftProofTarget, entries: [Float16], outOfGamutFraction: Double) {
        self.target = target
        self.entries = entries
        self.outOfGamutFraction = outOfGamutFraction
    }

    public enum ProofError: Error, CustomStringConvertible {
        case profileUnreadable(URL)
        case conversionFailed
        public var description: String {
            switch self {
            case .profileUnreadable(let u): return "could not read ICC profile \(u.lastPathComponent)"
            case .conversionFailed: return "ColorSync could not build the proof transform"
            }
        }
    }

    /// Colours are compared in a roughly perceptual way: a clip that moves
    /// a component by less than this (in gamma-2.2 units) is invisible.
    static let clipThreshold: Float = 0.02

    public static func build(_ target: SoftProofTarget) throws -> SoftProofLUT {
        let n = size
        // Grid of working-space (linear Rec.2020) display-referred colours.
        var grid = [Float](repeating: 0, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 4
            grid[i] = Float(r) / Float(n - 1)
            grid[i + 1] = Float(g) / Float(n - 1)
            grid[i + 2] = Float(b) / Float(n - 1)
            grid[i + 3] = 1
        } } }

        let proofed: [Float]
        switch target {
        case .sRGB, .displayP3:
            proofed = try matrixRoundTrip(grid, space: target == .sRGB ? .sRGB : .displayP3)
        case .icc(let url):
            proofed = try iccRoundTrip(grid, profile: url)
        }

        var entries = [Float16](repeating: 0, count: n * n * n * 4)
        var flagged = 0
        for i in stride(from: 0, to: grid.count, by: 4) {
            var clipped = false
            for c in 0..<3 {
                let a = pow(max(grid[i + c], 0), 1 / 2.2), b = pow(max(proofed[i + c], 0), 1 / 2.2)
                if abs(a - b) > clipThreshold { clipped = true }
                entries[i + c] = Float16(min(max(proofed[i + c], 0), 1))
            }
            entries[i + 3] = clipped ? 1 : 0
            if clipped { flagged += 1 }
        }
        return SoftProofLUT(target: target, entries: entries,
                            outOfGamutFraction: Double(flagged) / Double(n * n * n))
    }

    /// Matrix spaces: convert, clip to [0,1], convert back.
    static func matrixRoundTrip(_ grid: [Float], space: ColorKit.OutputSpace) throws -> [Float] {
        let toOut = ColorKit.workingToOutput(space)
        let back = toOut.inverse
        var out = grid
        for i in stride(from: 0, to: grid.count, by: 4) {
            let w = SIMD3<Float>(grid[i], grid[i + 1], grid[i + 2])
            var t = toOut * w
            t = clamp(t, min: 0, max: 1)
            let r = back * t
            out[i] = r.x; out[i + 1] = r.y; out[i + 2] = r.z
        }
        return out
    }

    /// ICC profiles: ColorSync does the conversion, through vImage so it's
    /// one call per direction rather than per colour.
    static func iccRoundTrip(_ grid: [Float], profile url: URL) throws -> [Float] {
        guard let data = try? Data(contentsOf: url),
              let targetSpace = CGColorSpace(iccData: data as CFData) else {
            throw ProofError.profileUnreadable(url)
        }
        guard let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else {
            throw ProofError.conversionFailed
        }
        let count = grid.count / 4
        var inTarget = try convert(grid, count: count, from: working, to: targetSpace)
        // ColorSync keeps out-of-range values in float pixels; a file
        // can't. Clipping here is the gamut limit the file would impose.
        for i in 0..<inTarget.count { inTarget[i] = min(max(inTarget[i], 0), 1) }
        return try convert(inTarget, count: count, from: targetSpace, to: working)
    }

    private static func convert(_ pixels: [Float], count: Int, from src: CGColorSpace,
                                to dst: CGColorSpace) throws -> [Float] {
        let floatInfo = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                                     | CGImageAlphaInfo.noneSkipLast.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        var srcFormat = vImage_CGImageFormat(bitsPerComponent: 32, bitsPerPixel: 128,
                                             colorSpace: Unmanaged.passUnretained(src),
                                             bitmapInfo: floatInfo, version: 0, decode: nil,
                                             renderingIntent: .perceptual)
        var dstFormat = vImage_CGImageFormat(bitsPerComponent: 32, bitsPerPixel: 128,
                                             colorSpace: Unmanaged.passUnretained(dst),
                                             bitmapInfo: floatInfo, version: 0, decode: nil,
                                             renderingIntent: .perceptual)
        var error = vImage_Error(kvImageNoError)
        guard let converter = vImageConverter_CreateWithCGImageFormat(&srcFormat, &dstFormat, nil,
                                                                      vImage_Flags(kvImageNoFlags), &error)?
                .takeRetainedValue(), error == kvImageNoError else {
            throw ProofError.conversionFailed
        }
        var input = pixels
        var output = [Float](repeating: 0, count: pixels.count)
        let result: vImage_Error = input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var srcBuf = vImage_Buffer(data: inBytes.baseAddress, height: 1, width: vImagePixelCount(count),
                                           rowBytes: count * 16)
                var dstBuf = vImage_Buffer(data: outBytes.baseAddress, height: 1, width: vImagePixelCount(count),
                                           rowBytes: count * 16)
                return vImageConvert_AnyToAny(converter, &srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        guard result == kvImageNoError else { throw ProofError.conversionFailed }
        return output
    }

    /// The table as a 3D texture for the colour kernel.
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let n = Self.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = n; d.height = n; d.depth = n
        d.storageMode = .shared
        d.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        entries.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: n * 8, bytesPerImage: n * n * 8)
        }
        return texture
    }

    /// Looks up one colour on the CPU (trilinear), for tests and readouts.
    public func lookup(_ c: SIMD3<Float>) -> (color: SIMD3<Float>, clipped: Bool) {
        let n = Self.size
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD4<Float> {
            let i = ((b * n + g) * n + r) * 4
            return SIMD4(Float(entries[i]), Float(entries[i + 1]), Float(entries[i + 2]), Float(entries[i + 3]))
        }
        let p = clamp(c, min: 0, max: 1) * Float(n - 1)
        let i0 = SIMD3<Int>(Int(p.x), Int(p.y), Int(p.z))
        let i1 = SIMD3<Int>(min(i0.x + 1, n - 1), min(i0.y + 1, n - 1), min(i0.z + 1, n - 1))
        let f = p - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        var acc = SIMD4<Float>(repeating: 0)
        for (dz, wz) in [(i0.z, 1 - f.z), (i1.z, f.z)] {
            for (dy, wy) in [(i0.y, 1 - f.y), (i1.y, f.y)] {
                for (dx, wx) in [(i0.x, 1 - f.x), (i1.x, f.x)] {
                    acc += at(dx, dy, dz) * (wx * wy * wz)
                }
            }
        }
        return (SIMD3(acc.x, acc.y, acc.z), acc.w > 0.5)
    }
}
