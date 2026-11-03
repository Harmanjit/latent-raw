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
    /// A profile held in memory, such as the screen's own (the monitor
    /// gamut warning), with a name to show for it.
    case profile(name: String, data: Data)

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .icc(let url): return url.deletingPathExtension().lastPathComponent
        case .profile(let name, _): return name
        }
    }

    /// Whether the target is a profile file or held profile, where the
    /// rendering intent and paper simulation mean something. The two
    /// display spaces are plain matrices: every intent clips them the
    /// same way and their white is the screen's.
    public var isICC: Bool {
        switch self {
        case .sRGB, .displayP3: return false
        case .icc, .profile: return true
        }
    }
}

/// How a soft proof converts into its target and back to the screen. A
/// view setting, like the target: never part of the edit.
public struct SoftProofOptions: Codable, Equatable, Sendable {
    /// The intent used into the target, as printing or a profile
    /// conversion on export would use it.
    public var intent: RenderingIntent = .perceptual
    /// Show the paper's white and the ink's black as they are, rather than
    /// mapped to the screen's white and black: the proof then looks as dull
    /// as a print beside the screen honestly does.
    public var simulatePaperAndInk = false

    public init(intent: RenderingIntent = .perceptual, simulatePaperAndInk: Bool = false) {
        self.intent = intent
        self.simulatePaperAndInk = simulatePaperAndInk
    }

    /// Fields missing from an older store keep their defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = (try? c.decode(RenderingIntent.self, forKey: .intent)) ?? .perceptual
        simulatePaperAndInk = (try? c.decode(Bool.self, forKey: .simulatePaperAndInk)) ?? false
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
    public let options: SoftProofOptions
    /// RGBA float16, index ((b * size + g) * size + r) * 4.
    public let entries: [Float16]

    /// Fraction of grid colours the target can't reproduce — a sense of
    /// how much the two gamuts differ.
    public let outOfGamutFraction: Double

