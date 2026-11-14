import Foundation
import simd

/// The Channel Mixer (darktable's channel mixer, Lightroom's B&W mixer in
/// older versions): each output channel made from a mix of the red, green
/// and blue the camera matrix produced, in the working space (linear
/// Rec.2020).
///
/// Each row is one output channel's recipe, 1 meaning 100% of that source,
/// −2…2 each. Normalise divides each row by its sum when drawing the
/// matrix, so a grey stays the grey it was however the row is set. The
/// Monochrome preset gives every row the same recipe (Rec.2020 luminance),
/// a black and white made before any of the colour controls see it.
///
/// Folded into the camera matrix on the CPU beside Calibration's primaries
/// (`RenderPipeline.calibrated`), so the shader is unchanged. Its own
/// optional edit-stack module, `channelmixer`, absent while it is the
/// identity: an edit that never used it encodes and renders as before.
public struct ChannelMixer: Equatable, Sendable, Codable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]
    public var normalise: Bool

    public static let identity = ChannelMixer()
    public static let sourceRange: ClosedRange<Float> = -2...2
    /// Rec.2020 luminance, the Monochrome preset's recipe for every row.
    public static let monochromeRow: [Float] = [0.2627, 0.6780, 0.0593]

    public static let monochrome = ChannelMixer(red: monochromeRow, green: monochromeRow, blue: monochromeRow)

    public init(red: [Float] = [1, 0, 0], green: [Float] = [0, 1, 0], blue: [Float] = [0, 0, 1],
                normalise: Bool = false) {
        self.red = red; self.green = green; self.blue = blue; self.normalise = normalise
    }

    public var isNeutral: Bool { self == .identity }

    /// The row for output channel 0 (red), 1 (green) or 2 (blue).
    public subscript(output: Int) -> [Float] {
        get { output == 0 ? red : output == 1 ? green : blue }
        set {
            switch output {
            case 0: red = newValue
            case 1: green = newValue
            default: blue = newValue
            }
        }
    }

    /// Whether every output is grey-equal (a monochrome mix).
    public var isMonochrome: Bool { red == green && green == blue && red != [1, 0, 0] }

    /// A row as drawn into the matrix: divided by its sum when Normalise
    /// is on and the sum isn't (near) zero.
    func effectiveRow(_ row: [Float]) -> SIMD3<Float> {
        let r = row.count == 3 ? SIMD3(row[0], row[1], row[2]) : SIMD3<Float>(0, 0, 0)
        guard normalise else { return r }
        let sum = r.x + r.y + r.z
        return abs(sum) > 1e-3 ? r / sum : r
    }

    /// The working-space matrix (rows are outputs). Identity when nothing
    /// is mixed.
    public var matrix: simd_float3x3 {
        guard !isNeutral else { return matrix_identity_float3x3 }
        let r = effectiveRow(red), g = effectiveRow(green), b = effectiveRow(blue)
        return simd_float3x3(rows: [r, g, b])
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue, normalise }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try c.decodeIfPresent([Float].self, forKey: .red) ?? [1, 0, 0],
                  green: try c.decodeIfPresent([Float].self, forKey: .green) ?? [0, 1, 0],
                  blue: try c.decodeIfPresent([Float].self, forKey: .blue) ?? [0, 0, 1],
                  normalise: try c.decodeIfPresent(Bool.self, forKey: .normalise) ?? false)
    }

    /// Normalise only when on.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(red, forKey: .red)
        try c.encode(green, forKey: .green)
        try c.encode(blue, forKey: .blue)
        if normalise { try c.encode(true, forKey: .normalise) }
    }

    /// Rows of the wrong length back to the identity's, values in range.
    var sanitized: ChannelMixer {
        func row(_ r: [Float], _ fallback: [Float]) -> [Float] {
            guard r.count == 3 else { return fallback }
            return r.map { $0.isFinite ? min(max($0, Self.sourceRange.lowerBound), Self.sourceRange.upperBound) : 0 }
        }
        return ChannelMixer(red: row(red, [1, 0, 0]), green: row(green, [0, 1, 0]), blue: row(blue, [0, 0, 1]),
                            normalise: normalise)
    }
}
