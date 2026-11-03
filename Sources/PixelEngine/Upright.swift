import Foundation
import CoreGraphics
import simd

// MARK: - The stored correction

/// Upright (Lightroom's name for it): a perspective correction found from
/// the straight lines in the picture rather than set by hand.
///
/// The analysis runs once, when the user picks a mode, and its answer is
/// stored as a matrix, so the edit renders and exports the same way on
/// any Mac without the analysis running again. "Update" in the panel
/// runs it again on purpose.
public struct UprightCorrection: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Levels the picture and straightens converging verticals,
        /// holding back on strong convergence so it doesn't look stretched.
        case auto
        /// Rotation only, from the horizontal lines.
        case level
        /// Level, and verticals made parallel.
        case vertical
        /// Verticals and horizontals both made parallel.
        case full
        /// From two to four lines the user draws on the picture.
        case guided

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .auto: "Auto"
            case .level: "Level"
            case .vertical: "Vertical"
            case .full: "Full"
            case .guided: "Guided"
            }
        }
    }

    public var mode: Mode
    /// The output-to-source homography in Upright's normalized space
    /// (`PerspectiveSpace`), nine numbers row by row. Nil when the
    /// analysis found nothing to correct, or Guided has no guides yet.
    public var matrix: [Float]?
    /// Guided mode's lines, in the same space as the analysis: the picture
    /// before any perspective correction, so they stay on the features
    /// they were drawn along whatever the sliders do afterwards.
    public var guides: [UprightGuide]?

    public init(mode: Mode, matrix: [Float]? = nil, guides: [UprightGuide]? = nil) {
        self.mode = mode
        self.matrix = matrix
        self.guides = guides
    }

    /// The most guides Guided Upright takes, as in Lightroom.
    public static let maximumGuides = 4

    /// Stores `inverse` (output to source) as the nine numbers.
    public static func encoded(_ inverse: simd_float3x3) -> [Float] {
        let t = inverse.transpose   // rows become columns
        return [t.columns.0.x, t.columns.0.y, t.columns.0.z,
                t.columns.1.x, t.columns.1.y, t.columns.1.z,
                t.columns.2.x, t.columns.2.y, t.columns.2.z]
    }

    /// Checked when a stack is read: a hand-edited file could hold a
    /// matrix that is not finite, folds the picture over, or guides
    /// beyond any picture.
    var sanitized: UprightCorrection {
        var out = self
        if let m = matrix {
            let ok = m.count == 9 && m.allSatisfy { $0.isFinite && abs($0) < 1e4 }
                && abs(simd_float3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]),
                                            SIMD3(m[6], m[7], m[8])]).determinant) > 1e-6
            if !ok { out.matrix = nil }
        }
        if let g = guides {
            let kept = g.prefix(Self.maximumGuides).filter { $0.isUsable }
            out.guides = kept.isEmpty ? nil : Array(kept)
        }
        return out
    }
}

/// One Guided Upright line, from (x0, y0) to (x1, y1) in `PerspectiveSpace`.
public struct UprightGuide: Codable, Equatable, Sendable {
    public var x0: Float, y0: Float, x1: Float, y1: Float

    public init(x0: Float, y0: Float, x1: Float, y1: Float) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    public init(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        self.init(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }

    public var start: SIMD2<Float> { SIMD2(x0, y0) }
    public var end: SIMD2<Float> { SIMD2(x1, y1) }
    public var segment: LineSegment { LineSegment(start, end) }

    /// Finite, inside a generous box around the picture, and long enough
    /// to have a direction.
    var isUsable: Bool {
        let all = [x0, y0, x1, y1]
        return all.allSatisfy { $0.isFinite && abs($0) < 10 } && simd_distance(start, end) > 1e-3
    }
}

// MARK: - The space Upright works in

/// Upright's coordinates: the point's offset from the sensor's centre,
/// divided by half the short side and multiplied by the lens profile's
/// auto-scale, which is exactly what the lens stage hands its perspective
/// matrix (`RenderPipeline.LensSampling.sourcePoints`). A render without
/// perspective shows the source side of that matrix; a render with it,
/// the output side.
public struct PerspectiveSpace: Equatable, Sendable {
    public var sensorSize: CGSize
    public var autoScale: Float

