import SwiftUI
import PixelEngine

/// How the selected mask is drawn on the image (Local Adjustments ›
/// Overlay): remembered across launches, never part of an edit.
@MainActor
final class MaskOverlaySettings: ObservableObject {
    static let shared = MaskOverlaySettings()

    /// The colours on offer, in linear RGB. Red first: what every
    /// version before the overlay menu drew.
    enum Swatch: String, CaseIterable, Identifiable {
        case red, green, blue, yellow, magenta, white
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
        var linear: SIMD3<Float> {
            switch self {
            case .red: return SIMD3(0.8, 0.05, 0.05)
            case .green: return SIMD3(0.05, 0.7, 0.1)
            case .blue: return SIMD3(0.05, 0.2, 0.9)
            case .yellow: return SIMD3(0.85, 0.75, 0.02)
            case .magenta: return SIMD3(0.8, 0.05, 0.75)
            case .white: return SIMD3(0.9, 0.9, 0.9)
            }
        }
        var colour: Color {
            Color(.sRGBLinear, red: Double(linear.x), green: Double(linear.y), blue: Double(linear.z))
        }
    }

    private let defaults: UserDefaults

    @Published var mode: MaskOverlayMode { didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) } }
    @Published var swatch: Swatch { didSet { defaults.set(swatch.rawValue, forKey: Self.swatchKey) } }
    @Published var opacity: Float { didSet { defaults.set(opacity, forKey: Self.opacityKey) } }

    static let modeKey = "maskOverlayMode", swatchKey = "maskOverlaySwatch", opacityKey = "maskOverlayOpacity"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = MaskOverlayMode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .colour
        swatch = defaults.string(forKey: Self.swatchKey).flatMap(Swatch.init(rawValue:)) ?? .red
        opacity = defaults.object(forKey: Self.opacityKey) == nil ? 0.5 : defaults.float(forKey: Self.opacityKey)
    }

    var style: MaskOverlayStyle {
        MaskOverlayStyle(mode: mode, colour: swatch.linear, opacity: opacity)
    }
}
