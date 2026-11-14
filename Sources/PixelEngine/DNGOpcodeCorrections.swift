import Foundation
import Metal
import simd
import RawCore
import LensKit

/// A DNG's own corrections (`DNGOpcodeList`), turned into what Latent's
/// stages already apply: its GainMaps into a `FlatFieldGainMap`, which
/// the flat-field stage lays over camera RGB (stage 6b), and its
/// FixVignetteRadial and WarpRectilinear into a `LensCorrection`, which
/// the lens stage applies in place of a Lensfun profile (stage 7).
///
/// Applied only while the Lens Corrections panel's "Apply embedded DNG
/// corrections" switch is on (`EditParameters.embeddedDNGCorrections`),
/// so no edit made before it changes. A reference flat field, when the
/// edit has one, takes the gain map's place: it was shot through the same
/// lens and already holds its shading.
///
/// The fits are approximations where Latent's models are smaller than the
/// DNG's: distortion is fitted by Lensfun's poly5 (the r⁶ term and the
/// tangential terms are dropped, and the scale term is left to the lens
/// stage's auto scale), vignetting by Lensfun's three-term model, and an
/// optical centre away from the frame's centre is taken as centred.
public struct DNGEmbeddedCorrections: Sendable {
    public let opcodes: DNGOpcodeList
    /// The gain maps resampled onto the sensor, nil when there are none.
    public let gainMap: FlatFieldGainMap?
    /// The lens model, nil without vignetting or warp opcodes.
    public let lens: LensCorrection?
    /// Names the gain map in `FlatFieldCache` (never written to disk).
    let gainMapKey: String

    public static let profileName = "Embedded DNG corrections"

    /// nil when nothing in the lists is something Latent applies.
    public init?(opcodes: DNGOpcodeList, summary: RawSummary) {
        self.opcodes = opcodes
        gainMap = Self.gainMap(from: opcodes.gainMaps, summary: summary)
        lens = Self.lens(warp: opcodes.warp, vignette: opcodes.vignette,
                         width: summary.rawWidth, height: summary.rawHeight)
        gainMapKey = "dngopcodes:" + opcodes.fingerprint
        if gainMap == nil && lens == nil { return nil }
    }

    /// What the file corrects, for the panel: "lens shading, vignetting, distortion".
    public var summaryDescription: String {
        var parts: [String] = []
        if gainMap != nil { parts.append("lens shading") }
        if lens?.vignetting != nil { parts.append("vignetting") }
        if lens?.distortion != nil { parts.append("distortion") }
        if lens?.tca != nil { parts.append("chromatic aberration") }
        return parts.joined(separator: ", ")
    }

    // MARK: Gain maps

    /// The gain maps averaged into a flat-field grid: each cell's centre
    /// sampled in every map that covers it, the map's CFA position (or
    /// planes) saying which channel it scales; the two greens averaged.
    static func gainMap(from maps: [DNGGainMap], summary: RawSummary) -> FlatFieldGainMap? {
        let w = summary.rawWidth, h = summary.rawHeight
        guard !maps.isEmpty, w > 1, h > 1 else { return nil }
        let long = max(w, h)
        let scale = Double(min(FlatFieldGainMap.longEdgeCells, long)) / Double(long)
        let gw = max(2, Int((Double(w) * scale).rounded()))
        let gh = max(2, Int((Double(h) * scale).rounded()))
        let order: UInt8?
        if case .bayer(let o) = summary.cfaPattern { order = o } else { order = nil }

        var sum = [SIMD3<Float>](repeating: .zero, count: gw * gh)
        var count = [SIMD3<Float>](repeating: .zero, count: gw * gh)
        for map in maps {
            // Which channels this map scales, and from which of its planes.
            var channels: [(channel: Int, mapPlane: Int)] = []
            if let order, map.planes == 1, map.rowPitch >= 2 || map.colPitch >= 2 {
                let c = Int(order >> UInt8((((map.top & 1) << 1) | (map.left & 1)) * 2)) & 3
                channels = [(c == 3 ? 1 : c, 0)]
            } else if order != nil {
                channels = [(0, 0), (1, 0), (2, 0)]
            } else {
                for p in 0..<map.planes where map.plane + p < 3 {
                    channels.append((map.plane + p, min(p, map.mapPlanes - 1)))
                }
            }
            guard !channels.isEmpty else { continue }
            for cy in 0..<gh {
                let v = (Double(cy) + 0.5) / Double(gh)
                let py = Int(v * Double(h))
                guard py >= map.top, py < max(map.bottom, map.top + 1) else { continue }
                for cx in 0..<gw {
                    let u = (Double(cx) + 0.5) / Double(gw)
                    let px = Int(u * Double(w))
                    guard px >= map.left, px < max(map.right, map.left + 1) else { continue }
                    for (channel, plane) in channels {
                        sum[cy * gw + cx][channel] += map.gain(v: v, h: u, mapPlane: plane)
                        count[cy * gw + cx][channel] += 1
                    }
                }
            }
        }
        guard count.contains(where: { $0.max() > 0 }) else { return nil }
        var gains = [Float]()
        gains.reserveCapacity(gw * gh * 3)
        let range = FlatFieldGainMap.gainRange
        for i in 0..<(gw * gh) {
            for c in 0..<3 {
                let g = count[i][c] > 0 ? sum[i][c] / count[i][c] : 1
                gains.append(min(max(g.isFinite ? g : 1, range.lowerBound), range.upperBound))
            }
        }
        return FlatFieldGainMap(width: gw, height: gh, gains: gains, aspect: Float(w) / Float(h))
    }

