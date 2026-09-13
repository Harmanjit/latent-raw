import Foundation
import CoreGraphics
import Metal
import simd

/// A local adjustment: a mask and what to do inside it (DESIGN.md §8.4).
///
/// Geometry is in normalized sensor coordinates — (0,0) top-left of the
/// raw frame, (1,1) bottom-right — so it's independent of rotation, zoom
/// and window size, and survives a re-render at any resolution.
public struct LocalAdjustment: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var shape: MaskShape
    public var invert: Bool
    /// Adjustments, applied in scene-linear light where the mask is 1.
    public var exposureEV: Float
    /// -1...1: a gamma around mid grey.
    public var contrast: Float
    /// -1 (grey) ... 1 (double saturation).
    public var saturation: Float
    /// -1 (cooler) ... 1 (warmer).
    public var warmth: Float
    /// Optional refinements that multiply into the geometric mask.
    public var luminanceRange: LuminanceRange?
    public var hueRange: HueRange?

    public init(id: UUID = UUID(), name: String, shape: MaskShape, invert: Bool = false,
                exposureEV: Float = 0, contrast: Float = 0, saturation: Float = 0, warmth: Float = 0,
                luminanceRange: LuminanceRange? = nil, hueRange: HueRange? = nil) {
        self.id = id; self.name = name; self.shape = shape; self.invert = invert
        self.exposureEV = exposureEV; self.contrast = contrast
        self.saturation = saturation; self.warmth = warmth
        self.luminanceRange = luminanceRange; self.hueRange = hueRange
    }

    /// True when the adjustment changes nothing (all sliders at zero).
    public var isNeutral: Bool {
        exposureEV == 0 && contrast == 0 && saturation == 0 && warmth == 0
    }

    /// Limited by the GPU-side array; more would need a different layout.
    public static let maximumCount = 8
}

public enum MaskShape: Equatable, Sendable, Codable {
    /// Full effect at `start`, fading to none at `end`.
    case linear(start: SIMD2<Float>, end: SIMD2<Float>)
    /// Full effect inside the ellipse, fading out over `feather` (0...1 of
    /// the radius). Radii are fractions of the sensor's short side.
    case radial(centre: SIMD2<Float>, radii: SIMD2<Float>, feather: Float)
    /// Painted.
    case brush(strokes: [BrushStroke])
    /// Everywhere — meaningful with a luminance or hue range.
    case whole

    var typeCode: Int32 {
        switch self {
        case .linear: return 1
        case .radial: return 2
        case .brush:  return 3
        case .whole:  return 4
        }
    }
}

/// One brush stroke: dabs along a path. The UI spaces `points` at about a
/// quarter of the radius so the stroke reads as continuous.
public struct BrushStroke: Equatable, Sendable, Codable {
    public var points: [SIMD2<Float>]
    /// Fraction of the sensor's short side.
    public var radius: Float
    /// 0 (hard edge) ... 1 (fully soft).
    public var feather: Float
    /// Opacity each dab adds, 0...1.
    public var flow: Float
    public var erase: Bool

    public init(points: [SIMD2<Float>], radius: Float, feather: Float, flow: Float, erase: Bool) {
        self.points = points; self.radius = radius; self.feather = feather
        self.flow = flow; self.erase = erase
    }
}

/// Restrict a mask to a band of displayed luminance (0 = black, 1 = white),
/// fading in over `feather` on both sides.
public struct LuminanceRange: Equatable, Sendable, Codable {
    public var low: Float
    public var high: Float
    public var feather: Float
    public init(low: Float = 0, high: Float = 1, feather: Float = 0.1) {
        self.low = low; self.high = high; self.feather = feather
    }
}

/// Restrict a mask to hues within `width` degrees of `centre`, and to
/// pixels at least `minimumSaturation` saturated (greys have no hue).
public struct HueRange: Equatable, Sendable, Codable {
    public var centre: Float
    public var width: Float
    public var minimumSaturation: Float
    public init(centre: Float = 30, width: Float = 30, minimumSaturation: Float = 0.1) {
        self.centre = centre; self.width = width; self.minimumSaturation = minimumSaturation
    }
}

// MARK: - GPU packing

