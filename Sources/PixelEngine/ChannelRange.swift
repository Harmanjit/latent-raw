import Foundation
import simd

// Range masks by one channel, separate fades either side of a band, and
// what the range masks read from a pixel, as the colour kernel reads it
// (ColorPipeline.metal: `luminanceRangeWeight`, `maskChannelValue`).

/// The channel a Channel Range component selects by. Values are 0…1:
/// red, green and blue of the perceptual (gamma 2.2) colour and its
/// saturation; CIE Lab lightness; Lab a and b centred on 0.5 (±100 at the
/// ends); and Lab chroma (100 at 1).
public enum MaskChannel: String, Codable, CaseIterable, Sendable {
    case red, green, blue, saturation, lightness, labA, labB, labChroma

    public var displayName: String {
        switch self {
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .saturation: return "Saturation"
        case .lightness: return "Lightness"
        case .labA: return "Lab a (green–magenta)"
        case .labB: return "Lab b (blue–yellow)"
        case .labChroma: return "Lab Chroma"
        }
    }

    /// The id the shader switches on (`maskChannelValue`).
    var gpuID: Int {
        switch self {
        case .red: return 0
        case .green: return 1
        case .blue: return 2
        case .saturation: return 3
        case .lightness: return 4
        case .labA: return 5
        case .labB: return 6
        case .labChroma: return 7
        }
    }

    /// The channel's value for a perceptual (gamma 2.2, display-referred
    /// Rec.2020) colour, as the shader computes it.
    public func value(perceptual p: SIMD3<Float>) -> Float {
        switch self {
        case .red: return p.x
        case .green: return p.y
        case .blue: return p.z
        case .saturation: return ColourRange.hueSaturation(p).saturation
        case .lightness, .labA, .labB, .labChroma:
            let lab = Self.lab(perceptual: p)
            switch self {
            case .lightness: return min(max(lab.x / 100, 0), 1)
            case .labA: return min(max(lab.y / 200 + 0.5, 0), 1)
            case .labB: return min(max(lab.z / 200 + 0.5, 0), 1)
            default: return min(max((lab.y * lab.y + lab.z * lab.z).squareRoot() / 100, 0), 1)
            }
        }
    }

