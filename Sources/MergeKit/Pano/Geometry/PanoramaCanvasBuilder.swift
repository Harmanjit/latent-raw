import CoreGraphics
import Foundation
import simd

// The panorama's surface: which projection, how big, where each photo's
// covered area lies on it, and the largest rectangle inside that area.

enum PanoramaCanvasBuilder {
    /// Perspective keeps straight lines straight but stretches everything
    /// towards its edges; beyond about 70° across that stretching shows.
    static let perspectiveLimitDegrees = 70.0
    /// Cylindrical stretches heights by 1 / cos² of the latitude: beyond 65°
    /// (5.6 times) a very tall panorama is better spherical.
    static let cylindricalLatitudeLimitDegrees = 65.0
    /// Points sampled along each edge of a photo to find its outline.
    static let outlineSamples = 48

    /// How far the photos reach: longitude and latitude ranges (radians)
    /// of their outlines, around the panorama's centre (+z).
    struct Extent {
        var minLongitude = Double.infinity, maxLongitude = -Double.infinity
        var minLatitude = Double.infinity, maxLatitude = -Double.infinity
        var widthDegrees: Double { (maxLongitude - minLongitude) * 180 / .pi }
        var heightDegrees: Double { (maxLatitude - minLatitude) * 180 / .pi }
    }

    /// Points around the edge of `camera`'s photo, full resolution.
    static func outline(_ camera: PanoramaCamera) -> [SIMD2<Double>] {
        let w = Double(camera.width), h = Double(camera.height), n = outlineSamples
        var points: [SIMD2<Double>] = []
        for k in 0..<n {
            let t = Double(k) / Double(n)
            points += [SIMD2(t * w, 0), SIMD2(w, t * h), SIMD2(w - t * w, h), SIMD2(0, h - t * h)]
        }
        return points
    }

    static func extent(_ cameras: [PanoramaCamera]) -> Extent {
        var e = Extent()
        for camera in cameras {
            let centre = PanoramaMath.direction(framePixel: camera.principalPoint, camera: camera)
            let centreLongitude = atan2(centre.x, centre.z)
            for p in outline(camera) + [camera.principalPoint] {
                let d = PanoramaMath.direction(framePixel: p, camera: camera)
                // Unwrapped next to the photo's own centre, so a photo
                // straddling the back of the sphere doesn't span 360°.
                var longitude = atan2(d.x, d.z)
                while longitude - centreLongitude > .pi { longitude -= 2 * .pi }
                while longitude - centreLongitude < -.pi { longitude += 2 * .pi }
                let latitude = atan2(-d.y, (d.x * d.x + d.z * d.z).squareRoot())
                e.minLongitude = min(e.minLongitude, longitude); e.maxLongitude = max(e.maxLongitude, longitude)
                e.minLatitude = min(e.minLatitude, latitude); e.maxLatitude = max(e.maxLatitude, latitude)
            }
        }
        return e
    }

    /// The projection `.automatic` resolves to: Perspective up to 70° across
    /// both ways, Spherical when the photos reach beyond 65° above or below
    /// the horizon, Cylindrical otherwise.
    static func automaticProjection(_ extent: Extent) -> PanoramaProjection {
        let limit = cylindricalLatitudeLimitDegrees * .pi / 180
        if max(extent.maxLatitude, -extent.minLatitude) > limit { return .spherical }
        if max(extent.widthDegrees, extent.heightDegrees) <= perspectiveLimitDegrees { return .perspective }
        return .cylindrical
    }

    /// The canvas at scale 1 (`pixelsPerRadian` = the focal length, so the
    /// panorama's centre keeps the photos' own resolution), cut to the
    /// bounding box of every photo's outline.
    static func canvas(_ cameras: [PanoramaCamera], projection: PanoramaProjection, focal: Double) -> PanoramaCanvas {
        let provisional = PanoramaCanvas(projection: projection, pixelsPerRadian: focal, origin: .zero, width: 1, height: 1)
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        let halfTurn = Double.pi * focal
        for camera in cameras {
            let centre = PanoramaMath.direction(framePixel: camera.principalPoint, camera: camera)
            let centreX = PanoramaMath.canvasPixel(direction: centre, canvas: provisional)?.x ?? 0
            for p in outline(camera) {
                let d = PanoramaMath.direction(framePixel: p, camera: camera)
                guard var q = PanoramaMath.canvasPixel(direction: d, canvas: provisional) else { continue }
                if projection != .perspective {
                    // Keep a photo that straddles the back of the panorama
                    // in one piece, then clip to one turn.
                    while q.x - centreX > halfTurn { q.x -= 2 * halfTurn }
                    while q.x - centreX < -halfTurn { q.x += 2 * halfTurn }
                    q.x = min(max(q.x, -halfTurn), halfTurn)
                }
                lo = simd_min(lo, q)
                hi = simd_max(hi, q)
            }
        }
        guard lo.x.isFinite, hi.x.isFinite else {
            return PanoramaCanvas(projection: projection, pixelsPerRadian: focal, origin: .zero, width: 1, height: 1)
        }
        let origin = SIMD2(lo.x.rounded(.down), lo.y.rounded(.down))
        return PanoramaCanvas(projection: projection, pixelsPerRadian: focal, origin: origin,
                              width: max(1, Int((hi.x - origin.x).rounded(.up))),
                              height: max(1, Int((hi.y - origin.y).rounded(.up))))
    }

