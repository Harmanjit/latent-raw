import Foundation
import simd

/// Lens Blur (docs/wiki/Develop.md, "Lens Blur"): a shallow depth of field
/// added after the fact, from a depth map of the photo.
///
/// The edit holds only the sliders and the focus range. The depth map is
/// derived, like a model mask: MLKit makes it from the picture (a depth
/// model when one is installed, else two planes from the subject mask),
/// the session holds it, and the export makes it again. `depthModel`
/// records what made it, so a later change of model is visible.
///
/// Depth runs from 0 (the farthest thing in the frame) to 1 (the
/// nearest). That is the order a depth model's relative inverse depth
/// already has, and it is the scale on which a lens's blur grows evenly:
/// the blur disc's size is proportional to the distance from the focus
/// plane measured in inverse depth.
public struct LensBlur: Codable, Equatable, Sendable {
    /// The shape of an out-of-focus highlight.
    public enum Bokeh: String, Codable, Sendable, CaseIterable, Identifiable {
        /// An even disc, as a modern lens with rounded blades draws it.
        case circle
        /// A disc with a bright rim, as some older and mirror-free designs
        /// draw it ("soap bubble" bokeh).
        case bubble
        /// A pentagon, as a lens with five straight blades stopped down.
        case blades5

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .circle: return "Circle"
            case .bubble: return "Bubble"
            case .blades5: return "5-Blade"
            }
        }

        /// The kernel's shape switch (LensBlur.metal).
        var gpuIndex: UInt32 {
            switch self {
            case .circle: return 0
            case .bubble: return 1
            case .blades5: return 2
            }
        }
    }

    /// 0 (off) … 100: how large the blur grows, up to `maximumRadiusFraction`
    /// of the image's long edge.
    public var amount: Float
    public var bokeh: Bokeh
    /// 0 … 100: how much brighter highlights come out in the blur, so a
    /// point of light opens into a visible disc instead of fading.
    public var boost: Float
    /// The focus range, in depth (0 far … 1 near): everything between the
    /// two stays sharp. `focusFar` ≤ `focusNear`.
    public var focusFar: Float
    public var focusNear: Float
    /// What made the depth map the blur was set on: a model's
    /// "<id>@<version>", or `LensBlur.subjectDepthVersion` for the two
    /// planes made from the subject mask. Nil until the blur first runs.
    public var depthModel: String?

    public init(amount: Float = 0, bokeh: Bokeh = .circle, boost: Float = 0,
                focusFar: Float = LensBlur.defaultFocusFar, focusNear: Float = 1, depthModel: String? = nil) {
        self.amount = amount
        self.bokeh = bokeh
        self.boost = boost
        self.focusFar = focusFar
        self.focusNear = focusNear
        self.depthModel = depthModel
    }

    /// Off: no blur, the nearer half of the scene as the focus range.
    public static let neutral = LensBlur()
    public static let defaultFocusFar: Float = 0.5

    /// The depth the two-plane fallback is recorded as. Not a model: the
    /// subject mask's model is whatever Settings › AI › Models picks.
    public static let subjectDepthVersion = "latent.subjectDepth@1"

    /// The blur at Amount 100, as a fraction of the long edge: 2 % is
    /// about 120 px on a 24 MP frame, the disc a fast portrait lens draws
    /// of a distant background.
    public static let maximumRadiusFraction: Float = 0.02
    /// How far outside the focus range (in depth) the blur reaches its
    /// full size. Nearer than that it grows in proportion.
    public static let fullBlurDepth: Float = 0.35

    /// Whether the stage runs.
    public var isActive: Bool { amount > 0 }

    /// Whether the module is stored at all: anything moved off neutral.
    /// A focus range set with the amount at 0 is kept, so turning the
    /// amount up again finds it.
    public var isNeutral: Bool { self == .neutral }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey { case amount, bokeh, boost, focusFar, focusNear, depthModel }

    /// Lenient: a missing key keeps its default and an unknown bokeh name
    /// reads as a circle, so a sidecar from a later build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 0
        let shape = try c.decodeIfPresent(String.self, forKey: .bokeh) ?? Bokeh.circle.rawValue
        bokeh = Bokeh(rawValue: shape) ?? .circle
        boost = try c.decodeIfPresent(Float.self, forKey: .boost) ?? 0
        focusFar = try c.decodeIfPresent(Float.self, forKey: .focusFar) ?? Self.defaultFocusFar
        focusNear = try c.decodeIfPresent(Float.self, forKey: .focusNear) ?? 1
        depthModel = try c.decodeIfPresent(String.self, forKey: .depthModel)
    }

    /// Values from a file brought into range: a hand-edited amount of a
    /// million must not ask the GPU for a blur larger than the frame.
    public var sanitized: LensBlur {
        var s = self
        func clamped(_ v: Float, _ lo: Float, _ hi: Float, _ fallback: Float) -> Float {
            v.isFinite ? min(max(v, lo), hi) : fallback
        }
        s.amount = clamped(amount, 0, 100, 0)
        s.boost = clamped(boost, 0, 100, 0)
        s.focusFar = clamped(focusFar, 0, 1, Self.defaultFocusFar)
        s.focusNear = clamped(focusNear, 0, 1, 1)
        if s.focusFar > s.focusNear { swap(&s.focusFar, &s.focusNear) }
        return s
    }

    // MARK: - The blur's size

    /// The largest blur radius in sensor pixels, for an image whose long
    /// edge is `longEdge` sensor pixels.
    public func maximumRadius(longEdge: Float) -> Float {
        amount / 100 * Self.maximumRadiusFraction * longEdge
    }

    /// The blur radius at depth `depth`, as a fraction of the maximum
    /// (0 inside the focus range, 1 from `fullBlurDepth` beyond it). The
    /// kernel's `lensBlurCoC` does the same arithmetic.
    public func blurFraction(atDepth depth: Float) -> Float {
        let distance = max(focusFar - depth, depth - focusNear, 0)
        return min(distance / Self.fullBlurDepth, 1)
    }

    /// Sensor pixels the stage reads past a pixel it writes: the largest
    /// blur plus the shrunk copy's own box and filtering. A full
    /// resolution tile adds this to its margin, as it does touch-up's.
    public func reachSensorPixels(longEdge: Float) -> Float {
        guard isActive else { return 0 }
        let radius = maximumRadius(longEdge: longEdge)
        let factor = Float(LensBlurStage.reduction(forRadius: radius))
        return radius + 3 * factor + 2
    }

    /// The focus range centred on `depth`, `width` wide, kept inside 0…1.
    public static func focusRange(around depth: Float, width: Float = 0.16) -> (far: Float, near: Float) {
        let d = min(max(depth, 0), 1)
        var far = d - width / 2, near = d + width / 2
        if far < 0 { near -= far; far = 0 }
        if near > 1 { far -= near - 1; near = 1 }
        return (max(far, 0), min(near, 1))
    }
}