    /// CIE Lab (D65) of a perceptual Rec.2020 colour.
    static func lab(perceptual p: SIMD3<Float>) -> SIMD3<Float> {
        let lin = SIMD3(powf(max(p.x, 0), 2.2), powf(max(p.y, 0), 2.2), powf(max(p.z, 0), 2.2))
        let x = simd_dot(lin, SIMD3(0.6369580, 0.1446169, 0.1688810)) / 0.95047
        let y = simd_dot(lin, SIMD3(0.2627002, 0.6779981, 0.0593017))
        let z = simd_dot(lin, SIMD3(0, 0.0280727, 1.0609851)) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856452 ? powf(t, 1.0 / 3.0) : t * 7.787037 + 0.137931 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

/// Selects pixels whose `channel` lies between `low` and `high`, fading
/// in over `featherLow` below and `featherHigh` above (each nil is
/// `feather`). Evaluated like a Luminance Range on another channel.
public struct ChannelRange: Equatable, Sendable, Codable {
    public var channel: MaskChannel
    public var low: Float
    public var high: Float
    public var feather: Float
    public var featherLow: Float?
    public var featherHigh: Float?

    public init(channel: MaskChannel = .red, low: Float = 0.5, high: Float = 1, feather: Float = 0.1) {
        self.channel = channel; self.low = low; self.high = high; self.feather = feather
    }

    public var lowFeather: Float { featherLow ?? feather }
    public var highFeather: Float { featherHigh ?? feather }

    /// The selection for a pixel whose channel reads `value`.
    public func weight(value: Float) -> Float {
        MaskRangeMath.weight(low: low, high: high, featherLow: lowFeather, featherHigh: highFeather, value: value)
    }

    /// The selection for a perceptual colour.
    public func weight(perceptual p: SIMD3<Float>) -> Float { weight(value: channel.value(perceptual: p)) }
}

extension LuminanceRange {
    public var lowFeather: Float { featherLow ?? feather }
    public var highFeather: Float { featherHigh ?? feather }

    /// The selection for a pixel of displayed luminance `luma`.
    public func weight(luma: Float) -> Float {
        MaskRangeMath.weight(low: low, high: high, featherLow: lowFeather, featherHigh: highFeather, value: luma)
    }
}

/// The four numbers the range control edits: the band and its fades. The
/// same for a Luminance Range and a Channel Range.
public struct MaskRangeBand: Equatable, Sendable {
    public var low: Float
    public var high: Float
    public var featherLow: Float
    public var featherHigh: Float

    public init(low: Float, high: Float, featherLow: Float, featherHigh: Float) {
        self.low = low; self.high = high; self.featherLow = featherLow; self.featherHigh = featherHigh
    }

    /// Where the fades end: the outer handles.
    public var lowEdge: Float { low - featherLow }
    public var highEdge: Float { high + featherHigh }

    /// Feathers are kept in the slider's range, 0.01…0.5, and Low never
    /// passes High.
    public static let featherRange: ClosedRange<Float> = 0.01...0.5

    public func sanitised() -> MaskRangeBand {
        var b = self
        b.low = min(max(b.low, 0), 1)
        b.high = min(max(b.high, b.low), 1)
        b.featherLow = min(max(b.featherLow, Self.featherRange.lowerBound), Self.featherRange.upperBound)
        b.featherHigh = min(max(b.featherHigh, Self.featherRange.lowerBound), Self.featherRange.upperBound)
        return b
    }

    /// A band around a single sampled value: ±0.1, the default fades.
    public static func around(_ value: Float, feather: Float) -> MaskRangeBand {
        MaskRangeBand(low: max(value - 0.1, 0), high: min(value + 0.1, 1), featherLow: feather, featherHigh: feather)
    }
}

/// Reading and writing a range through its band. Equal fades are stored
/// as `feather` alone (both separate ones nil), so a range whose fades
/// were never set apart stays exactly as it is written today.
public protocol MaskBandEditable {
    var low: Float { get set }
    var high: Float { get set }
    var feather: Float { get set }
    var featherLow: Float? { get set }
    var featherHigh: Float? { get set }
}

extension MaskBandEditable {
    public var band: MaskRangeBand {
        get { MaskRangeBand(low: low, high: high, featherLow: featherLow ?? feather, featherHigh: featherHigh ?? feather) }
        set {
            low = newValue.low; high = newValue.high
            if newValue.featherLow == newValue.featherHigh {
                feather = newValue.featherLow; featherLow = nil; featherHigh = nil
            } else {
                featherLow = newValue.featherLow; featherHigh = newValue.featherHigh
            }
        }
    }

    /// The Feather slider: both fades at once.
    public var bothFeathers: Float {
        get { feather }
        set { feather = newValue; featherLow = nil; featherHigh = nil }
    }
}

extension LuminanceRange: MaskBandEditable {}
extension ChannelRange: MaskBandEditable {}

enum MaskRangeMath {
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// `luminanceRangeWeight` in ColorPipeline.metal.
    static func weight(low: Float, high: Float, featherLow: Float, featherHigh: Float, value: Float) -> Float {
        let fl = max(featherLow, 1e-3), fh = max(featherHigh, 1e-3)
        let inLow = smoothstep(low - fl, low + fl * 0.001, value)
        let inHigh = 1 - smoothstep(high - fh * 0.001, high + fh, value)
        return inLow * inHigh
    }
}

/// What the range masks read from a working-space pixel, as the colour
/// kernel does before any local adjustment: through the tone ranges and
/// the SDR tone curve (as `ColourRange.sample`), the displayed luminance
/// a Luminance Range compares, and the perceptual colour the colour and
/// channel ranges read.
public struct MaskRangeInputs: Equatable, Sendable {
    public var displayLuma: Float
    public var perceptual: SIMD3<Float>

    public init(working rgb: SIMD3<Float>, contrast: Float, greyPoint: Float, toneRanges: ToneRanges = .neutral) {
        var w = simd_max(rgb, SIMD3(repeating: 0))
        if !toneRanges.isNeutral {
            let y = simd_dot(w, SIMD3(0.2627, 0.6780, 0.0593))
            let c = max(contrast, 1e-3)
            let t = min(max(c * log2(max(y, 1e-10) / max(greyPoint, 1e-6)), ToneRanges.lutRange.lowerBound),
                        ToneRanges.lutRange.upperBound)
            w *= exp2((toneRanges.remap(t) - t) / c)
        }
        let c = contrast
        let xc = SIMD3(powf(w.x, c), powf(w.y, c), powf(w.z, c))
        let kc = powf(max(greyPoint, 1e-6), c)
        let display = xc / (xc + SIMD3(repeating: kc))
        displayLuma = powf(max(simd_dot(display, SIMD3(0.2627, 0.6780, 0.0593)), 0), 1 / 2.2)
        perceptual = SIMD3(powf(max(display.x, 0), 1 / 2.2), powf(max(display.y, 0), 1 / 2.2),
                           powf(max(display.z, 0), 1 / 2.2))
    }

    /// The value a Luminance Range (nil channel) or Channel Range reads.
    public func value(_ channel: MaskChannel?) -> Float {
        channel.map { $0.value(perceptual: perceptual) } ?? displayLuma
    }
}

extension MaskComponent {
    /// Whether Show Channel has something to show for this component: it
    /// reads a value from the picture rather than drawing a shape.
    public var showsChannel: Bool {
        switch source {
        case .luminance, .colour, .channel: return true
        case .shape: return false
        }
    }
}

extension LocalsGPUPlan {
    /// `MaskOverlayParams.flags.z`: 1 + the flattened index of the
    /// component Show Channel displays, 0 when it is off.
    func channelViewFlag(_ output: RenderOutput) -> UInt32 {
        guard let i = output.maskOverlay, let k = output.maskOverlayStyle.channelComponent,
              i >= 0, i < locals.count, k >= 0, k < Int(locals[i].info2.y) else { return 0 }
        return UInt32(Int(locals[i].info2.x) + k + 1)
    }
}
