import Foundation
import PixelEngine
import simd

// The projection maths turned into what the GPU kernels need: each frame's
// mapping in a form 32-bit floats handle precisely, and where on the output
// each frame can show up. Everything here is double precision and follows
// PanoramaMath (PanoramaAPI.swift) exactly; the kernels mirror it.

/// Output pixels and canvas pixels: output pixel (x, y) has its centre at
/// canvas pixel ((x + 0.5) / scale, (y + 0.5) / scale).
enum PanoramaBlendGeometry {
    typealias Mapping = MergePanoBlendKernels.FrameMapping

    /// Camera `position`'s mapping for the kernels, at level 0 of an output
    /// `scale` times the canvas, for the output pixels in `bounds` (nil: none).
    ///
    /// The output is cut into blocks of 512 x 512 pixels, and each block
    /// covering the bounds (plus one all round, for pixels of coarser grids
    /// that start just outside) gets its own anchor, the block's centre
    /// pixel. The kernels express every pixel's ray as a small change from
    /// its block anchor's ray, worked out here in double precision (see
    /// `mergePanoBlendMap`): for Cylindrical and Spherical canvases the
    /// world is turned by the anchor's longitude (which moves every
    /// longitude by the same amount, so the maths is unchanged) and tilted
    /// by its elevation, so the GPU only takes the sine of angles smaller
    /// than a block. Each block's columns are scaled so the anchor's ray has
    /// z = 1; the frame pixel only depends on the ray's direction.
    static func mapping(camera: PanoramaCamera, position: Int, canvas: PanoramaCanvas, scale: Double,
                        sampleScale: Double, bounds: PixelRegion?) -> Mapping {
        let shift = Mapping.blockShift, size = 1 << shift
        let s = canvas.pixelsPerRadian
        let toCamera = camera.rotationMatrix.transpose
        var first = SIMD2<Int>(0, 0), across = 0, down = 0
        var blocks: [Mapping.Block] = []
        if let bounds, bounds.width > 0, bounds.height > 0 {
            first = SIMD2(max(0, (bounds.x >> shift) - 1), max(0, (bounds.y >> shift) - 1))
            across = ((bounds.x + bounds.width - 1) >> shift) + 2 - first.x
            down = ((bounds.y + bounds.height - 1) >> shift) + 2 - first.y
            for row in 0..<down {
                for column in 0..<across {
                    let anchor = SIMD2((first.x + column) * size + size / 2, (first.y + row) * size + size / 2)
                    blocks.append(block(anchor: anchor, toCamera: toCamera, canvas: canvas, scale: scale))
                }
            }
        }
        let projection: MergePanoBlendKernels.Projection
        switch canvas.projection {
        case .perspective, .automatic: projection = .perspective
        case .cylindrical: projection = .cylindrical
        case .spherical: projection = .spherical
        }
        return Mapping(firstBlock: first, blocksAcross: across, blocksDown: down, blocks: blocks,
                       unitsPerPixel: SIMD2(repeating: 1 / (scale * s)), focalLength: camera.focalLengthPixels,
                       principalPoint: camera.principalPoint, sampleScale: sampleScale, gain: camera.exposureGain,
                       projection: projection, position: position)
    }

