import Foundation
import CoreGraphics
import simd

extension RenderPipeline {
    /// The space the lens stage applies `parameters.perspective` in, for
    /// this image: what Upright measures its lines and stores its guides in.
    public func perspectiveSpace(session: ImageSession, parameters: EditParameters) -> PerspectiveSpace {
        let sampling = LensSampling(session: session, parameters: parameters)
        return PerspectiveSpace(sensorSize: CGSize(width: CGFloat(sampling.sensorSize.x),
                                                   height: CGFloat(sampling.sensorSize.y)),
                                autoScale: sampling.autoScale)
    }
}

/// Upright's analysis of a picture: the straight lines in a render made
/// without any perspective correction, in `PerspectiveSpace`.
public enum UprightAnalysis {
    /// Lines in `image`, a render of the whole sensor (at any scale, the
    /// right way round for the sensor, not turned for display), converted
    /// into `space`.
    public static func lines(in image: CGImage, space: PerspectiveSpace) -> [LineSegment] {
        let width = image.width, height = image.height
        guard width >= 8, height >= 8,
              let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colourSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let luminance = LineDetector.luminance(rgba: UnsafeRawBufferPointer(start: data, count: width * height * 4),
                                               width: width, height: height, bytesPerRow: width * 4)
        let found = LineDetector.segments(luminance: luminance, width: width, height: height)
        // Pixels to sensor coordinates (the render covers the whole sensor),
        // then into the perspective space.
        let sx = space.sensorSize.width / CGFloat(width), sy = space.sensorSize.height / CGFloat(height)
        func convert(_ p: SIMD2<Float>) -> SIMD2<Float> {
            space.normalized(CGPoint(x: CGFloat(p.x) * sx, y: CGFloat(p.y) * sy))
        }
        return found.map { LineSegment(convert($0.a), convert($0.b)) }
    }
}

extension CropParameters {
    /// The largest crop of this one's shape (its locked aspect, else its
    /// current proportions) and angle that lies wholly on the picture,
    /// centred where this one is, or on the frame's centre when that
    /// leaves no room: Constrain Crop. `onPicture` says whether an output
    /// sensor point shows real pixels (after lens corrections, keystone
    /// and the Transform sliders, a corner of the frame may show none).
    ///
    /// Checked along all four edges, not only at the corners: with lens
    /// distortion the picture's border is curved, and an edge can cross
    /// it between two corners that are inside.
    public func fitted(sensorSize s: CGSize, onPicture: (CGPoint) -> Bool) -> CropParameters {
        guard s.width > 0, s.height > 0 else { return self }
        let ratio = aspect ?? ratio(sensorSize: s)
        guard ratio > 0, ratio.isFinite else { return self }
        func candidate(height h: Double, centre c: SIMD2<Float>) -> CropParameters {
            CropParameters(centre: c, size: SIMD2(Float(h * Double(ratio) / s.width), Float(h / s.height)),
                           angle: angle, aspect: aspect)
        }
        func fits(_ crop: CropParameters) -> Bool {
            let p = crop.pixelSize(sensorSize: s)
            let c = CGPoint(x: Double(crop.centre.x) * s.width, y: Double(crop.centre.y) * s.height)
            let a = Double(crop.angle) * .pi / 180
            let steps = 16
            for i in 0...steps {
                let t = Double(i) / Double(steps) - 0.5
                for d in [CGPoint(x: t * p.width, y: -p.height / 2), CGPoint(x: t * p.width, y: p.height / 2),
                          CGPoint(x: -p.width / 2, y: t * p.height), CGPoint(x: p.width / 2, y: t * p.height)] {
                    // The crop frame turned by its angle, as `CropFrame` maps it.
                    let point = CGPoint(x: c.x + cos(-a) * d.x - sin(-a) * d.y,
                                        y: c.y + sin(-a) * d.x + cos(-a) * d.y)
                    if !onPicture(point) { return false }
                }
            }
            return true
        }
        // Tallest the shape could be on the sensor at all.
        let largest = max(s.height, s.width / Double(ratio)) * 2
        for c in [centre, SIMD2<Float>(0.5, 0.5)] {
            var lo = 0.0, hi = largest
            guard fits(candidate(height: 8, centre: c)) else { continue }
            lo = 8
            for _ in 0..<32 {
                let mid = (lo + hi) / 2
                if fits(candidate(height: mid, centre: c)) { lo = mid } else { hi = mid }
                if hi - lo < 0.5 { break }
            }
            return candidate(height: lo, centre: c)
        }
        return self
    }

    /// Mirrored left-to-right (`horizontal`) or top-to-bottom about the
    /// sensor's centre, as a flip mirrors the picture under it.
    public func mirrored(horizontal: Bool) -> CropParameters {
        var out = self
        if horizontal { out.centre.x = 1 - centre.x } else { out.centre.y = 1 - centre.y }
        out.angle = -angle
        return out
    }
}

extension PerspectiveCorrection {
    /// Flips the picture as it now looks: the flip itself, and the sliders
    /// that would otherwise act the other way round on the flipped picture
    /// (horizontal keystone, Rotate and X Offset for a left-right flip),
    /// so the result is exactly the mirror image of what was there.
    public mutating func flip(horizontal: Bool) {
        rotate = -rotate
        if horizontal {
            flipHorizontal.toggle()
            self.horizontal = -self.horizontal
            offsetX = -offsetX
        } else {
            flipVertical.toggle()
            vertical = -vertical
            offsetY = -offsetY
        }
    }

    /// Everything the Transform panel's Reset puts back: keystone, sliders,
    /// flips and Upright. Constrain Crop is a preference and stays.
    public mutating func resetTransform() {
        let constrain = constrainCrop
        self = .none
        constrainCrop = constrain
    }

    /// A string that changes whenever the output grid moves: model masks
    /// and touch-up masks made on another grid are made again.
    public var geometryKey: String {
        guard !isIdentity else { return "0" }
        let m = inverseMatrix
        return [m.columns.0, m.columns.1, m.columns.2]
            .flatMap { [$0.x, $0.y, $0.z] }
            .map { String(format: "%.6g", $0) }
            .joined(separator: ",")
    }
}

extension MaskShape {
    /// The shape mirrored about the sensor's centre, as a flip mirrors the
    /// picture under it. Model-made masks keep their prompts mirrored and
    /// are made again on the flipped picture.
    public func mirrored(horizontal: Bool) -> MaskShape {
        func m(_ p: SIMD2<Float>) -> SIMD2<Float> { horizontal ? SIMD2(1 - p.x, p.y) : SIMD2(p.x, 1 - p.y) }
        switch self {
        case .linear(let start, let end):
            return .linear(start: m(start), end: m(end))
        case .radial(let centre, let radii, let feather):
            return .radial(centre: m(centre), radii: radii, feather: feather)
        case .brush(let strokes):
            return .brush(strokes: strokes.map { stroke in
                var s = stroke
                s.points = stroke.points.map(m)
                return s
            })
        case .whole, .ai:
            return self
        case .prompted(let points, let modelVersion):
            return .prompted(points: points.map { p in
                var q = p
                if horizontal { q.x = 1 - p.x } else { q.y = 1 - p.y }
                return q
            }, modelVersion: modelVersion)
        }
    }
}
