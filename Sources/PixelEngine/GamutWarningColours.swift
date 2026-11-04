import Foundation
import simd
import ColorKit

/// The colours the soft proof paints its two gamut warnings in. Lightroom's
/// red and blue by default; either can be changed, for a photo whose own
/// reds or blues would hide the warning. A view setting, never part of the
/// edit.
public struct GamutWarningColours: Codable, Equatable, Sendable {
    /// What the destination can't reproduce, as sRGB components (0...1,
    /// with the sRGB curve, as a colour well gives them).
    public var destination: SIMD3<Float>
    /// What the screen can't show of the proof, the same way.
    public var monitor: SIMD3<Float>

    public init(destination: SIMD3<Float>, monitor: SIMD3<Float>) {
        self.destination = destination
        self.monitor = monitor
    }

    public static let standard = GamutWarningColours(destination: SIMD3(1, 0, 0), monitor: SIMD3(0, 0, 1))

    /// Fields missing from an older store keep their defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = (try? c.decode(SIMD3<Float>.self, forKey: .destination)) ?? Self.standard.destination
        monitor = (try? c.decode(SIMD3<Float>.self, forKey: .monitor)) ?? Self.standard.monitor
    }

    /// One colour as the colour kernel paints it: linear Rec. 2020, the
    /// working space the warning is painted in.
    public static func working(_ sRGB: SIMD3<Float>) -> SIMD3<Float> {
        let encoded = simd_clamp(sRGB, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let linear = SIMD3<Float>(srgbToLinear(encoded.x), srgbToLinear(encoded.y), srgbToLinear(encoded.z))
        return simd_clamp(ColorKit.workingToOutput(.sRGB).inverse * linear, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// Both colours packed for the kernel as six half floats in three
    /// words: destination red and green; destination blue and monitor red;
    /// monitor green and blue (low half first). Half floats rather than
    /// bytes: the warning goes back out through the working-to-screen
    /// matrix, whose large coefficients would turn eight-bit steps into
    /// visible tints in a pure primary.
    public var packedWords: SIMD3<UInt32> {
        let d = Self.working(destination), m = Self.working(monitor)
        func pair(_ low: Float, _ high: Float) -> UInt32 {
            UInt32(Float16(low).bitPattern) | UInt32(Float16(high).bitPattern) << 16
        }
        return SIMD3(pair(d.x, d.y), pair(d.z, m.x), pair(m.y, m.z))
    }

    private static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
