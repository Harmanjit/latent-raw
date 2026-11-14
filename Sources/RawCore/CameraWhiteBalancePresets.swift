import Foundation
import CLibRaw

/// One of the camera's own white balance presets (Daylight, Shade, a
/// Kelvin setting…), as its maker notes record them: the multipliers the
/// camera itself would use under that light. LibRaw reads them
/// (`imgdata.color.WB_Coeffs` and `WBCT_Coeffs`); the decoder service
/// sends them back with the rest of the metadata.
public struct CameraWhiteBalancePreset: Codable, Sendable, Equatable {
    /// EXIF LightSource code, or `kelvinCode` for a colour-temperature entry.
    public var illuminant: Int
    /// The entry's temperature for a colour-temperature entry; 0 otherwise.
    public var kelvin: Float
    /// R, G, B and second-green multipliers, in the maker's own scale
    /// (only their ratios matter).
    public var multipliers: [Float]

    public static let kelvinCode = 254
    /// More than any camera records; a reply with more is cut to this.
    static let maximumCount = 96

    public init(illuminant: Int, kelvin: Float, multipliers: [Float]) {
        self.illuminant = illuminant
        self.kelvin = kelvin
        self.multipliers = multipliers
    }

    /// What the menu calls it.
    public var title: String {
        if illuminant == Self.kelvinCode { return "\(Int(kelvin.rounded())) K" }
        switch illuminant {
        case 1: return "Daylight"
        case 2: return "Fluorescent"
        case 3: return "Tungsten"
        case 4: return "Flash"
        case 9: return "Fine Weather"
        case 10: return "Cloudy"
        case 11: return "Shade"
        case 12: return "Daylight Fluorescent"
        case 13: return "Day White Fluorescent"
        case 14: return "Cool White Fluorescent"
        case 15: return "White Fluorescent"
        case 16: return "Warm White Fluorescent"
        case 17: return "Standard Light A"
        case 18: return "Standard Light B"
        case 19: return "Standard Light C"
        case 20: return "D55"
        case 21: return "D65"
        case 22: return "D75"
        case 23: return "D50"
        case 24: return "Studio Tungsten"
        case 64: return "Sunset"
        case 65: return "Underwater"
        case 66: return "Fluorescent (High)"
        case 67: return "Mercury Vapour"
        default: return "Light Source \(illuminant)"
        }
    }

    /// Four positive, finite multipliers: anything else from a reply is
    /// dropped rather than trusted.
    var isUsable: Bool {
        multipliers.count == 4 && multipliers.prefix(3).allSatisfy { $0.isFinite && $0 > 0 }
            && multipliers[3].isFinite && multipliers[3] >= 0
            && kelvin.isFinite && kelvin >= 0 && kelvin < 100_000
    }

    /// The usable presets of a list, at most `maximumCount`.
    static func sanitized(_ presets: [CameraWhiteBalancePreset]) -> [CameraWhiteBalancePreset] {
        Array(presets.filter(\.isUsable).prefix(maximumCount))
    }

    /// The presets LibRaw found for the open file.
    static func read(_ h: OpaquePointer) -> [CameraWhiteBalancePreset] {
        var buffer = [CLibRawWBPreset](repeating: CLibRawWBPreset(), count: maximumCount)
        let n = buffer.withUnsafeMutableBufferPointer { clibraw_get_wb_presets(h, $0.baseAddress, Int32($0.count)) }
        return sanitized(buffer.prefix(Int(max(0, n))).map { p in
            CameraWhiteBalancePreset(illuminant: Int(p.illuminant), kelvin: p.kelvin,
                                     multipliers: [p.coeffs.0, p.coeffs.1, p.coeffs.2, p.coeffs.3])
        })
    }
}
