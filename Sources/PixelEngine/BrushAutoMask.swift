import Foundation
import Metal
import simd

// Auto Mask for the brush, as Lightroom's: with it on, each dab paints only
// where the picture is like the colour and brightness under the brush's
// centre, so a stroke along the edge of a sky stops at the trees.
//
// The stroke stores only the switch (`BrushStroke.autoMask`); the pixels
// are worked out again from the picture whenever the mask is rasterized,
// as model masks are regenerated, so an export never goes stale. What the
// dabs compare against is a guide: the raw itself, demosaiced at the
// brush mask's quarter resolution with the as-shot white balance and no
// other edit, so moving a slider never changes what a stroke covers, and
// the preview and the export (each its own session) build the same one.

/// The picture as Auto Mask sees it: per brush-mask pixel, log brightness
/// and two chromaticities, a byte each.
public struct BrushGuide: Sendable {
    public let id = UUID()
    public let width: Int
    public let height: Int
    /// Three bytes a pixel: log2 brightness over `logRange` stops below 1,
    /// then r / (r + g + b) and b / (r + g + b).
    let data: [UInt8]

    /// Stops of brightness the first byte spans, ending at 1 (white).
    static let logRange: Float = 13

    /// How far two pixels may differ and still count as alike: stops of
    /// brightness, and the summed difference of the two chromaticities.
    static let brightnessTolerance: Float = 0.5
    static let colourTolerance: Float = 0.04