extension EditParameters {
    /// Sensor pixels a full-resolution tile must reach beyond its margin
    /// so every pixel shown is blurred as the whole frame is. Zero while
    /// the blur is off.
    public func lensBlurTileReach(sensorSize: CGSize) -> CGFloat {
        CGFloat(lensBlur.reachSensorPixels(longEdge: Float(max(sensorSize.width, sensorSize.height))))
    }
}

/// A depth map on the output grid (the lens-corrected frame, unrotated),
/// 255 nearest and 0 farthest, at whatever size the model produced. The
/// render samples it by sensor position, as it does the touch-up masks.
public struct DepthMap: Sendable, Equatable {
    public var bitmap: MaskBitmap
    /// What made it: a model's "<id>@<version>" or
    /// `LensBlur.subjectDepthVersion`.
    public var source: String

    public init(bitmap: MaskBitmap, source: String) {
        self.bitmap = bitmap
        self.source = source
    }

    /// The depth (0…1) at a normalised point of the frame, bilinear.
    public func depth(atNormalized p: SIMD2<Float>) -> Float {
        let w = bitmap.width, h = bitmap.height
        let fx = min(max(p.x, 0), 1) * Float(w) - 0.5
        let fy = min(max(p.y, 0), 1) * Float(h) - 0.5
        let x0 = min(max(Int(fx.rounded(.down)), 0), w - 1), y0 = min(max(Int(fy.rounded(.down)), 0), h - 1)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = min(max(fx - Float(x0), 0), 1), ty = min(max(fy - Float(y0), 0), 1)
        let d = bitmap.data
        let a = Float(d[y0 * w + x0]), b = Float(d[y0 * w + x1])
        let c = Float(d[y1 * w + x0]), e = Float(d[y1 * w + x1])
        return ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + e * tx) * ty) / 255
    }

    /// How much of the frame lies at each depth, in `bins` equal steps
    /// from far to near, as fractions summing to 1. The panel draws it
    /// behind the focus range.
    public func histogram(bins: Int = 64) -> [Float] {
        let n = max(bins, 1)
        var counts = [Float](repeating: 0, count: n)
        for v in bitmap.data { counts[min(Int(v) * n / 256, n - 1)] += 1 }
        let total = Float(max(bitmap.data.count, 1))
        return counts.map { $0 / total }
    }

    /// Two planes from a subject mask (255 subject): the subject near,
    /// everything else far, the mask's soft edge between them. What Lens
    /// Blur uses when no depth model is installed.
    public static func twoPlane(fromSubject mask: MaskBitmap) -> DepthMap {
        let far = Float(twoPlaneFar), near = Float(twoPlaneNear)
        let data = mask.data.map { UInt8((far + (near - far) * Float($0) / 255).rounded()) }
        return DepthMap(bitmap: MaskBitmap(width: mask.width, height: mask.height, data: data),
                        source: LensBlur.subjectDepthVersion)
    }

    /// The two planes' depths, in 0…255: far enough apart that the default
    /// focus range keeps the subject sharp and blurs the rest fully.
    public static let twoPlaneFar: UInt8 = 38
    public static let twoPlaneNear: UInt8 = 217
}
