import Foundation
import CoreGraphics
import Metal
import simd

/// A local adjustment: a mask and what to do inside it (DESIGN.md §8.4).
///
/// Geometry is in normalized sensor coordinates — (0,0) top-left of the
/// sensor plane (the camera's active area), (1,1) bottom-right — so it's
/// independent of rotation, zoom and window size, and survives a
/// re-render at any resolution.
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

    // Added with mask components and the wider slider set
    // (MaskComponents.swift). Every one defaults to "nothing" and is
    // written to the edit only when set (LocalAdjustment+Codable.swift),
    // so an edit made before them loads, saves and renders as it did.

    /// More shapes combined with `shape` in order: added, subtracted or
    /// intersected. `shape` with `invert` is always the first component.
    public var components: [MaskComponent] = []
    /// Inverts the combined mask (shape and components) before the
    /// luminance and hue ranges narrow it. Duplicate and Invert sets it
    /// on a mask with components; with none, `invert` does the same job.
    public var invertMask = false
    /// 0…1: how strongly the mask applies its sliders. 1 is full.
    public var amount: Float = 1
    /// Feather (0…1) and Edge (−1 contract … 1 expand) for a model mask
    /// in `shape`; components carry their own.
    public var modelFeather: Float = 0
    public var modelEdge: Float = 0
    /// Hidden masks keep their settings but change nothing.
    public var hidden = false
    /// Light: the global Highlights, Shadows, Whites and Blacks, inside the mask. −1…1.
    public var highlights: Float = 0
    public var shadows: Float = 0
    public var whites: Float = 0
    public var blacks: Float = 0
    /// Colour: green (−1) … magenta (1), and a hue rotation in degrees (−180…180).
    public var tint: Float = 0
    public var hue: Float = 0
    /// Effects and detail, −1…1 (noise and defringe 0…1): the presence and
    /// sharpening kernels inside the mask (LocalDetailStage.swift).
    public var texture: Float = 0
    public var clarity: Float = 0
    public var dehaze: Float = 0
    public var sharpness: Float = 0
    public var noise: Float = 0
    public var defringe: Float = 0
    /// A point curve inside the mask: master, and red, green and blue
    /// (Lightroom's Curve in a mask), on the same display-referred,
    /// gamma 2.2 scale as the global curve. nil is a straight line.
    public var curve: ToneCurve?
    public var channelCurves: RGBCurves?
    /// Point Colour swatches that act only inside the mask, at most
    /// `maximumPointColours`.
    public var pointColours: [PointColour] = []
    /// Grain inside the mask, its own amount, size and roughness, on top
    /// of any global grain. nil is none.
    public var grain: Grain?

    // Added with mask blending and management (MaskBlend.swift,
    // MaskLinks.swift, MaskRefine.swift). Each is neutral by default and
    // written to the edit only when set, so older edits are unchanged.

    /// How the mask's result joins the picture: Normal, or keeping only
    /// its change of colour or only its change of lightness.
    public var blendMode: LocalBlendMode = .normal
    /// 0…1: an edge-preserving smoothing inside the mask
    /// (LocalDetailStage.swift), up to about 20 sensor pixels.
    public var smooth: Float = 0
    /// 0…1: snaps a brush or model mask in `shape` to the picture's edges
    /// with a guided filter (MaskRefine.swift). Components carry their own.
    public var edgeRefine: Float = 0

    /// The tone equalizer's nine band gains (EV, −3…3, the −8 EV band
    /// first) inside this mask (LocalToneEqualizer.swift). Read from the
    /// global tone equalizer's mask, so they move the same tones its bands
    /// do, but only where this mask is. nil while every band is 0, and
    /// then not written to the edit.
    public var toneEqualizerBands: [Float]?

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
            && pointSlidersNeutral && !wantsDetailStage && !hasToneEqualizerBands
    }

    /// The sliders the colour kernel applies beyond the original four.
    var pointSlidersNeutral: Bool {
        highlights == 0 && shadows == 0 && whites == 0 && blacks == 0 && tint == 0 && hue == 0
    }

    /// Whether any slider needs the neighbourhood (a blur), so the local
    /// detail stage runs after the colour kernel for this mask.
    public var wantsDetailStage: Bool {
        !hidden && amount > 0 && (texture != 0 || clarity != 0 || dehaze != 0 || sharpness != 0
            || noise > 0 || defringe > 0 || smooth > 0 || wantsToneColourStage)
    }

    /// Limited by the GPU-side array; more would need a different layout.
    public static let maximumCount = 8
}

