import Foundation
import Metal
import simd

/// The view-only marks the present pass can draw over the picture, beside
/// the clipping overlay (J) it already had: focus peaking, the raw clipping
/// indicator, and how J itself is drawn (`ClippingOptions`). None of them
/// is part of an edit, and the defaults draw exactly what the presenter
/// drew before they existed.
public struct PresentOverlays: Equatable, Sendable {
    /// View › Focus Peaking: edges at least this sharp drawn in a colour
    /// (`PresentFocusPeaking`). nil, off.
    public var focusPeaking: PresentFocusPeaking?
    /// How the clipping overlay (J) decides and colours what it marks.
    public var clipping: ClippingOptions
    /// View › Show Raw Clipping: pixels where a sensor channel reached its
    /// clip level, from the mask a layer carries (`PresentLayer.rawClipMask`),
    /// in magenta. A layer without a mask shows nothing.
    public var rawClipping: Bool

    public init(focusPeaking: PresentFocusPeaking? = nil, clipping: ClippingOptions = .standard,
                rawClipping: Bool = false) {
        self.focusPeaking = focusPeaking
        self.clipping = clipping
        self.rawClipping = rawClipping
    }

    /// Nothing beyond what J draws by default.
    public static let none = PresentOverlays()

    /// The colour raw clipping is marked in: magenta, unlike J's red and
    /// blue, so the two can be told apart when both are on.
    public static let rawClippingColour = SIMD3<Float>(1, 0, 1)
}

/// Focus peaking: the gradient of the displayed picture's lightness, and
/// a colour where it is steep, as darktable and mirrorless viewfinders
/// draw it, to see at a glance what is in focus.
public struct PresentFocusPeaking: Equatable, Sendable {
    public enum Sensitivity: String, CaseIterable, Sendable, Identifiable {
        case low, medium, high
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }

        /// The smallest normalised Sobel magnitude (0 to 1 of a step from
        /// black to white across one pixel) that counts as an edge. High
        /// sensitivity marks softer edges too.
        public var threshold: Float {
            switch self {
            case .low: 0.22
            case .medium: 0.14
            case .high: 0.08
            }
        }
    }

    /// Linear Display P3, as the drawable takes it.
    public var colour: SIMD3<Float>
    public var sensitivity: Sensitivity

    public init(colour: SIMD3<Float>, sensitivity: Sensitivity = .medium) {
        self.colour = colour
        self.sensitivity = sensitivity
    }
}

/// How the clipping overlay (J) marks the picture: what counts as clipped
/// (`Mode`), where (the thresholds), and in which colours (`Scheme`). The
/// standard options are what J has always drawn: a channel at the top in
/// red, a pixel whose every channel is black in blue.
public struct ClippingOptions: Equatable, Sendable, Codable {
    public enum Mode: String, CaseIterable, Sendable, Codable, Identifiable {
        /// Highlights where any channel reaches the top, shadows where every
        /// channel is at the bottom (the standard).
        case anyChannel
        /// The pixel's luminance against the two thresholds.
        case luminance
        /// Colours pressed against the gamut: a channel at the top while
        /// the colour is saturated, or a channel outside Display P3, in the
        /// highlight colour; a channel at the bottom while another is
        /// above it, in the shadow colour.
        case saturation
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .anyChannel: "Any channel"
            case .luminance: "Luminance"
            case .saturation: "Saturation (gamut)"
            }
        }
        var gpuValue: UInt32 {
            switch self {
            case .anyChannel: 0
            case .luminance: 1
            case .saturation: 2
            }
        }
    }

    public enum Scheme: String, CaseIterable, Sendable, Codable, Identifiable {
        case redBlue, magentaCyan, mono
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .redBlue: "Red and blue"
            case .magentaCyan: "Magenta and cyan"
            case .mono: "Black and white"
            }
        }
        /// Linear Display P3: highlights, then shadows. Mono marks clipped
        /// highlights black and crushed shadows white, so each shows
        /// against what it replaces.
        public var colours: (highlights: SIMD3<Float>, shadows: SIMD3<Float>) {
            switch self {
            case .redBlue: (SIMD3(1, 0, 0), SIMD3(0, 0.3, 1))
            case .magentaCyan: (SIMD3(1, 0, 1), SIMD3(0, 1, 1))
            case .mono: (SIMD3(0, 0, 0), SIMD3(1, 1, 1))
            }
        }
    }

    public var mode: Mode
    /// Shadows at or below this share of the encoded range, 0 to 0.05.
    public var shadowThreshold: Float
    /// Highlights at or above this share of the encoded range, 0.95 to 1.
    public var highlightThreshold: Float
    public var scheme: Scheme

    public static let shadowRange: ClosedRange<Float> = 0...0.05
    public static let highlightRange: ClosedRange<Float> = 0.95...1

    public init(mode: Mode = .anyChannel, shadowThreshold: Float = 0, highlightThreshold: Float = 1,
                scheme: Scheme = .redBlue) {
        self.mode = mode
        self.shadowThreshold = min(max(shadowThreshold, Self.shadowRange.lowerBound), Self.shadowRange.upperBound)
        self.highlightThreshold = min(max(highlightThreshold, Self.highlightRange.lowerBound), Self.highlightRange.upperBound)
        self.scheme = scheme
    }

    public static let standard = ClippingOptions()

    /// The linear value a highlight must reach, as a share of the layer's
    /// ceiling. At 100% it is the histogram's own line (0.9955 encodes to
    /// 254.5/255), so the standard options mark what they always have.
    public var highlightLinear: Float {
        highlightThreshold >= 1 ? 0.9955 : Self.decodeSRGB(highlightThreshold - 0.5 / 255)
    }

    /// The linear value a shadow must stay under. At 0% it is the
    /// histogram's line (0.000152 encodes to 0.5/255).
    public var shadowLinear: Float {
        shadowThreshold <= 0 ? 0.000152 : Self.decodeSRGB(shadowThreshold + 0.5 / 255)
    }

    static func decodeSRGB(_ v: Float) -> Float {
        let x = min(max(v, 0), 1)
        return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
    }
}

/// Laid out as `PresentOptions` in Present.metal: four float4 then four uints.
struct PresentOptionsGPU {
    /// Peaking colour, and its threshold in w (0: off).
    var peak: SIMD4<Float>
    /// Highlight colour, and the linear threshold in w.
    var clipHigh: SIMD4<Float>
    /// Shadow colour, and the linear threshold in w.
    var clipLow: SIMD4<Float>
    /// Raw clipping colour.
    var raw: SIMD4<Float>
    var clipMode: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0

    init(_ overlays: PresentOverlays) {
        let colours = overlays.clipping.scheme.colours
        peak = SIMD4(overlays.focusPeaking?.colour ?? .zero, overlays.focusPeaking?.sensitivity.threshold ?? 0)
        clipHigh = SIMD4(colours.highlights, overlays.clipping.highlightLinear)
        clipLow = SIMD4(colours.shadows, overlays.clipping.shadowLinear)
        raw = SIMD4(PresentOverlays.rawClippingColour, 0)
        clipMode = overlays.clipping.mode.gpuValue
    }
}
