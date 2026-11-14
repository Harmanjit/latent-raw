import Foundation
import simd

/// Lens Blur's blur types (docs/wiki/Develop.md, "Lens Blur"): Bokeh, the
/// depth-driven disc it always drew, plus Gaussian and Motion. All three
/// take Amount as their size (Gaussian's radius, Motion's length) and keep
/// the focus range sharp over a depth map; Gaussian and Motion, unlike
/// Bokeh, also run without one, blurring the whole frame evenly.
extension LensBlur {
    public enum BlurType: String, Codable, Sendable, CaseIterable, Identifiable {
        /// A disc in the bokeh's shape, sized by depth.
        case bokeh
        /// A soft Gaussian: no bright-edged discs, just softness.
        case gaussian
        /// A streak along `motionAngle`, as if the camera or the subject
        /// moved during the exposure.
        case motion

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .bokeh: return "Bokeh"
            case .gaussian: return "Gaussian"
            case .motion: return "Motion"
            }
        }

        /// The kernel's switch (LensBlur.metal).
        var gpuIndex: UInt32 {
            switch self {
            case .bokeh: return 0
            case .gaussian: return 1
            case .motion: return 2
            }
        }
    }

    /// `blurType` with nil read as Bokeh.
    public var effectiveBlurType: BlurType { blurType ?? .bokeh }

    /// `motionAngle` with nil read as 0, in 0…180.
    public var effectiveMotionAngle: Float { motionAngle ?? 0 }

    /// Whether the stage runs without a depth map, over the whole frame:
    /// Gaussian and Motion do; Bokeh needs depth to know what to blur.
    public var blursWithoutDepth: Bool { isActive && effectiveBlurType != .bokeh }

    /// Motion's unit direction on the render grid (y down), from its angle
    /// measured anticlockwise from horizontal, as on screen.
    var motionDirection: SIMD2<Float> {
        let radians = effectiveMotionAngle * .pi / 180
        return SIMD2(cos(radians), -sin(radians))
    }

    /// Bokeh is stored as no type, an angle of 0 as none, and an angle
    /// from a file is folded into 0…180 (a streak has no front or back).
    func sanitizeBlurType(_ s: inout LensBlur) {
        if s.blurType == .bokeh { s.blurType = nil }
        if let a = s.motionAngle {
            var folded = a.isFinite ? a.truncatingRemainder(dividingBy: 180) : 0
            if folded < 0 { folded += 180 }
            s.motionAngle = folded == 0 ? nil : folded
        }
    }
}