public enum MaskShape: Equatable, Sendable, Codable {
    /// Full effect at `start`, fading to none at `end`.
    case linear(start: SIMD2<Float>, end: SIMD2<Float>)
    /// Full effect inside the ellipse, fading out over `feather` (0...1 of
    /// the radius). Radii are fractions of the sensor's short side.
    /// `angle` turns the ellipse, in degrees clockwise on the sensor (y
    /// down); nil is 0, and is what an edit made before rotation stores,
    /// so such an edit reads and writes exactly as it did
    /// (MaskShapeGeometry.swift has the helpers).
    case radial(centre: SIMD2<Float>, radii: SIMD2<Float>, feather: Float, angle: Float? = nil)
    /// Painted.
    case brush(strokes: [BrushStroke])
    /// Everywhere — meaningful with a luminance or hue range.
    case whole
    /// Generated by a model ("subject", "person", "sky"). The stored
    /// parameter is the *kind*; the pixels are regenerated from the image
    /// on demand and cached in memory (DESIGN.md §8.4). `modelVersion`
    /// records what produced it so a future model change is visible.
    case ai(kind: String, modelVersion: String)
    /// Click-to-select (Segment Anything): the clicks are the parameters;
    /// the pixels are decoded from them and cached like `.ai`.
    case prompted(points: [MaskPromptPoint], modelVersion: String)

    var typeCode: Int32 {
        switch self {
        case .linear: return 1
        case .radial: return 2
        case .brush:  return 3
        case .whole:  return 4
        case .ai, .prompted: return 3   // sampled from a mask slice, like a brush
        }
    }

    /// Whether this shape's pixels live in a mask texture slice.
    var usesMaskSlice: Bool {
        switch self {
        case .brush, .ai, .prompted: return true
        default: return false
        }
    }

    /// Whether the pixels come from a model (and may need generating).
    public var isModelGenerated: Bool {
        switch self {
        case .ai, .prompted: return true
        default: return false
        }
    }
}

/// A click for a prompted mask, in normalized sensor coordinates.
public struct MaskPromptPoint: Equatable, Sendable, Codable {
    public var x: Float
    public var y: Float
    public var foreground: Bool
    /// Set for the two corners of a Select Objects box: 1 top-left,
    /// 2 bottom-right. nil for a click, so older edits read as before.
    public var corner: Int?
    public init(x: Float, y: Float, foreground: Bool) { self.x = x; self.y = y; self.foreground = foreground }
    public init(x: Float, y: Float, corner: Int) {
        self.x = x; self.y = y; self.foreground = true; self.corner = corner
    }
}

/// A greyscale mask as pixels, 0...255, row-major.
public struct MaskBitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let data: [UInt8]
    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height)
        self.width = width; self.height = height; self.data = data
    }

    /// Fraction of pixels above half — a quick "how much did it select".
    public var coverage: Double {
        Double(data.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }) / Double(max(data.count, 1))
    }

    /// Bilinear resample to another size.
    public func resampled(width w: Int, height h: Int) -> MaskBitmap {
        if w == width && h == height { return self }
        var out = [UInt8](repeating: 0, count: w * h)
        let sx = Float(width) / Float(w), sy = Float(height) / Float(h)
        for y in 0..<h {
            let fy = (Float(y) + 0.5) * sy - 0.5
            let y0 = max(Int(fy.rounded(.down)), 0), y1 = min(y0 + 1, height - 1)
            let ty = max(fy - Float(y0), 0)
            for x in 0..<w {
                let fx = (Float(x) + 0.5) * sx - 0.5
                let x0 = max(Int(fx.rounded(.down)), 0), x1 = min(x0 + 1, width - 1)
                let tx = max(fx - Float(x0), 0)
                let a = Float(data[y0 * width + x0]), b = Float(data[y0 * width + x1])
                let c = Float(data[y1 * width + x0]), d = Float(data[y1 * width + x1])
                let v = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                out[y * w + x] = UInt8(min(max(v, 0), 255))
            }
        }
        return MaskBitmap(width: w, height: h, data: out)
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
    /// Auto Mask: each dab paints only where the picture is like the
    /// colour and brightness under the brush's centre (BrushAutoMask.swift).
    /// nil is off, as every stroke was before.
    public var autoMask: Bool?
    /// The most coverage the stroke can build up, 0…1 (Lightroom's
    /// Density): painting over it again never goes past. nil is full, as
    /// every stroke was before.
    public var density: Float?

    public init(points: [SIMD2<Float>], radius: Float, feather: Float, flow: Float, erase: Bool,
                density: Float? = nil, autoMask: Bool? = nil) {
        self.points = points; self.radius = radius; self.feather = feather
        self.flow = flow; self.erase = erase; self.density = density
        self.autoMask = autoMask == true ? true : nil
    }

    var isAutoMasked: Bool { autoMask == true }
}