    init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height * 3)
        self.width = width; self.height = height; self.data = data
    }

    /// From camera RGB (four floats a pixel, `sourceWidth × sourceHeight`),
    /// resampled to `width × height` by the nearest pixel.
    init(cameraRGB pixels: [Float], sourceWidth: Int, sourceHeight: Int, width: Int, height: Int) {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let sx = Float(sourceWidth) / Float(width), sy = Float(sourceHeight) / Float(height)
        for y in 0..<height {
            let syi = min(Int((Float(y) + 0.5) * sy), sourceHeight - 1)
            for x in 0..<width {
                let sxi = min(Int((Float(x) + 0.5) * sx), sourceWidth - 1)
                let i = (syi * sourceWidth + sxi) * 4
                let r = max(pixels[i], 0), g = max(pixels[i + 1], 0), b = max(pixels[i + 2], 0)
                let o = (y * width + x) * 3
                let (l, cr, cb) = Self.encode(r: r, g: g, b: b)
                out[o] = l; out[o + 1] = cr; out[o + 2] = cb
            }
        }
        self.init(width: width, height: height, data: out)
    }

    static func encode(r: Float, g: Float, b: Float) -> (UInt8, UInt8, UInt8) {
        let y = 0.25 * r + 0.5 * g + 0.25 * b
        let stops = log2(max(y, 1e-4))
        let l = (stops + logRange) / logRange
        let sum = r + g + b
        let cr = sum > 1e-5 ? r / sum : 1.0 / 3
        let cb = sum > 1e-5 ? b / sum : 1.0 / 3
        func byte(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
        return (byte(l), byte(cr), byte(cb))
    }

    /// Brightness in stops and the two chromaticities at a pixel.
    @inline(__always)
    func values(at x: Int, _ y: Int) -> SIMD3<Float> {
        let o = (y * width + x) * 3
        return SIMD3(Float(data[o]) / 255 * Self.logRange - Self.logRange,
                     Float(data[o + 1]) / 255, Float(data[o + 2]) / 255)
    }

    /// What a dab compares against: the mean over 3×3 pixels around its
    /// centre, so one noisy pixel under the brush doesn't decide.
    func reference(atX cx: Int, y cy: Int) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0)
        var n: Float = 0
        for y in max(cy - 1, 0)...min(cy + 1, height - 1) {
            for x in max(cx - 1, 0)...min(cx + 1, width - 1) {
                sum += values(at: x, y); n += 1
            }
        }
        return n > 0 ? sum / n : SIMD3(0, 1.0 / 3, 1.0 / 3)
    }

    /// 1 where the pixel is like `reference`, falling to 0 as it differs.
    /// Colour counts for less in deep shadow, where noise scatters it.
    @inline(__always)
    func similarity(_ reference: SIMD3<Float>, at x: Int, _ y: Int) -> Float {
        let v = values(at: x, y)
        let dark = min(max((-min(v.x, reference.x) - 6) / 4, 0), 1)
        let d = abs(v.x - reference.x) / Self.brightnessTolerance
            + (abs(v.y - reference.y) + abs(v.z - reference.z)) / (Self.colourTolerance * (1 + 3 * dark))
        let t = min(max((d - 0.6) / 0.8, 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The guide for `session`'s raw at the brush masks' size: a binned
    /// camera-RGB render (no edit but the as-shot white balance) read
    /// back. In the analysis pool, so the textures on screen stay.
    static func build(session: ImageSession, pipeline: RenderPipeline) throws -> BrushGuide {
        let summary = session.file.summary
        let width = max(1, summary.rawWidth / BrushMaskRasterizer.downscale)
        let height = max(1, summary.rawHeight / BrushMaskRasterizer.downscale)
        var sw = 0, sh = 0
        var halfs: [Float16] = []
        try session.withTexturePool(.analysis) {
            let texture = try pipeline.renderCameraRGB(session, scale: .binned(quads: 2), parameters: EditParameters())
            sw = texture.width; sh = texture.height
            halfs = try TextureReadback.float16Pixels(of: texture, gpu: pipeline.gpu)
        }
        session.releasePooledTextures(in: .analysis)
        guard sw > 0, sh > 0, halfs.count == sw * sh * 4 else { throw RenderError.commandBufferFailed }
        return BrushGuide(cameraRGB: halfs.map(Float.init), sourceWidth: sw, sourceHeight: sh,
                          width: width, height: height)
    }
}

extension LocalAdjustment {
    /// Whether any brush stroke in the mask (its own shape or a
    /// component) has Auto Mask on.
    public var usesAutoMask: Bool {
        maskElements.contains { element in
            if case .brush(let strokes) = element.shape { return strokes.contains(where: \.isAutoMasked) }
            return false
        }
    }
}

extension RenderPipeline {
    /// Builds the session's Auto Mask guide the first time an edit needs
    /// one, before the render that needs it starts encoding. A failure
    /// leaves the strokes drawn as plain strokes, and is tried again next
    /// render.
    func prepareBrushGuide(_ session: ImageSession, parameters: EditParameters) {
        guard session.brushGuide == nil,
              parameters.locals.prefix(LocalAdjustment.maximumCount).contains(where: \.usesAutoMask) else { return }
        session.brushGuide = try? BrushGuide.build(session: session, pipeline: self)
    }
}

extension BrushMaskRasterizer {
    /// An Auto Mask stroke, dab by dab, straight into the bitmap: the same
    /// falloff, flow, density and blending as the Core Graphics dabs
    /// (`lighten` to paint, multiply by 1 − dab to erase), each pixel's
    /// share scaled by how alike it is to the dab's centre in the guide.
    func drawAutoMasked(_ stroke: BrushStroke, points: [SIMD2<Float>], guide: BrushGuide) {
        guard let base = data?.assumingMemoryBound(to: UInt8.self) else { return }
        let radius = stroke.radius * Float(min(width, height))
        guard radius > 0.5 else { return }
        let rowBytes = bytesPerRow
        let inner = 1 - min(max(stroke.feather, 0), 1)
        let flow = min(max(stroke.flow, 0), 1)
        let level: Float = stroke.erase ? 0 : min(max(stroke.density ?? 1, 0), 1)
        for p in points {
            let cx = p.x * Float(width), cy = p.y * Float(height)
            let ref = guide.reference(atX: min(max(Int(cx), 0), width - 1), y: min(max(Int(cy), 0), height - 1))
            let x0 = max(Int(cx - radius), 0), x1 = min(Int(cx + radius), width - 1)
            let y0 = max(Int(cy - radius), 0), y1 = min(Int(cy + radius), height - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                let dy = Float(y) + 0.5 - cy
                let row = base + y * rowBytes
                for x in x0...x1 {
                    let dx = Float(x) + 0.5 - cx
                    let d = (dx * dx + dy * dy).squareRoot() / radius
                    if d >= 1 { continue }
                    var a = d <= inner || inner >= 1 ? flow : flow * (1 - d) / (1 - inner)
                    a *= guide.similarity(ref, at: x, y)
                    if a <= 0.002 { continue }
                    var v = Float(row[x]) / 255
                    if stroke.erase {
                        v *= 1 - a
                    } else if level > v {
                        v += a * (level - v)
                    }
                    row[x] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                }
            }
        }
    }
}
