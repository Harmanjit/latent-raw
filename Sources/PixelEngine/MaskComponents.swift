import Foundation
import simd

/// How a component joins the mask built so far.
///
/// - Add: the union. A pixel is in the mask if it is in either; with soft
///   edges the larger of the two values wins, so overlapping feathers
///   never add up past full strength.
/// - Subtract: takes the component out, in proportion to its value.
/// - Intersect: keeps only what is in both (the product).
public enum MaskCombineMode: String, Codable, Sendable, CaseIterable {
    case add, subtract, intersect

    public var displayName: String {
        switch self {
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        }
    }

    /// The combination on one pixel: `mask` so far, `component` this one.
    public func combine(_ mask: Float, _ component: Float) -> Float {
        switch self {
        case .add: return max(mask, component)
        case .subtract: return mask * (1 - component)
        case .intersect: return mask * component
        }
    }
}

/// What a component is made of: a shape like a mask's own, or a range of
/// tones or colours measured on the image itself.
public enum MaskComponentSource: Equatable, Sendable, Codable {
    case shape(MaskShape)
    case luminance(LuminanceRange)
    case colour(ColourRange)
}

/// One part of a local adjustment's mask after its first shape
/// (`LocalAdjustment.shape`), combined with what comes before it.
public struct MaskComponent: Equatable, Sendable, Codable, Identifiable {
    /// Also the key for this component's pixels when it is a brush or a
    /// model mask, as a local's own id is for its shape.
    public var id: UUID
    public var mode: MaskCombineMode
    public var source: MaskComponentSource
    public var invert: Bool
    /// Feather (0…1) and Edge (−1…1) of a model mask, as on the local.
    public var feather: Float
    public var edge: Float

    public init(id: UUID = UUID(), mode: MaskCombineMode, source: MaskComponentSource,
                invert: Bool = false, feather: Float = 0, edge: Float = 0) {
        self.id = id; self.mode = mode; self.source = source; self.invert = invert
        self.feather = feather; self.edge = edge
    }

    /// Components a mask may have after its first shape. The GPU packs
    /// every component of every mask into one small buffer.
    public static let maximumPerMask = 6

    /// The shape, when the component is one.
    public var shape: MaskShape? {
        if case .shape(let s) = source { return s }
        return nil
    }

    /// A short name for the component list: "Brush", "Colour Range".
    public var displayName: String {
        switch source {
        case .shape(let shape): return shape.componentName
        case .luminance: return "Luminance Range"
        case .colour: return "Colour Range"
        }
    }
}

extension MaskShape {
    /// The kind of shape, for the component list.
    public var componentName: String {
        switch self {
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .brush: return "Brush"
        case .whole: return "Whole Image"
        case .ai(let kind, _): return kind == "subject" ? "Subject" : kind.capitalized
        case .prompted(let points, _):
            return points.contains(where: { $0.corner != nil }) ? "Object" : "Click to Select"
        }
    }

    /// Whether the shape has nothing in it yet: a brush with no strokes,
    /// a selection with no clicks, a gradient or radial never dragged out.
    /// Model masks of a kind (subject, sky) are never empty here: whether
    /// the model found anything is only known from its pixels.
    public var isEmpty: Bool {
        switch self {
        case .brush(let strokes): return strokes.allSatisfy { $0.erase || $0.points.isEmpty }
        case .prompted(let points, _): return points.isEmpty
        case .linear(let s, let e): return simd_distance(s, e) < 1e-4
        case .radial(_, let r, _): return max(r.x, r.y) < 0.002
        case .whole, .ai: return false
        }
    }
}

/// One colour picked with the Colour Range eyedropper: its hue (degrees)
/// and saturation (0…1) as the mask sees the pixel, before any local
/// adjustment changes it.
public struct ColourSample: Equatable, Sendable, Codable {
    public var hue: Float
    public var saturation: Float
    public init(hue: Float, saturation: Float) { self.hue = hue; self.saturation = saturation }

    /// The sample as a point on the colour wheel (saturation is the
    /// radius), where distance between colours is measured.
    var wheel: SIMD2<Float> {
        let a = hue * .pi / 180
        return SIMD2(saturation * cos(a), saturation * sin(a))
    }
}

/// Selects pixels close in colour to any of up to five samples.
///
/// Closeness is distance on the colour wheel (hue as the angle,
/// saturation as the radius), so a pale and a vivid red count as related
/// but further apart than two vivid reds; greys gather at the centre and
/// can be picked too. `refine` (0…1) widens the tolerance.
public struct ColourRange: Equatable, Sendable, Codable {
    public var samples: [ColourSample]
    public var refine: Float

    public init(samples: [ColourSample] = [], refine: Float = 0.5) {
        self.samples = samples; self.refine = refine
    }

    public static let maximumSamples = 5

    /// The wheel distance at which selection reaches zero.
    var radius: Float { 0.04 + min(max(refine, 0), 1) * 0.36 }