    public init(sensorSize: CGSize, autoScale: Float = 1) {
        self.sensorSize = sensorSize
        self.autoScale = autoScale
    }

    var halfShort: Float { Float(min(sensorSize.width, sensorSize.height)) / 2 }
    var centre: SIMD2<Float> { SIMD2(Float(sensorSize.width), Float(sensorSize.height)) / 2 }

    public func normalized(_ sensor: CGPoint) -> SIMD2<Float> {
        (SIMD2(Float(sensor.x), Float(sensor.y)) - centre) * autoScale / max(halfShort, 1)
    }

    public func sensorPoint(_ n: SIMD2<Float>) -> CGPoint {
        let p = n * halfShort / max(autoScale, 1e-6) + centre
        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    /// The picture's corners in this space (top-left, top-right,
    /// bottom-right, bottom-left).
    public var corners: [SIMD2<Float>] {
        let w = CGFloat(sensorSize.width), h = CGFloat(sensorSize.height)
        return [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].map(normalized)
    }
}

extension simd_float3x3 {
    /// `p` through the homography, with the divide.
    func applied(to p: SIMD2<Float>) -> SIMD2<Float> {
        let q = self * SIMD3(p.x, p.y, 1)
        let z = abs(q.z) < 1e-6 ? (q.z < 0 ? -1e-6 : 1e-6) : q.z
        return SIMD2(q.x, q.y) / z
    }
}

extension PerspectiveCorrection {
    /// Where an output point of Upright's space reads from on the source
    /// side, and back: the matrix pair, with the divide.
    public func sourcePoint(forOutput p: SIMD2<Float>) -> SIMD2<Float> { inverseMatrix.applied(to: p) }
    public func outputPoint(forSource p: SIMD2<Float>) -> SIMD2<Float> { forwardMatrix.applied(to: p) }
}

// MARK: - Edit stack form

extension EditStack.Perspective {
    init(transform t: PerspectiveCorrection) {
        self.init(vertical: t.vertical, horizontal: t.horizontal)
        rotate = t.rotate == 0 ? nil : t.rotate
        aspect = t.aspect == 0 ? nil : t.aspect
        scale = t.scale == 1 ? nil : t.scale
        offsetX = t.offsetX == 0 ? nil : t.offsetX
        offsetY = t.offsetY == 0 ? nil : t.offsetY
        flipHorizontal = t.flipHorizontal ? true : nil
        flipVertical = t.flipVertical ? true : nil
        upright = t.upright
        constrainCrop = t.constrainCrop ? true : nil
    }

    /// Back to the render's form, each newer value clamped to its slider's
    /// range so a hand-edited sidecar can't ask for a degenerate transform.
    var correction: PerspectiveCorrection {
        func clamped(_ v: Float?, _ range: ClosedRange<Float>, _ fallback: Float) -> Float {
            guard let v, v.isFinite else { return fallback }
            return min(max(v, range.lowerBound), range.upperBound)
        }
        // The keystone pair is read as it always was, unclamped, so an old
        // edit renders exactly as before.
        var t = PerspectiveCorrection(vertical: vertical, horizontal: horizontal)
        t.rotate = clamped(rotate, TransformRanges.rotate, 0)
        t.aspect = clamped(aspect, TransformRanges.aspect, 0)
        t.scale = clamped(scale, TransformRanges.scale, 1)
        t.offsetX = clamped(offsetX, TransformRanges.offset, 0)
        t.offsetY = clamped(offsetY, TransformRanges.offset, 0)
        t.flipHorizontal = flipHorizontal ?? false
        t.flipVertical = flipVertical ?? false
        t.upright = upright?.sanitized
        t.constrainCrop = constrainCrop ?? false
        return t
    }
}

/// The Transform sliders' ranges, shared by the panel and the reader.
public enum TransformRanges {
    public static let rotate: ClosedRange<Float> = -10...10
    public static let aspect: ClosedRange<Float> = -1...1
    public static let scale: ClosedRange<Float> = 0.5...1.5
    public static let offset: ClosedRange<Float> = -1...1
}