/// Mirrors `LocalAdjust` in ColorPipeline.metal: six 16-byte fields.
struct LocalAdjustGPU {
    var geometry0 = SIMD4<Float>(repeating: 0)  // linear: start.xy end.xy | radial: centre.xy radii.xy
    var geometry1 = SIMD4<Float>(repeating: 0)  // radial: feather
    var adjust = SIMD4<Float>(repeating: 0)     // ev, contrast, saturation, warmth
    var lumRange = SIMD4<Float>(repeating: 0)   // low, high, feather, enabled
    var hueRange = SIMD4<Float>(repeating: 0)   // centre, width, minSat, enabled
    var info = SIMD4<Int32>(repeating: 0)       // type, brushSlice, invert, 0

    init(_ local: LocalAdjustment, brushSlice: Int32) {
        switch local.shape {
        case .linear(let s, let e):
            geometry0 = SIMD4(s.x, s.y, e.x, e.y)
        case .radial(let c, let r, let feather):
            geometry0 = SIMD4(c.x, c.y, r.x, r.y)
            geometry1 = SIMD4(feather, 0, 0, 0)
        case .brush, .whole:
            break
        }
        adjust = SIMD4(local.exposureEV, local.contrast, local.saturation, local.warmth)
        if let l = local.luminanceRange { lumRange = SIMD4(l.low, l.high, l.feather, 1) }
        if let h = local.hueRange { hueRange = SIMD4(h.centre, h.width, h.minimumSaturation, 1) }
        info = SIMD4(local.shape.typeCode, brushSlice, local.invert ? 1 : 0, 0)
    }
}

// MARK: - Brush rasterization

/// Turns brush strokes into a greyscale mask texture slice, on the CPU
/// with Core Graphics. Painting adds dabs at the end of the last stroke,
/// so the common update is "draw the new dabs" rather than "redraw
/// everything"; a fingerprint of what's already drawn detects that case.
final class BrushMaskRasterizer {
    /// Mask resolution: a quarter of the sensor on each axis. A brush has
    /// no detail finer than that, and it keeps 8 slices under ~15 MB.
    static let downscale = 4

    let width: Int
    let height: Int
    private let context: CGContext
    private var drawnFingerprint: [StrokeFingerprint] = []
    private var drawnPointsInLast = 0

    struct StrokeFingerprint: Equatable {
        let radius: Float, feather: Float, flow: Float, erase: Bool
        let first: SIMD2<Float>
        init(_ s: BrushStroke) {
            radius = s.radius; feather = s.feather; flow = s.flow; erase = s.erase
            first = s.points.first ?? SIMD2(-1, -1)
        }
    }