    /// The selection for a pixel of the given hue (degrees) and
    /// saturation, 0…1. The GPU does the same sum (ColorPipeline.metal,
    /// `colourRangeWeight`).
    public func weight(hue: Float, saturation: Float) -> Float {
        guard !samples.isEmpty else { return 0 }
        let p = ColourSample(hue: hue, saturation: saturation).wheel
        let d = samples.map { simd_distance($0.wheel, p) }.min() ?? .infinity
        let r = radius
        return 1 - Self.smoothstep(r * 0.5, r, d)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// The sample the mask takes from a working-space (linear Rec.2020)
    /// pixel, as the colour kernel sees it before the local adjustments:
    /// through the tone ranges and the SDR tone curve, then a gamma of
    /// 2.2, then hue and saturation (ColorPipeline.metal, stage 11).
    public static func sample(working rgb: SIMD3<Float>, contrast: Float, greyPoint: Float,
                              toneRanges: ToneRanges = .neutral) -> ColourSample {
        var w = simd_max(rgb, SIMD3(repeating: 0))
        if !toneRanges.isNeutral {
            let y = simd_dot(w, SIMD3(0.2627, 0.6780, 0.0593))
            let c = max(contrast, 1e-3)
            let t = min(max(c * log2(max(y, 1e-10) / max(greyPoint, 1e-6)), ToneRanges.lutRange.lowerBound),
                        ToneRanges.lutRange.upperBound)
            w *= exp2((toneRanges.remap(t) - t) / c)
        }
        // toneMapSigmoid with a headroom of 1.
        let c = contrast
        let xc = SIMD3(pow(w.x, c), pow(w.y, c), pow(w.z, c))
        let kc = pow(max(greyPoint, 1e-6), c)
        let display = xc / (xc + SIMD3(repeating: kc))
        let p = SIMD3(pow(max(display.x, 0), 1 / 2.2), pow(max(display.y, 0), 1 / 2.2), pow(max(display.z, 0), 1 / 2.2))
        let hsv = hueSaturation(p)
        return ColourSample(hue: hsv.hue, saturation: hsv.saturation)
    }

    /// Hue in degrees and saturation, as `rgbToHSV` in the shader.
    static func hueSaturation(_ c: SIMD3<Float>) -> (hue: Float, saturation: Float) {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        var h: Float = 0
        if d > 1e-6 {
            if mx == c.x { h = fmodf((c.y - c.z) / d, 6) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx > 1e-6 ? d / mx : 0)
    }
}

/// A shape inside a local adjustment that may own pixels (a brush, a
/// model mask): the local's own shape under the local's id, or a shape
/// component under the component's.
public struct MaskElement: Equatable, Sendable {
    public let id: UUID
    public let shape: MaskShape
    /// Feather and Edge, which matter only for a model mask.
    public let feather: Float
    public let edge: Float

    public init(id: UUID, shape: MaskShape, feather: Float = 0, edge: Float = 0) {
        self.id = id; self.shape = shape; self.feather = feather; self.edge = edge
    }
}

extension LocalAdjustment {
    /// The local's own shape, then each shape component, in order.
    public var maskElements: [MaskElement] {
        var out = [MaskElement(id: id, shape: shape, feather: modelFeather, edge: modelEdge)]
        for c in components {
            if let s = c.shape { out.append(MaskElement(id: c.id, shape: s, feather: c.feather, edge: c.edge)) }
        }
        return out
    }

    /// The elements whose pixels come from a model.
    public var modelElements: [MaskElement] { maskElements.filter { $0.shape.isModelGenerated } }

    /// Whether any element keeps its pixels in a mask texture slice.
    var usesMaskSlices: Bool { maskElements.contains { $0.shape.usesMaskSlice } }

    /// The shape of the element `elementID` (the local's id for its own).
    public func shape(ofElement elementID: UUID) -> MaskShape? {
        if elementID == id { return shape }
        return components.first { $0.id == elementID }?.shape
    }

    /// Replaces the shape of an element; false when there is none.
    @discardableResult
    public mutating func setShape(_ newShape: MaskShape, ofElement elementID: UUID) -> Bool {
        if elementID == id { shape = newShape; return true }
        guard let i = components.firstIndex(where: { $0.id == elementID }), components[i].shape != nil else { return false }
        components[i].source = .shape(newShape)
        return true
    }

    /// True when no part of the mask has anything in it: Delete Empty
    /// Masks removes such masks. Ranges never make a mask empty on their
    /// own; they only narrow a shape.
    public var isEmptyMask: Bool {
        shape.isEmpty && components.allSatisfy { c in
            switch c.source {
            case .shape(let s): return s.isEmpty || c.mode != .add
            case .colour(let r): return r.samples.isEmpty || c.mode != .add
            case .luminance: return c.mode != .add
            }
        }
    }

    /// A copy with fresh ids for the local and every component, so its
    /// pixels and history never mix with the original's.
    public func duplicated(name newName: String? = nil) -> LocalAdjustment {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) copy"
        copy.components = components.map { c in
            var c = c
            c.id = UUID()
            return c
        }
        return copy
    }

    /// The same copy, inverted: Duplicate and Invert. A single-shape mask
    /// flips its own `invert` (exactly the old meaning); one with
    /// components flips the whole combination.
    public func duplicatedAndInverted() -> LocalAdjustment {
        var copy = duplicated(name: "\(name) inverted")
        if components.isEmpty { copy.invert.toggle() } else { copy.invertMask.toggle() }
        return copy
    }
}

extension EditParameters {
    /// Every model-generated element of every local.
    public var modelMaskElements: [MaskElement] { locals.flatMap(\.modelElements) }

    /// The element `id` names, in whichever local holds it.
    public func maskElement(id elementID: UUID) -> MaskElement? {
        for local in locals {
            if let e = local.maskElements.first(where: { $0.id == elementID }) { return e }
        }
        return nil
    }

    /// Masks that have nothing in them (`LocalAdjustment.isEmptyMask`).
    public var emptyLocalIndices: [Int] {
        locals.indices.filter { locals[$0].isEmptyMask }
    }
}