    // MARK: - Coverage and Auto Crop

    /// Where the photos cover the canvas, on a coarse grid: `columns x rows`
    /// cells, each `cellSize` canvas pixels square (the last row and column
    /// may be cut short by the canvas edge).
    struct Coverage {
        let columns: Int
        let rows: Int
        let cellSize: Double
        /// True for a cell whose four corners are all inside some photo.
        let covered: [Bool]
    }

    /// The coverage grid, with cells no bigger than the canvas's long side
    /// over `longSideCells`.
    ///
    /// A grid corner is covered when its direction lands inside a photo,
    /// on a texel of its thumbnail with coverage (so a lens-corrected
    /// photo's empty corners don't count). A cell counts only when all four
    /// of its corners do, so a rectangle of covered cells is covered
    /// throughout, give or take the bulge of a photo's curved edge between
    /// two corners (a fraction of a cell).
    static func coverage(canvas: PanoramaCanvas, cameras: [PanoramaCamera], thumbnails: [Int: PanoramaThumbnail],
                         longSideCells: Int = 1024) -> Coverage {
        let cell = max(1, Double(max(canvas.width, canvas.height)) / Double(longSideCells))
        let columns = max(1, Int((Double(canvas.width) / cell).rounded(.up)))
        let rows = max(1, Int((Double(canvas.height) / cell).rounded(.up)))
        // Each camera's axis and how far from it (as a cosine) its photo reaches.
        let reach = cameras.map { camera -> (axis: SIMD3<Double>, cosine: Double) in
            let axis = camera.rotationMatrix * SIMD3(0, 0, 1)
            let halfDiagonal = (Double(camera.width * camera.width + camera.height * camera.height)).squareRoot() / 2
            return (axis, cos(min(atan(halfDiagonal / camera.focalLengthPixels) + 0.01, .pi / 2)))
        }
        var corners = [Bool](repeating: false, count: (columns + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...columns {
                let p = SIMD2(min(Double(i) * cell, Double(canvas.width)), min(Double(j) * cell, Double(canvas.height)))
                guard let d = PanoramaMath.direction(canvasPixel: p, canvas: canvas) else { continue }
                for (k, camera) in cameras.enumerated() where simd_dot(d, reach[k].axis) >= reach[k].cosine {
                    guard let q = PanoramaMath.framePixel(direction: d, camera: camera),
                          q.x >= 0, q.y >= 0, q.x <= Double(camera.width), q.y <= Double(camera.height) else { continue }
                    if let t = thumbnails[camera.frameIndex] {
                        let x = min(Int(q.x / Double(t.span)), t.width - 1), y = min(Int(q.y / Double(t.span)), t.height - 1)
                        guard t.rgba[4 * (y * t.width + x) + 3] >= 0.5 else { continue }
                    }
                    corners[j * (columns + 1) + i] = true
                    break
                }
            }
        }
        var covered = [Bool](repeating: false, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let a = j * (columns + 1) + i, b = a + columns + 1
                covered[j * columns + i] = corners[a] && corners[a + 1] && corners[b] && corners[b + 1]
            }
        }
        return Coverage(columns: columns, rows: rows, cellSize: cell, covered: covered)
    }

    /// The largest axis-aligned rectangle of covered cells, in canvas pixels
    /// at scale 1; `.zero` when nothing is covered.
    ///
    /// **How.** Row by row, each column's run of covered cells ending at
    /// that row is a histogram bar; the largest rectangle under a histogram
    /// is found with a stack in one pass (every bar is pushed and popped
    /// once), so the whole grid takes rows x columns steps.
    static func largestRectangle(_ coverage: Coverage, canvas: PanoramaCanvas) -> CGRect {
        let columns = coverage.columns, rows = coverage.rows
        var heights = [Int](repeating: 0, count: columns)
        var best = (area: 0, x: 0, y: 0, width: 0, height: 0)
        for j in 0..<rows {
            for i in 0..<columns { heights[i] = coverage.covered[j * columns + i] ? heights[i] + 1 : 0 }
            var stack: [Int] = []
            for i in 0...columns {
                let h = i < columns ? heights[i] : 0
                while let top = stack.last, heights[top] >= h {
                    stack.removeLast()
                    let height = heights[top]
                    let left = stack.last.map { $0 + 1 } ?? 0
                    let width = i - left
                    if height * width > best.area {
                        best = (height * width, left, j - height + 1, width, height)
                    }
                }
                if i < columns { stack.append(i) }
            }
        }
        guard best.area > 0 else { return .zero }
        let c = coverage.cellSize
        let x0 = Double(best.x) * c, y0 = Double(best.y) * c
        let x1 = min(Double(best.x + best.width) * c, Double(canvas.width))
        let y1 = min(Double(best.y + best.height) * c, Double(canvas.height))
        // Whole pixels, inside the covered cells.
        let left = x0.rounded(.up), top = y0.rounded(.up)
        return CGRect(x: left, y: top, width: max(0, x1.rounded(.down) - left), height: max(0, y1.rounded(.down) - top))
    }
}
