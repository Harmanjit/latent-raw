import Foundation
import CoreGraphics
import simd
import RawCore

/// Moving an edit's geometry from the whole sensor readout onto the
/// camera's active area.
///
/// Crops, masks, heals and red-eye spots are stored in normalized sensor
/// coordinates: (0, 0) is the sensor plane's top-left, (1, 1) its
/// bottom-right. The plane used to be LibRaw's whole readout, masked
/// border and padding included; it is now only the active area
/// (`SensorActiveArea`). For most Nikons the two are the same and nothing
/// moves. For a camera with a border they are not: a Canon's readout has
/// 100-250 masked columns on the left, so a heal saved against the old
/// plane would now land that far to the side of its spot.
///
/// So an edit written before the change (no `frame`) is converted when
/// its image is opened, exported or thumbnailed: every point goes through
/// the readout pixel it named to the same pixel in active-area
/// coordinates, and every size keeps its size in pixels. The picture
/// under each edit is exactly what it was. Nothing is rewritten on disk
/// until the edit is next saved, and a converted stack is marked, so
/// converting twice changes nothing.
extension EditStack {
    /// The `frame` of a stack whose geometry measures the active area.
    public static let activeAreaFrame = "active-area"

    /// The groups whose modules hold normalized sensor geometry.
    /// Perspective (in the crop group) is a pair of angles, not a place.
    var geometryGroups: Set<EditGroup> {
        var groups: Set<EditGroup> = []
        if modules.locals != nil { groups.insert(.locals) }
        if modules.crop != nil { groups.insert(.crop) }
        if modules.heal != nil || modules.redeye != nil { groups.insert(.heal) }
        return groups
    }

    var hasGeometry: Bool { !geometryGroups.isEmpty }

    /// This stack with its geometry measured on `area`, the image's
    /// active area. Unchanged if it already is, or has no geometry.
    public func migratingGeometry(to area: SensorActiveArea) -> EditStack {
        guard frame != Self.activeAreaFrame, hasGeometry else { return self }
        var result = self
        result.frame = Self.activeAreaFrame
        guard area.isValid, !area.isWholeReadout else { return result }
        let map = ReadoutToActiveArea(area)

        if let c = modules.crop {
            result.modules.crop = map.crop(c)
        }
        result.modules.locals = modules.locals?.map { local in
            var local = local
            local.shape = map.shape(local.shape)
            return local
        }
        result.modules.heal = modules.heal?.map { patch in
            var patch = patch
            patch.target = map.point(patch.target)
            patch.source = map.point(patch.source)
            patch.radius *= map.shortSide
            patch.stroke = patch.stroke?.map(map.offset)
            return patch
        }
        result.modules.redeye = modules.redeye?.map { spot in
            var spot = spot
            spot.centre = map.point(spot.centre)
            spot.radius *= map.shortSide
            return spot
        }
        return result
    }
}

/// The conversion itself, for one image.
struct ReadoutToActiveArea {
    /// Readout size over active size, per axis: how much a normalized
    /// length grows when the same pixels are measured on the smaller grid.
    let scale: SIMD2<Float>
    /// The active area's corner, as a fraction of the active size.
    let origin: SIMD2<Float>
    /// The same growth for lengths given as a fraction of the short side
    /// (radii).
    let shortSide: Float
    let activeSize: CGSize

    init(_ area: SensorActiveArea) {
        let full = SIMD2<Float>(Float(area.fullWidth), Float(area.fullHeight))
        let active = SIMD2<Float>(Float(area.width), Float(area.height))
        scale = full / active
        origin = SIMD2(Float(area.left), Float(area.top)) / active
        shortSide = min(full.x, full.y) / min(active.x, active.y)
        activeSize = CGSize(width: area.width, height: area.height)
    }

    /// A position: readout pixel `p * full`, less the border, over the
    /// active size.
    func point(_ p: SIMD2<Float>) -> SIMD2<Float> { p * scale - origin }

    /// A displacement (heal stroke offsets, which are relative to the patch).
    func offset(_ d: SIMD2<Float>) -> SIMD2<Float> { d * scale }

    func shape(_ shape: MaskShape) -> MaskShape {
        switch shape {
        case .linear(let start, let end):
            return .linear(start: point(start), end: point(end))
        case .radial(let centre, let radii, let feather):
            return .radial(centre: point(centre), radii: radii * shortSide, feather: feather)
        case .brush(let strokes):
            return .brush(strokes: strokes.map { stroke in
                var stroke = stroke
                stroke.points = stroke.points.map(point)
                stroke.radius *= shortSide
                return stroke
            })
        case .prompted(let points, let modelVersion):
            return .prompted(points: points.map { p in
                let moved = point(SIMD2(p.x, p.y))
                return MaskPromptPoint(x: moved.x, y: moved.y, foreground: p.foreground)
            }, modelVersion: modelVersion)
        case .whole, .ai:
            return shape
        }
    }

    /// The crop keeps its centre pixel, its size in pixels and its angle
    /// (which is measured in pixels, so an unequal scale doesn't bend it).
    /// "No crop" stays no crop: the whole readout meant the whole picture.
    /// A crop that reached into the border now reaches past the plane,
    /// where there's nothing to show, so it's brought back inside: cut
    /// at the edge when it's square to the frame and free, shrunk about
    /// its centre (keeping angle and aspect) otherwise, as straightening does.
    func crop(_ c: EditStack.Crop) -> EditStack.Crop {
        var parameters = CropParameters(centre: [c.cx, c.cy], size: [c.w, c.h], angle: c.angle, aspect: c.aspect)
        guard !parameters.isIdentity else { return c }
        parameters.centre = point(parameters.centre)
        parameters.size *= scale
        if !parameters.fitsInside(sensorSize: activeSize) {
            if parameters.angle == 0 && parameters.aspect == nil {
                let lo = simd_clamp(parameters.centre - parameters.size / 2, SIMD2(0, 0), SIMD2(1, 1))
                let hi = simd_clamp(parameters.centre + parameters.size / 2, SIMD2(0, 0), SIMD2(1, 1))
                parameters.centre = (lo + hi) / 2
                parameters.size = hi - lo
            } else {
                parameters = parameters.constrained(sensorSize: activeSize)
            }
        }
        return EditStack.Crop(cx: parameters.centre.x, cy: parameters.centre.y,
                              w: parameters.size.x, h: parameters.size.y,
                              angle: parameters.angle, aspect: parameters.aspect)
    }
}