/// Restrict a mask to a band of displayed luminance (0 = black, 1 = white),
/// fading in over `feather` on both sides.
public struct LuminanceRange: Equatable, Sendable, Codable {
    public var low: Float
    public var high: Float
    public var feather: Float
    /// Separate fades below `low` and above `high` (the four-handle range
    /// control). nil is `feather`, as every range made before them was, so
    /// they are written only when set (ChannelRange.swift has the helpers).
    public var featherLow: Float?
    public var featherHigh: Float?
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

/// Mirrors `LocalAdjust` in ColorPipeline.metal: nine 16-byte fields.
/// The first six are the original layout; the last three carry the
/// components, the wider slider set and the detail-stage slot, and are
/// all neutral for an edit that uses none of them.
struct LocalAdjustGPU {
    var geometry0 = SIMD4<Float>(repeating: 0)  // linear: start.xy end.xy | radial: centre.xy radii.xy
    var geometry1 = SIMD4<Float>(repeating: 0)  // radial: feather
    var adjust = SIMD4<Float>(repeating: 0)     // ev, contrast, saturation, warmth
    var lumRange = SIMD4<Float>(repeating: 0)   // low, high, feather, enabled
    var hueRange = SIMD4<Float>(repeating: 0)   // centre, width, minSat, enabled
    var info = SIMD4<Int32>(repeating: 0)       // type, brushSlice, invert, blend mode
    var adjust2 = SIMD4<Float>(repeating: 0)    // tint, highlights, shadows, whites
    var adjust3 = SIMD4<Float>(1, 0, 1, 0)      // amount, blacks, luminance range high feather, hue (degrees)
    var info2 = SIMD4<Int32>(0, 0, -1, 0)       // componentStart, componentCount, detailSlot, invertMask

    init(_ local: LocalAdjustment, brushSlice: Int32) {
        geometry0 = MaskComponentGPU.geometry0(local.shape)
        geometry1 = MaskComponentGPU.geometry1(local.shape)
        adjust = SIMD4(local.exposureEV, local.contrast, local.saturation, local.warmth)
        if let l = local.luminanceRange { lumRange = SIMD4(l.low, l.high, l.lowFeather, 1) }
        if let h = local.hueRange { hueRange = SIMD4(h.centre, h.width, h.minimumSaturation, 1) }
        info = SIMD4(local.shape.typeCode, brushSlice, local.invert ? 1 : 0, local.blendMode.gpuCode)
        adjust2 = SIMD4(local.tint, local.highlights, local.shadows, local.whites)
        // A hidden mask applies nothing; its shape still shows as an overlay.
        // The range's fade above High rides in the spare slot; it equals
        // the fade below Low unless the two were set apart.
        adjust3 = SIMD4(local.hidden ? 0 : min(max(local.amount, 0), 1), local.blacks,
                        local.luminanceRange?.highFeather ?? 0, local.hue)
        info2 = SIMD4(0, 0, -1, local.invertMask ? 1 : 0)
    }
}

/// Mirrors `MaskComponentGPU` in ColorPipeline.metal: four 16-byte fields.
struct MaskComponentGPU {
    var geometry0 = SIMD4<Float>(repeating: 0)  // shape geometry | lum, channel: low, high, low feather, high feather | colour: h,s,h,s
    var geometry1 = SIMD4<Float>(repeating: 0)  // radial feather, angle (radians) | colour: h,s,h,s
    var extra = SIMD4<Float>(repeating: 0)      // colour: h, s, radius, sample count | channel: channel id
    /// x: 1-4 shapes, 5 luminance, 6 colour, 7 a linked mask's hue range
    /// (MaskLinks.swift), 8 channel range (ChannelRange.swift).
    /// z: bit 0 invert; bits 1-4 a linked mask's group (MaskLinks.swift).
    /// w: 0 add, 1 subtract, 2 intersect, 3 sum, 4 exclusion.
    var info = SIMD4<Int32>(repeating: 0)       // type, slice, invert and group flags, mode