    init?(sensorWidth: Int, sensorHeight: Int) {
        width = max(1, sensorWidth / Self.downscale)
        height = max(1, sensorHeight / Self.downscale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // Core Graphics has y up; masks are y down like everything else.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context = ctx
    }

    var bytesPerRow: Int { context.bytesPerRow }
    var data: UnsafeMutableRawPointer? { context.data }

    /// Brings the bitmap up to date with `strokes`. Returns true if
    /// anything was drawn (so the texture needs re-uploading).
    func update(strokes: [BrushStroke]) -> Bool {
        let fingerprints = strokes.map(StrokeFingerprint.init)
        let extendsDrawn = !strokes.isEmpty
            && fingerprints == drawnFingerprint
            && strokes.last!.points.count >= drawnPointsInLast
        let extendsWithNewStroke = strokes.count == drawnFingerprint.count + 1
            && Array(fingerprints.dropLast()) == drawnFingerprint
            && (drawnFingerprint.isEmpty || drawnPointsInLast == strokeBefore(strokes).count)

        if extendsDrawn {
            let last = strokes[strokes.count - 1]
            let newPoints = last.points[drawnPointsInLast...]
            if newPoints.isEmpty { return false }
            draw(last, points: Array(newPoints))
            drawnPointsInLast = last.points.count
            return true
        }
        if extendsWithNewStroke {
            let last = strokes[strokes.count - 1]
            draw(last, points: last.points)
            drawnFingerprint = fingerprints
            drawnPointsInLast = last.points.count
            return true
        }
        // Anything else: start over.
        context.setBlendMode(.normal)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for stroke in strokes { draw(stroke, points: stroke.points) }
        drawnFingerprint = fingerprints
        drawnPointsInLast = strokes.last?.points.count ?? 0
        return true
    }

    private func strokeBefore(_ strokes: [BrushStroke]) -> [SIMD2<Float>] {
        strokes.count >= 2 ? strokes[strokes.count - 2].points : []
    }

    /// Each dab is a radial gradient. Painting uses `lighten`, which adds
    /// coverage up to 1 without ever exceeding it; erasing multiplies
    /// what's there by (1 − dab), which `darken` with black achieves.
    private func draw(_ stroke: BrushStroke, points: [SIMD2<Float>]) {
        let radiusPx = CGFloat(stroke.radius) * CGFloat(min(width, height))
        guard radiusPx > 0.5 else { return }
        let inner = CGFloat(1 - min(max(stroke.feather, 0), 1))
        let flow = CGFloat(min(max(stroke.flow, 0), 1))
        let space = CGColorSpaceCreateDeviceGray()
        let level: CGFloat = stroke.erase ? 0 : 1
        let colors = [CGColor(gray: level, alpha: flow), CGColor(gray: level, alpha: flow),
                      CGColor(gray: level, alpha: 0)] as CFArray
        let locations: [CGFloat] = [0, inner, 1]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        context.setBlendMode(stroke.erase ? .darken : .lighten)
        for p in points {
            let c = CGPoint(x: CGFloat(p.x) * CGFloat(width), y: CGFloat(p.y) * CGFloat(height))
            context.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: radiusPx, options: [])
        }
    }

    /// The mask value at a normalized coordinate, for tests.
    func value(atNormalized p: SIMD2<Float>) -> Float {
        guard let data else { return 0 }
        let x = min(max(Int(p.x * Float(width)), 0), width - 1)
        let y = min(max(Int(p.y * Float(height)), 0), height - 1)
        return Float(data.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)) / 255
    }
}

/// Owns the brush-mask texture array for one image and keeps its slices
/// in step with the brush locals in the current parameters.
final class BrushMaskSet {
    let texture: MTLTexture
    private var rasterizers: [UUID: (slice: Int, raster: BrushMaskRasterizer)] = [:]
    private let sensorWidth: Int, sensorHeight: Int

    init?(device: MTLDevice, sensorWidth: Int, sensorHeight: Int) {
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .r8Unorm
        d.width = max(1, sensorWidth / BrushMaskRasterizer.downscale)
        d.height = max(1, sensorHeight / BrushMaskRasterizer.downscale)
        d.arrayLength = LocalAdjustment.maximumCount
        d.storageMode = .shared
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
    }

    /// Updates slices for every brush local and returns local id -> slice.
    func sync(locals: [LocalAdjustment]) -> [UUID: Int32] {
        var assignment: [UUID: Int32] = [:]
        var usedSlices = Set(rasterizers.values.map(\.slice))
        // Drop rasterizers for locals that no longer exist.
        let live = Set(locals.map(\.id))
        for id in rasterizers.keys where !live.contains(id) {
            usedSlices.remove(rasterizers[id]!.slice)
            rasterizers[id] = nil
        }
        for local in locals {
            guard case .brush(let strokes) = local.shape else { continue }
            let entry: (slice: Int, raster: BrushMaskRasterizer)
            if let existing = rasterizers[local.id] {
                entry = existing
            } else {
                guard let slice = (0..<LocalAdjustment.maximumCount).first(where: { !usedSlices.contains($0) }),
                      let raster = BrushMaskRasterizer(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
                else { continue }
                usedSlices.insert(slice)
                entry = (slice, raster)
                rasterizers[local.id] = entry
            }
            if entry.raster.update(strokes: strokes), let bytes = entry.raster.data {
                texture.replace(region: MTLRegionMake2D(0, 0, entry.raster.width, entry.raster.height),
                                mipmapLevel: 0, slice: entry.slice, withBytes: bytes,
                                bytesPerRow: entry.raster.bytesPerRow, bytesPerImage: 0)
            }
            assignment[local.id] = Int32(entry.slice)
        }
        return assignment
    }
}