    // MARK: Lens model

    static func lens(warp: DNGWarpRectilinear?, vignette: DNGFixVignetteRadial?,
                     width: Int, height: Int) -> LensCorrection? {
        guard warp != nil || vignette != nil, width > 1, height > 1 else { return nil }
        let halfShort = Double(min(width, height)) / 2
        let halfDiag = (Double(width * width + height * height)).squareRoot() / 2
        var correction = LensCorrection(cropRatio: 1, profileName: profileName, databaseVersion: "dng")

        if let warp, let green = warp.planes.count >= 3 ? warp.planes[1] : warp.planes.first {
            let scale0 = green.kr[0] != 0 ? green.kr[0] : 1
            // Latent's radius is in half short sides; the DNG's is 1 at the
            // corner (half the diagonal, for a centred lens).
            let toDNG = halfShort / halfDiag
            let maxR = halfDiag / halfShort
            let samples = (0...64).map { maxR * Double($0) / 64 }
            let rows = samples.map { r in [r * r, r * r * r * r] }
            let targets = samples.map { r in green.radialFactor(atNormalisedRadius: r * toDNG) / scale0 - 1 }
            if let k = leastSquares(rows, targets), k.allSatisfy(\.isFinite) {
                let model = DistortionModel.poly5(k1: Float(k[0]), k2: Float(k[1]))
                correction.distortion = model
                correction.autoScale = LensCorrection.autoScale(for: model, cropRatio: 1, width: width, height: height)
            }
            if warp.planes.count >= 3 {
                func fit(_ plane: DNGWarpRectilinear.Plane) -> SIMD3<Float>? {
                    var rows: [[Double]] = [], targets: [Double] = []
                    var deviation = 0.0
                    for r in samples {
                        let fg = green.radialFactor(atNormalisedRadius: r * toDNG)
                        guard abs(fg) > 1e-9 else { continue }
                        let ratio = plane.radialFactor(atNormalisedRadius: r * toDNG) / fg
                        let rd = r * fg / scale0
                        rows.append([rd * rd, rd, 1])
                        targets.append(ratio)
                        deviation = max(deviation, abs(ratio - 1))
                    }
                    guard deviation > 1e-6, let c = leastSquares(rows, targets), c.allSatisfy(\.isFinite) else { return nil }
                    return SIMD3(Float(c[0]), Float(c[1]), Float(c[2]))
                }
                let red = fit(warp.planes[0]), blue = fit(warp.planes[2])
                if red != nil || blue != nil {
                    correction.tca = TCAModel(red: red ?? TCAModel.identity.red, blue: blue ?? TCAModel.identity.blue)
                }
            }
        }

        if let vignette {
            // Latent divides by 1 + k1 x + k2 x² + k3 x³ (x = r², r in half
            // diagonals); the DNG multiplies by its polynomial.
            let samples = (0...64).map { Double($0) / 64 }
            let rows = samples.map { r -> [Double] in let x = r * r; return [x, x * x, x * x * x] }
            let targets = samples.map { r -> Double in
                let g = vignette.gain(atNormalisedRadius: r)
                return g > 1e-6 ? 1 / g - 1 : 0
            }
            if let k = leastSquares(rows, targets), k.allSatisfy(\.isFinite) {
                correction.vignetting = VignettingModel(k1: Float(k[0]), k2: Float(k[1]), k3: Float(k[2]))
            }
        }
        return correction.isEmpty ? nil : correction
    }

    /// Least squares by the normal equations, for two or three unknowns;
    /// nil when they're singular.
    static func leastSquares(_ rows: [[Double]], _ targets: [Double]) -> [Double]? {
        guard let n = rows.first?.count, n > 0, rows.count == targets.count, rows.count >= n else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for (row, t) in zip(rows, targets) {
            for i in 0..<n {
                for j in 0..<n { a[i][j] += row[i] * row[j] }
                a[i][n] += row[i] * t
            }
        }
        // Gaussian elimination with partial pivoting.
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-15 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<n where row != col {
                let f = a[row][col] / a[col][col]
                for k in col...n { a[row][k] -= f * a[col][k] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}

extension ImageSession {
    /// Whether this file carries corrections the switch would apply.
    public var hasEmbeddedDNGCorrections: Bool { dngCorrections != nil }

    /// The DNG's gain map as a texture for the flat-field stage, when the
    /// edit applies the embedded corrections and has no reference flat
    /// field of its own; nil otherwise.
    func embeddedGainMapTexture(for p: EditParameters) -> MTLTexture? {
        guard p.embeddedDNGCorrections, p.flatField == nil, let corrections = dngCorrections,
              let map = corrections.gainMap else { return nil }
        let cache = FlatFieldCache.shared
        if cache.gainMap(for: corrections.gainMapKey) == nil {
            cache.store(map, for: corrections.gainMapKey, persist: false)
        }
        return cache.texture(for: corrections.gainMapKey, gpu: gpu)?.texture
    }
}