    /// Every mask's components, flattened, fit one `setBytes` (4 KB).
    static let maximumTotal = LocalAdjustment.maximumCount * MaskComponent.maximumPerMask
    /// A Channel Range component's type (7 is a linked mask's hue range,
    /// `MaskLinks.hueRangeType`).
    static let channelRangeType: Int32 = 8

    /// What is bound when no mask has components: Metal wants the buffer.
    init() {}

    init(_ component: MaskComponent, slice: Int32) {
        var type: Int32
        switch component.source {
        case .shape(let shape):
            type = shape.typeCode
            geometry0 = Self.geometry0(shape)
            geometry1 = Self.geometry1(shape)
        case .luminance(let l):
            type = 5
            geometry0 = SIMD4(l.low, l.high, l.lowFeather, l.highFeather)
        case .colour(let r):
            type = 6
            var hs = [Float](repeating: 0, count: 10)
            for (k, sample) in r.samples.prefix(ColourRange.maximumSamples).enumerated() {
                hs[2 * k] = sample.hue; hs[2 * k + 1] = sample.saturation
            }
            geometry0 = SIMD4(hs[0], hs[1], hs[2], hs[3])
            geometry1 = SIMD4(hs[4], hs[5], hs[6], hs[7])
            extra = SIMD4(hs[8], hs[9], r.radius, Float(min(r.samples.count, ColourRange.maximumSamples)))
        case .channel(let r):
            type = Self.channelRangeType
            geometry0 = SIMD4(r.low, r.high, r.lowFeather, r.highFeather)
            extra = SIMD4(Float(r.channel.gpuID), 0, 0, 0)
        case .mask:
            // Inlined by `LocalsGPUPlan` (MaskLinks.swift); never packed
            // itself. Type 0 masks nothing.
            type = 0
        }
        info = SIMD4(type, slice, component.invert ? 1 : 0, component.mode.gpuCode)
    }

    static func geometry0(_ shape: MaskShape) -> SIMD4<Float> {
        switch shape {
        case .linear(let s, let e): return SIMD4(s.x, s.y, e.x, e.y)
        case .radial(let c, let r, _, _): return SIMD4(c.x, c.y, r.x, r.y)
        default: return SIMD4(repeating: 0)
        }
    }

    static func geometry1(_ shape: MaskShape) -> SIMD4<Float> {
        // The angle is 0 for an edit made before rotation, which the shader
        // skips, so such an ellipse renders exactly as it did.
        if case .radial(_, _, let feather, let angle) = shape {
            return SIMD4(feather, (angle ?? 0) * .pi / 180, 0, 0)
        }
        return SIMD4(repeating: 0)
    }
}

/// Everything the colour kernel needs about the locals, packed: one entry
/// per local, their components flattened after one another, and how many
/// locals write a mask for the detail stage.
struct LocalsGPUPlan {
    var locals: [LocalAdjustGPU]
    var components: [MaskComponentGPU]
    /// Local index -> slot (0…7) in the detail stage's mask textures.
    var detailSlots: [Int: Int]
    /// Per local, per component: its first entry's index among the local's
    /// packed components (a linked mask's group takes several), nil when it
    /// packed as nothing. Show Channel uses it (ChannelRange.swift).
    var componentOffsets: [[Int?]]