    /// One block's anchor ray and the matrix around it.
    private static func block(anchor: SIMD2<Int>, toCamera: simd_double3x3, canvas: PanoramaCanvas,
                              scale: Double) -> Mapping.Block {
        let s = canvas.pixelsPerRadian
        // The anchor pixel centre's projected point, over pixels per radian.
        let projected = ((SIMD2<Double>(Double(anchor.x), Double(anchor.y)) + 0.5) / scale + canvas.origin) / s
        var matrix: simd_double3x3
        var ray: SIMD3<Double>
        var tilt = SIMD2<Double>(1, 0)
        switch canvas.projection {
        case .perspective, .automatic:
            matrix = toCamera
            ray = toCamera * SIMD3(projected.x, projected.y, 1)
        case .cylindrical, .spherical:
            let longitude = projected.x
            let turn = simd_double3x3(rows: [SIMD3(cos(longitude), 0, sin(longitude)), SIMD3(0, 1, 0),
                                             SIMD3(-sin(longitude), 0, cos(longitude))])
            // Cylindrical: the anchor's direction is (0, height, 1), tilted
            // by atan(height), sec(tilt) long; Spherical: its latitude is the
            // tilt, and it is unit length.
            let angle = canvas.projection == .cylindrical ? atan(projected.y) : projected.y
            let lift = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(angle), sin(angle)),
                                             SIMD3(0, -sin(angle), cos(angle))])
            matrix = toCamera * turn * lift
            ray = matrix.columns.2 * (canvas.projection == .cylindrical ? 1 / cos(angle) : 1)
            tilt = SIMD2(cos(angle), sin(angle))
        }
        // The anchor behind (or beside) the camera: nothing in the block can
        // land on the photo, whose field of view is far below 180 degrees.
        guard ray.z > 1e-6 * simd_length(ray) else {
            return Mapping.Block(matrix: matrix, anchorRay: ray, tilt: tilt, anchor: anchor, isValid: false)
        }
        matrix = matrix * (1 / ray.z)
        ray /= ray.z
        return Mapping.Block(matrix: matrix, anchorRay: ray, tilt: tilt, anchor: anchor, isValid: true)
    }

    /// The output pixels (level 0) a frame can put any coverage on, or nil
    /// if none: the frame's rectangle, widened by `reach` prepared pixels
    /// (how far a sample's taps reach past its edge), projected onto the
    /// output, plus a few pixels, clipped to the output.
    ///
    /// The rectangle's outline and a grid inside it are projected: for a
    /// frame that doesn't contain a pole of the projection, the outline
    /// bounds the inside, and the grid catches the cases where it doesn't.
    /// A point the projection can't show (behind a Perspective canvas, or
    /// straight up on a Cylindrical one) makes the whole output the answer.
    static func outputBounds(camera: PanoramaCamera, frame: PanoramaPreparedFrame, canvas: PanoramaCanvas,
                             scale: Double, outputWidth: Int, outputHeight: Int, reach: Double) -> PixelRegion? {
        let whole = PixelRegion(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let widen = reach / frame.sampleScale
        let maxU = max(Double(camera.width), Double(frame.width) / frame.sampleScale) + widen
        let maxV = max(Double(camera.height), Double(frame.height) / frame.sampleScale) + widen
        let minU = -widen, minV = -widen
        var lower = SIMD2<Double>(repeating: .infinity), upper = SIMD2<Double>(repeating: -.infinity)
        let steps = 48
        for j in 0...steps {
            for i in 0...steps {
                let onEdge = i == 0 || j == 0 || i == steps || j == steps
                // The outline densely, the inside every 4th point.
                guard onEdge || (i % 4 == 0 && j % 4 == 0) else { continue }
                let u = minU + (maxU - minU) * Double(i) / Double(steps)
                let v = minV + (maxV - minV) * Double(j) / Double(steps)
                let direction = PanoramaMath.direction(framePixel: SIMD2(u, v), camera: camera)
                guard let onCanvas = PanoramaMath.canvasPixel(direction: direction, canvas: canvas),
                      onCanvas.x.isFinite, onCanvas.y.isFinite else { return whole }
                let output = onCanvas * scale - 0.5
                lower = simd_min(lower, output)
                upper = simd_max(upper, output)
            }
        }
        let margin = 4.0
        let x0 = max(0, Int(floor(lower.x - margin))), y0 = max(0, Int(floor(lower.y - margin)))
        let x1 = min(outputWidth, Int(ceil(upper.x + margin)) + 1), y1 = min(outputHeight, Int(ceil(upper.y + margin)) + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The most prepared pixels one output pixel spans anywhere on the
    /// frame (its footprint), measured at points around the rectangle and
    /// at its centre.
    static func largestFootprint(camera: PanoramaCamera, frame: PanoramaPreparedFrame, canvas: PanoramaCanvas,
                                 scale: Double) -> Double {
        var largest = 0.0
        let w = Double(camera.width), h = Double(camera.height)
        for (u, v) in [(0.5, 0.5), (0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0), (0.5, 1), (0, 0.5), (1, 0.5)] {
            let p = SIMD2(u * w, v * h)
            guard let a = PanoramaMath.canvasPixel(direction: PanoramaMath.direction(framePixel: p, camera: camera),
                                                   canvas: canvas),
                  let bx = PanoramaMath.canvasPixel(direction: PanoramaMath.direction(framePixel: p + SIMD2(1, 0),
                                                                                       camera: camera), canvas: canvas),
                  let by = PanoramaMath.canvasPixel(direction: PanoramaMath.direction(framePixel: p + SIMD2(0, 1),
                                                                                       camera: camera), canvas: canvas)
            else { continue }
            // Output pixels per full-resolution pixel, the smaller way.
            let outputPerPixel = min(simd_distance(a, bx), simd_distance(a, by)) * scale
            guard outputPerPixel > 1e-9 else { continue }
            largest = max(largest, frame.sampleScale / outputPerPixel)
        }
        return largest > 0 ? largest : 1 / scale
    }

    /// How far (prepared pixels) a warp's taps reach past the frame's edge
    /// on a grid whose pixels span `footprint` prepared pixels: two taps of
    /// the coarser of the two mip levels it samples, and a pixel more.
    static func reach(footprint: Double) -> Double {
        let level = footprint > 1 ? Int(ceil(log2(footprint))) : 0
        return 2 * Double(1 << min(level + 1, 30)) + 2
    }
}