    private init(target: SoftProofTarget, options: SoftProofOptions, entries: [Float16], outOfGamutFraction: Double) {
        self.target = target
        self.options = options
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

    public static func build(_ target: SoftProofTarget, options: SoftProofOptions = SoftProofOptions()) throws -> SoftProofLUT {
        let grid = makeGrid()
        let proofed: [Float]
        // Which colours get flagged is a question about the target's gamut
        // alone, so it is answered the same way whatever the intent or
        // paper setting: a relative colorimetric round trip.
        let reference: [Float]
        switch target {
        case .sRGB, .displayP3:
            proofed = try matrixRoundTrip(grid, space: target == .sRGB ? .sRGB : .displayP3)
            reference = proofed
        case .icc(let url):
            guard let profile = ICCProfile(url: url) else { throw ProofError.profileUnreadable(url) }
            (proofed, reference) = try iccRoundTrip(grid, profile: profile, options: options)
        case .profile(_, let data):
            guard let profile = ICCProfile(data: data) else { throw ProofError.conversionFailed }
            (proofed, reference) = try iccRoundTrip(grid, profile: profile, options: options)
        }
        return assemble(target: target, options: options, grid: grid, proofed: proofed, reference: reference)
    }

    /// A table that only flags: colours `target` can't show get alpha 1,
    /// and the colour itself passes through untouched. The monitor gamut
    /// warning samples one of these after the proof.
    public static func gamutCheck(_ target: SoftProofTarget) throws -> SoftProofLUT {
        let grid = makeGrid()
        let reference: [Float]
        switch target {
        case .sRGB, .displayP3:
            reference = try matrixRoundTrip(grid, space: target == .sRGB ? .sRGB : .displayP3)
        case .icc(let url):
            guard let profile = ICCProfile(url: url) else { throw ProofError.profileUnreadable(url) }
            reference = try iccRoundTrip(grid, profile: profile, options: SoftProofOptions(intent: .relativeColorimetric)).reference
        case .profile(_, let data):
            guard let profile = ICCProfile(data: data) else { throw ProofError.conversionFailed }
            reference = try iccRoundTrip(grid, profile: profile, options: SoftProofOptions(intent: .relativeColorimetric)).reference
        }
        return assemble(target: target, options: SoftProofOptions(), grid: grid, proofed: grid, reference: reference)
    }

    /// Grid of working-space (linear Rec.2020) display-referred colours.
    private static func makeGrid() -> [Float] {
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
        return grid
    }

    /// The table from the grid, what each grid colour shows as, and the
    /// colorimetric round trip that decides which ones are flagged.
    private static func assemble(target: SoftProofTarget, options: SoftProofOptions, grid: [Float],
                                 proofed: [Float], reference: [Float]) -> SoftProofLUT {
        let n = size
        var entries = [Float16](repeating: 0, count: n * n * n * 4)
        var flagged = 0
        for i in stride(from: 0, to: grid.count, by: 4) {
            var clipped = false
            for c in 0..<3 {
                let a = pow(max(grid[i + c], 0), 1 / 2.2), b = pow(max(reference[i + c], 0), 1 / 2.2)
                if abs(a - b) > clipThreshold { clipped = true }
                entries[i + c] = Float16(min(max(proofed[i + c], 0), 1))
            }
            entries[i + 3] = clipped ? 1 : 0
            if clipped { flagged += 1 }
        }
        return SoftProofLUT(target: target, options: options, entries: entries,
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

    /// ICC profiles: ColorSync does each leg, one call per leg for the
    /// whole grid. Returns what the proof shows and the colorimetric round
    /// trip the gamut warning is judged on.
    ///
    /// Into the target: the chosen intent, with black point compensation
    /// for relative colorimetric (`ICCTransform`). Clipping to [0,1] there
    /// is the gamut limit a file or print imposes; ColorSync keeps
    /// out-of-range values in float pixels.
    ///
    /// Back to the screen: relative colorimetric with the target's black
    /// mapped to screen black, so the proof shows the gamut and the tonal
    /// squeeze but not the paper; or, simulating paper and ink, absolute
    /// colorimetric with no black point compensation, so the paper's white
    /// and the ink's black show as the colours they are.
    static func iccRoundTrip(_ grid: [Float], profile: ICCProfile,
                             options: SoftProofOptions) throws -> (proofed: [Float], reference: [Float]) {
        guard let working = ICCProfile.linearRec2020 else { throw ProofError.conversionFailed }
        let count = grid.count / 4
        var rgb = [Float](repeating: 0, count: count * 3)
        for i in 0..<count { for c in 0..<3 { rgb[i * 3 + c] = grid[i * 4 + c] } }
        let black = ICCTransform.blackPoint(of: profile)

        func into(_ intent: ICCTransform.Intent, compensate: Bool) throws -> [Float] {
            let source = compensate ? rgb.map { ICCTransform.compressBlack($0, blackPoint: black) } : rgb
            return try ICCTransform.convert(source, from: working, to: profile, intent: intent).map { min(max($0, 0), 1) }
        }
        func back(_ device: [Float], intent: ICCTransform.Intent, expand: Bool) throws -> [Float] {
            let w = try ICCTransform.convert(device, from: profile, to: working, intent: intent)
            var out = grid
            for i in 0..<count {
                for c in 0..<3 {
                    let v = w[i * 3 + c]
                    out[i * 4 + c] = expand ? ICCTransform.expandBlack(v, blackPoint: black) : v
                }
            }
            return out
        }

        do {
            let relative = try into(.relativeColorimetric, compensate: true)
            let reference = try back(relative, intent: .relativeColorimetric, expand: true)
            let device = options.intent == .relativeColorimetric ? relative : try into(.perceptual, compensate: false)
            let proofed = options.simulatePaperAndInk
                ? try back(device, intent: .absoluteColorimetric, expand: false)
                : (options.intent == .relativeColorimetric ? reference
                   : try back(device, intent: .relativeColorimetric, expand: true))
            return (proofed, reference)
        } catch {
            throw ProofError.conversionFailed
        }
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