    init(locals: [LocalAdjustment], slices: [UUID: Int32]) {
        self.locals = []
        components = []
        detailSlots = [:]
        componentOffsets = []
        for (index, local) in locals.enumerated() {
            var packed = LocalAdjustGPU(local, brushSlice: slices[local.id] ?? -1)
            let room = MaskComponentGPU.maximumTotal - components.count
            // Each component packs as one entry, a linked mask as its
            // inlined group (MaskLinks.swift); whole groups only.
            let (own, offsets) = MaskLinks.packedComponentsAndOffsets(
                of: local, in: locals, slices: slices,
                limit: min(MaskComponent.maximumPerMask, max(room, 0)))
            componentOffsets.append(offsets)
            if !own.isEmpty {
                packed.info2.x = Int32(components.count)
                packed.info2.y = Int32(own.count)
                components += own
            }
            if local.wantsDetailStage {
                let slot = detailSlots.count
                detailSlots[index] = slot
                packed.info2.z = Int32(slot)
            }
            self.locals.append(packed)
        }
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
    /// The guide Auto Mask strokes were drawn against; a different one
    /// (or the first, after drawing without) redraws everything.
    private var drawnGuide: UUID?
    private var guide: BrushGuide?

    struct StrokeFingerprint: Equatable {
        let radius: Float, feather: Float, flow: Float, erase: Bool, density: Float?, autoMask: Bool
        let first: SIMD2<Float>
        init(_ s: BrushStroke) {
            radius = s.radius; feather = s.feather; flow = s.flow; erase = s.erase; density = s.density
            autoMask = s.isAutoMasked
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

    /// How `update` would bring the bitmap up to date with `strokes`:
    /// nothing to do, draw only what was added, or redraw everything.
    enum Plan: Equatable { case upToDate, appendPoints, appendStroke, redraw }

    func plan(strokes: [BrushStroke], guide: BrushGuide? = nil) -> Plan {
        let fingerprints = strokes.map(StrokeFingerprint.init)
        let usesGuide = strokes.contains(where: \.isAutoMasked)
        let guideChanged = usesGuide && guide?.id != drawnGuide
        let extendsDrawn = !guideChanged && !strokes.isEmpty
            && fingerprints == drawnFingerprint
            && strokes.last!.points.count >= drawnPointsInLast
        let extendsWithNewStroke = !guideChanged && strokes.count == drawnFingerprint.count + 1
            && Array(fingerprints.dropLast()) == drawnFingerprint
            && (drawnFingerprint.isEmpty || drawnPointsInLast == strokeBefore(strokes).count)
        if extendsDrawn {
            return strokes[strokes.count - 1].points.count == drawnPointsInLast ? .upToDate : .appendPoints
        }
        return extendsWithNewStroke ? .appendStroke : .redraw
    }

    /// Brings the bitmap up to date with `strokes`. Returns true if
    /// anything was drawn (so the texture needs re-uploading).
    func update(strokes: [BrushStroke], guide: BrushGuide? = nil) -> Bool {
        let plan = plan(strokes: strokes, guide: guide)
        noteGuide(guide, for: strokes)
        switch plan {
        case .upToDate:
            return false
        case .appendPoints:
            let last = strokes[strokes.count - 1]
            draw(last, points: Array(last.points[drawnPointsInLast...]))
            drawnPointsInLast = last.points.count
            return true
        case .appendStroke:
            let last = strokes[strokes.count - 1]
            draw(last, points: last.points)
            drawnFingerprint = strokes.map(StrokeFingerprint.init)
            drawnPointsInLast = last.points.count
            return true
        case .redraw:
            // Start over.
            context.setBlendMode(.normal)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for stroke in strokes { draw(stroke, points: stroke.points) }
            drawnFingerprint = strokes.map(StrokeFingerprint.init)
            drawnPointsInLast = strokes.last?.points.count ?? 0
            return true
        }
    }

    private func noteGuide(_ guide: BrushGuide?, for strokes: [BrushStroke]) {
        self.guide = guide
        if strokes.contains(where: \.isAutoMasked) { drawnGuide = guide?.id }
    }

    /// The bitmap's bytes, row by row (`bytesPerRow` apart), for drawing
    /// somewhere else and handing over (`adopt`).
    func pixels() -> [UInt8] {
        guard let data else { return [] }
        return [UInt8](UnsafeRawBufferPointer(start: data, count: bytesPerRow * height))
    }

    /// Takes over a bitmap drawn elsewhere (`BrushRasterJob`) from
    /// `strokes` and `guide`, exactly as if `update` had redrawn it here:
    /// the same pixels, and later strokes draw on incrementally. False,
    /// changing nothing, if the bitmap is not this one's shape.
    func adopt(_ raster: BrushRaster, strokes: [BrushStroke], guide: BrushGuide?) -> Bool {
        guard raster.width == width, raster.height == height, raster.bytesPerRow == bytesPerRow,
              raster.bytes.count == bytesPerRow * height, let data else { return false }
        raster.bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        noteGuide(guide, for: strokes)
        drawnFingerprint = strokes.map(StrokeFingerprint.init)
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
        if stroke.isAutoMasked, let guide, guide.width == width, guide.height == height {
            drawAutoMasked(stroke, points: points, guide: guide)
            return
        }
        let radiusPx = CGFloat(stroke.radius) * CGFloat(min(width, height))
        guard radiusPx > 0.5 else { return }
        let inner = CGFloat(1 - min(max(stroke.feather, 0), 1))
        let flow = CGFloat(min(max(stroke.flow, 0), 1))
        let space = CGColorSpaceCreateDeviceGray()
        // Density caps the grey a paint dab reaches; `lighten` then never
        // takes the mask past it, however often the stroke passes.
        let level: CGFloat = stroke.erase ? 0 : CGFloat(min(max(stroke.density ?? 1, 0), 1))
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

/// A brush bitmap drawn away from the render (`BrushRasterJob`): the
/// pixels of a `BrushMaskRasterizer` of the same size.
struct BrushRaster: Sendable {
    let width: Int, height: Int, bytesPerRow: Int
    let bytes: [UInt8]
}

/// Redrawing one brush element's whole bitmap, which costs milliseconds
/// (every dab of every stroke), handed off by an interactive render
/// (`BrushMaskSet.sync(..., deferRedraws:)`) so it runs off the main
/// thread. Painting appends dabs and never needs one; undo, redo and a
/// feather or flow change that rewrites the strokes do.
public struct BrushRasterJob: Sendable {
    /// The `BrushMaskSet` that asked, and which of its requests this is.
    let setID: UUID
    let token: UInt64
    let elementID: UUID
    let strokes: [BrushStroke]
    let guide: BrushGuide?
    let sensorWidth: Int, sensorHeight: Int

    /// Draws the bitmap exactly as `BrushMaskRasterizer.update` redraws
    /// one. Safe on any thread: it touches nothing but its own bitmap.
    public func run() -> BrushRasterResult? {
        guard let raster = BrushMaskRasterizer(sensorWidth: sensorWidth, sensorHeight: sensorHeight) else { return nil }
        _ = raster.update(strokes: strokes, guide: guide)
        let pixels = BrushRaster(width: raster.width, height: raster.height, bytesPerRow: raster.bytesPerRow,
                                 bytes: raster.pixels())
        return BrushRasterResult(job: self, raster: pixels)
    }
}

/// A finished `BrushRasterJob`, for `ImageSession.applyBrushRaster`.
public struct BrushRasterResult: Sendable {
    let job: BrushRasterJob
    let raster: BrushRaster
}

/// Where a `BrushMaskSet` hands its redraws: runs the job somewhere and
/// passes the result back to the set on the thread that owns it.
typealias BrushRasterScheduler = @Sendable (BrushRasterJob) -> Void

/// Owns the mask texture array for one image and keeps its slices in
/// step with the brush and model-mask elements of the current locals: a
/// local's own shape and each shape component get a slice of their own.
/// The array starts with room for one slice per local and grows (rarely,
/// once components are used) up to one per possible element.
final class BrushMaskSet {
    private(set) var texture: MTLTexture
    private let device: MTLDevice
    private var rasterizers: [UUID: BrushSlot] = [:]
    private let sensorWidth: Int, sensorHeight: Int
    private let id = UUID()
    private var nextToken: UInt64 = 0
    /// Where the last deferring sync sent its redraws, for starting the
    /// next one when a result arrives (`apply`).
    private var scheduler: BrushRasterScheduler?

    /// One brush element's slice and bitmap, and any redraw running for it
    /// off the render.
    final class BrushSlot {
        let slice: Int
        let raster: BrushMaskRasterizer
        /// The strokes (and guide) the latest deferring sync wanted while
        /// the bitmap lags behind; nil while it is current.
        var wanted: (strokes: [BrushStroke], guide: BrushGuide?)?
        /// The one redraw whose result is still welcome; any other that
        /// arrives is stale and dropped.
        var inFlight: UInt64?
        /// The bitmap changed without reaching the texture (a redraw was
        /// adopted); the next sync that leaves it current uploads it.
        var needsUpload = false
        init(slice: Int, raster: BrushMaskRasterizer) { self.slice = slice; self.raster = raster }
    }

    /// Model masks already uploaded: element id -> (slice, the bitmap as
    /// made, the feather and edge it was refined with).
    private var uploadedAI: [UUID: (slice: Int, bitmap: MaskBitmap, feather: Float, edge: Float)] = [:]
    /// Edge refine (MaskRefine.swift) each slice was last uploaded with:
    /// the amount and the guide it was filtered against. Absent is off,
    /// which is every element until the slider is used.
    private var refinedWith: [UUID: MaskEdgeRefineKey] = [:]

    static let maximumSlices = LocalAdjustment.maximumCount * (1 + MaskComponent.maximumPerMask)

    init?(device: MTLDevice, sensorWidth: Int, sensorHeight: Int, slices: Int = LocalAdjustment.maximumCount) {
        self.device = device
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        guard let t = Self.makeTexture(device: device, sensorWidth: sensorWidth, sensorHeight: sensorHeight,
                                       slices: slices) else { return nil }
        texture = t
    }

    private static func makeTexture(device: MTLDevice, sensorWidth: Int, sensorHeight: Int, slices: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .r8Unorm
        d.width = max(1, sensorWidth / BrushMaskRasterizer.downscale)
        d.height = max(1, sensorHeight / BrushMaskRasterizer.downscale)
        d.arrayLength = slices
        d.storageMode = .shared
        d.usage = [.shaderRead]
        return device.makeTexture(descriptor: d)
    }

    private var usedSlices: Set<Int> {
        Set(rasterizers.values.map(\.slice)).union(uploadedAI.values.map(\.slice))
    }

    private func freeSlice() -> Int? {
        let used = usedSlices
        return (0..<texture.arrayLength).first { !used.contains($0) }
    }

    /// Updates slices for every brush and model element and returns
    /// element id -> slice. `aiMasks` supplies the pixels for model
    /// elements, by element id; one without pixels yet gets no slice
    /// (and masks nothing).
    ///
    /// With `deferRedraws` (interactive renders only), a brush element
    /// that already has a bitmap and would have to redraw all of it keeps
    /// its slice as it is for this render and the redraw goes to the
    /// scheduler; `apply` takes the result, and the next sync uploads it.
    /// Only the latest wanted strokes are ever uploaded: a result for
    /// strokes since replaced is never shown. Without it (export, High
    /// Quality Preview, every render outside the editor) every slice is
    /// brought up to date here, as always.
    func sync(locals: [LocalAdjustment], aiMasks: [UUID: MaskBitmap], guide: BrushGuide? = nil,
              deferRedraws scheduler: BrushRasterScheduler? = nil) -> [UUID: Int32] {
        if let scheduler { self.scheduler = scheduler }
        let elements = locals.flatMap(\.maskElements).filter { $0.shape.usesMaskSlice }
        // Room for every element: grow the array, starting the slices
        // over (the rasterizers redraw and the model masks upload again).
        let needed = elements.count
        if needed > texture.arrayLength {
            let slices = min(Self.maximumSlices, (needed + 7) / 8 * 8)
            if let bigger = Self.makeTexture(device: device, sensorWidth: sensorWidth,
                                             sensorHeight: sensorHeight, slices: slices) {
                texture = bigger
                rasterizers.removeAll()
                uploadedAI.removeAll()
                refinedWith.removeAll()
            }
        }

        var assignment: [UUID: Int32] = [:]
        // Drop entries for elements that no longer exist.
        let live = Set(elements.map(\.id))
        for id in rasterizers.keys where !live.contains(id) { rasterizers[id] = nil }
        for id in uploadedAI.keys where !live.contains(id) { uploadedAI[id] = nil }
        for id in refinedWith.keys where !live.contains(id) { refinedWith[id] = nil }

        for element in elements {
            switch element.shape {
            case .brush(let strokes):
                let entry: BrushSlot
                var isNew = false
                if let existing = rasterizers[element.id] {
                    entry = existing
                } else {
                    guard let slice = freeSlice(),
                          let raster = BrushMaskRasterizer(sensorWidth: sensorWidth, sensorHeight: sensorHeight)
                    else { continue }
                    entry = BrushSlot(slice: slice, raster: raster)
                    rasterizers[element.id] = entry
                    isNew = true
                }
                assignment[element.id] = Int32(entry.slice)
                // A slice with nothing in it yet is drawn now: showing it
                // empty for a moment would flash the adjustment off.
                if let scheduler, !isNew, entry.raster.plan(strokes: strokes, guide: guide) == .redraw {
                    deferRedraw(entry, elementID: element.id, strokes: strokes, guide: guide, scheduler: scheduler)
                    continue
                }
                entry.wanted = nil
                entry.inFlight = nil
                let drew = entry.raster.update(strokes: strokes, guide: guide) || entry.needsUpload
                let refineKey = MaskEdgeRefineKey(element.refine, guide: guide)
                if drew || refinedWith[element.id] != refineKey, let bytes = entry.raster.data {
                    if refineKey != nil, let guide, let refined = entry.raster.bitmap()?.edgeRefined(element.refine, guide: guide) {
                        upload(refined, slice: entry.slice)
                    } else {
                        texture.replace(region: MTLRegionMake2D(0, 0, entry.raster.width, entry.raster.height),
                                        mipmapLevel: 0, slice: entry.slice, withBytes: bytes,
                                        bytesPerRow: entry.raster.bytesPerRow, bytesPerImage: 0)
                    }
                    refinedWith[element.id] = refineKey
                    entry.needsUpload = false
                }

            case .ai, .prompted:
                guard let bitmap = aiMasks[element.id] else { continue }
                let refineKey = MaskEdgeRefineKey(element.refine, guide: guide)
                if let existing = uploadedAI[element.id], existing.bitmap == bitmap,
                   existing.feather == element.feather, existing.edge == element.edge,
                   refinedWith[element.id] == refineKey {
                    assignment[element.id] = Int32(existing.slice)
                    continue
                }
                let slice = uploadedAI[element.id]?.slice ?? freeSlice()
                guard let slice else { continue }
                // Refined at the slice's size, where the frame's aspect
                // is true, so Edge and Feather are round.
                var fitted = bitmap.resampled(width: texture.width, height: texture.height)
                    .refined(feather: element.feather, edge: element.edge)
                if refineKey != nil, let guide { fitted = fitted.edgeRefined(element.refine, guide: guide) }
                upload(fitted, slice: slice)
                uploadedAI[element.id] = (slice, bitmap, element.feather, element.edge)
                refinedWith[element.id] = refineKey
                assignment[element.id] = Int32(slice)

            default:
                continue
            }
        }
        return assignment
    }

    /// Notes that `entry` should show `strokes` and starts a redraw for
    /// them unless one for exactly these is already running; with one for
    /// older strokes running, the new one starts when it lands (`apply`).
    private func deferRedraw(_ entry: BrushSlot, elementID: UUID, strokes: [BrushStroke], guide: BrushGuide?,
                             scheduler: BrushRasterScheduler) {
        if let wanted = entry.wanted, wanted.strokes == strokes, wanted.guide?.id == guide?.id,
           entry.inFlight != nil { return }
        entry.wanted = (strokes, guide)
        if entry.inFlight == nil { startRedraw(entry, elementID: elementID, scheduler: scheduler) }
    }

    private func startRedraw(_ entry: BrushSlot, elementID: UUID, scheduler: BrushRasterScheduler) {
        guard let wanted = entry.wanted else { return }
        nextToken &+= 1
        entry.inFlight = nextToken
        scheduler(BrushRasterJob(setID: id, token: nextToken, elementID: elementID, strokes: wanted.strokes,
                                 guide: wanted.guide, sensorWidth: sensorWidth, sensorHeight: sensorHeight))
    }

    /// Takes a finished redraw. True when the caller should render again:
    /// the bitmap can now be brought to the wanted strokes without another
    /// redraw, so the next sync uploads it. A result that is no longer
    /// welcome (a newer render brought the slice up to date itself, the
    /// element is gone, the set was replaced) changes nothing.
    func apply(_ result: BrushRasterResult) -> Bool {
        let job = result.job
        guard job.setID == id, let entry = rasterizers[job.elementID], entry.inFlight == job.token else { return false }
        entry.inFlight = nil
        // Even a redraw for strokes since replaced is a full, consistent
        // bitmap to continue from; it is only uploaded once current.
        guard entry.raster.adopt(result.raster, strokes: job.strokes, guide: job.guide) else {
            entry.wanted = nil
            return false
        }
        entry.needsUpload = true
        guard let wanted = entry.wanted else { return true }
        if wanted.strokes == job.strokes, wanted.guide?.id == job.guide?.id {
            entry.wanted = nil
            return true
        }
        // The strokes moved on while it ran: catch up by appending if that
        // is enough, else redraw again for the latest.
        if entry.raster.plan(strokes: wanted.strokes, guide: wanted.guide) != .redraw { return true }
        if let scheduler { startRedraw(entry, elementID: job.elementID, scheduler: scheduler) }
        return false
    }

    /// Whether a redraw is running or wanted for any element, for tests.
    var hasPendingRedraws: Bool { rasterizers.values.contains { $0.wanted != nil || $0.inFlight != nil } }

    /// Writes a mask bitmap of the slices' size into `slice`.
    private func upload(_ bitmap: MaskBitmap, slice: Int) {
        guard bitmap.width == texture.width, bitmap.height == texture.height else { return }
        bitmap.data.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height),
                            mipmapLevel: 0, slice: slice, withBytes: bytes.baseAddress!,
                            bytesPerRow: bitmap.width, bytesPerImage: 0)
        }
    }
}
