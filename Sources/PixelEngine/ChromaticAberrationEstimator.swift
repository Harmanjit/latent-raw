import Foundation
import simd

/// Remove Chromatic Aberration without a lens profile: measures how much
/// larger (or smaller) the red and blue images are than the green one, on
/// the photo itself.
///
/// Lateral chromatic aberration makes a lens magnify each colour slightly
/// differently, so red and blue edges sit a little further out (or in)
/// than green ones, by an amount that grows with the distance from the
/// centre. The estimate reads small full-resolution patches of the
/// demosaiced, uncorrected image spread over the frame. In each it finds
/// the shift along the line to the centre that best lines up the red (and
/// blue) edges with the green ones, then fits a single scale through all
/// those shifts: shift = k × radius. The result, one number per colour,
/// goes in the edit and the lens pass resamples red and blue by 1 + k,
/// exactly as it applies a profile's TCA.
///
/// Patches with no edges (sky, out-of-focus areas) say nothing and are
/// dropped; so are patches whose shift disagrees badly with the rest
/// (a red object next to a green one is not aberration).
public enum ChromaticAberrationEstimator {
    /// Patch size in sensor pixels, and where the patches go, as fractions
    /// of the frame: a 5 × 5 grid without its centre, where there is
    /// little to measure.
    static let tileSize = 192
    static let gridFractions: [Double] = [0.08, 0.29, 0.5, 0.71, 0.92]

    /// Shifts tried, in pixels, either side of zero.
    static let searchRange: Float = 3
    static let searchStep: Float = 0.25

    /// One patch's finding for one colour.
    public struct Sample: Equatable, Sendable {
        /// Distance of the patch centre from the frame centre, sensor px.
        public var radius: Float
        /// How far out the colour sits from green, sensor px.
        public var shift: Float
        /// Edge strength times how well the shifted edges line up.
        public var weight: Float
    }

    /// A full-resolution patch of the demosaiced, uncorrected image.
    public struct Tile: Sendable {
        public var pixels: [SIMD3<Float>]
        public var width: Int, height: Int
        /// The patch centre's offset from the frame centre, sensor px.
        public var offset: SIMD2<Float>

        public init(pixels: [SIMD3<Float>], width: Int, height: Int, offset: SIMD2<Float>) {
            self.pixels = pixels; self.width = width; self.height = height; self.offset = offset
        }
    }

    /// Renders the patches the estimate reads: quick GPU work, on the
    /// caller's thread (the session isn't shared across threads).
    public static func captureTiles(session: ImageSession, pipeline: RenderPipeline,
                                    parameters: EditParameters) throws -> [Tile] {
        let summary = session.file.summary
        let width = summary.rawWidth, height = summary.rawHeight
        guard width >= tileSize * 2, height >= tileSize * 2 else { return [] }
        let centre = SIMD2<Float>(Float(width), Float(height)) / 2
        // The demosaic choice matters at full resolution; the white balance
        // doesn't (the measure works on log gradients), so as shot.
        var p = EditParameters()
        p.demosaic = parameters.demosaic
        p.whiteBalance = .asShot
        var tiles: [Tile] = []
        for fy in gridFractions {
            for fx in gridFractions where !(fx == 0.5 && fy == 0.5) {
                let x = Int(Double(width) * fx) - tileSize / 2
                let y = Int(Double(height) * fy) - tileSize / 2
                let scale = RenderScale.region(x: x, y: y, width: tileSize, height: tileSize)
                // Where the render puts the patch: clamped and snapped to even.
                guard case .fullResolution(let origin, let size) = RenderPipeline.plan(
                    rawWidth: width, rawHeight: height, scale: scale) else { continue }
                let texture = try session.withTexturePool(.analysis) {
                    try pipeline.renderCameraRGB(session, scale: scale, parameters: p)
                }
                let raw = try TextureReadback.float16Pixels(of: texture, gpu: pipeline.gpu)
                let w = texture.width, h = texture.height
                var pixels = [SIMD3<Float>](repeating: .zero, count: w * h)
                for i in 0..<(w * h) {
                    pixels[i] = SIMD3(Float(raw[i * 4]), Float(raw[i * 4 + 1]), Float(raw[i * 4 + 2]))
                }
                let tileCentre = SIMD2<Float>(Float(origin.x) + Float(size.width) / 2,
                                              Float(origin.y) + Float(size.height) / 2)
                tiles.append(Tile(pixels: pixels, width: w, height: h, offset: tileCentre - centre))
            }
        }
        return tiles
    }

    /// The fit from the patches. Nil when too few of them have edges to
    /// measure: a correction from two patches would be a guess. Pure CPU
    /// work, safe on any thread.
    public static func estimate(tiles: [Tile]) -> AutoChromaticAberration? {
        var red: [Sample] = [], blue: [Sample] = []
        for tile in tiles {
            let radius = simd_length(tile.offset)
            guard radius > 1 else { continue }
            let direction = tile.offset / radius
            if let s = radialShift(pixels: tile.pixels, width: tile.width, height: tile.height,
                                   channel: 0, direction: direction) {
                red.append(Sample(radius: radius, shift: s.shift, weight: s.weight))
            }
            if let s = radialShift(pixels: tile.pixels, width: tile.width, height: tile.height,
                                   channel: 2, direction: direction) {
                blue.append(Sample(radius: radius, shift: s.shift, weight: s.weight))
            }
        }
        guard let kr = fitScale(red), let kb = fitScale(blue) else { return nil }
        return AutoChromaticAberration(red: kr, blue: kb).sanitized
    }

    /// The shift of `channel` (0 red, 2 blue) relative to green along
    /// `direction`, and how much to trust it; nil for a patch without
    /// enough edges or without a clear best alignment.
    ///
    /// Compared on gradients along the direction rather than on values, so
    /// the colours' different brightness doesn't matter, by normalised
    /// cross-correlation, so neither does their contrast.
    public static func radialShift(pixels: [SIMD3<Float>], width: Int, height: Int, channel: Int,
                                   direction u: SIMD2<Float>) -> (shift: Float, weight: Float)? {
        guard width > 16, height > 16, pixels.count == width * height else { return nil }
        // Log values, so an edge's gradient means the same in shadow and
        // highlight, and the per-channel gain cancels.
        func value(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let px = pixels[y * width + x]
            let v = c == 0 ? px.x : (c == 1 ? px.y : px.z)
            return log(max(v, 1e-4))
        }
        var grad = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 2)
        for (slot, c) in [(0, 1), (1, channel)] {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let gx = (value(x + 1, y, c) - value(x - 1, y, c)) * 0.5
                    let gy = (value(x, y + 1, c) - value(x, y - 1, c)) * 0.5
                    grad[slot][y * width + x] = gx * u.x + gy * u.y
                }
            }
        }
        let green = grad[0], other = grad[1]
        func sampleOther(_ x: Float, _ y: Float) -> Float {
            let x0 = Int(floor(x)), y0 = Int(floor(y))
            let fx = x - Float(x0), fy = y - Float(y0)
            func at(_ xi: Int, _ yi: Int) -> Float {
                other[min(max(yi, 0), height - 1) * width + min(max(xi, 0), width - 1)]
            }
            let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * fx
            let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * fx
            return top + (bottom - top) * fy
        }
        // Only pixels far enough in that every shifted read stays inside.
        let margin = Int(searchRange.rounded(.up)) + 3
        var energy: Float = 0, count: Float = 0
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                let g = green[y * width + x]
                energy += g * g; count += 1
            }
        }
        // A patch whose green gradients are this weak has no edge worth
        // measuring (the threshold is about a 5 % step across a pixel or
        // two over a small part of the patch).
        let meanEnergy = energy / max(count, 1)
        guard meanEnergy > 2e-4 else { return nil }

        let steps = Int((2 * searchRange / searchStep).rounded())
        var scores: [Float] = []
        for i in 0...steps {
            let s = -searchRange + Float(i) * searchStep
            var sgo: Float = 0, soo: Float = 0
            for y in margin..<(height - margin) {
                for x in margin..<(width - margin) {
                    let g = green[y * width + x]
                    let o = sampleOther(Float(x) + s * u.x, Float(y) + s * u.y)
                    sgo += g * o; soo += o * o
                }
            }
            scores.append(sgo / max((energy * soo).squareRoot(), 1e-12))
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let peak = scores[best]
        // Poorly aligned even at its best: the colours don't share edges
        // here (coloured objects, not fringes).
        guard peak > 0.6 else { return nil }
        // At the end of the search range the true shift may lie beyond it.
        guard best > 0, best < steps else { return nil }
        let a = scores[best - 1], b = peak, c = scores[best + 1]
        let denominator = a - 2 * b + c
        let refine = abs(denominator) > 1e-9 ? 0.5 * (a - c) / denominator : 0
        let shift = -searchRange + (Float(best) + max(-0.5, min(0.5, refine))) * searchStep
        return (shift, peak * peak * meanEnergy.squareRoot())
    }

    /// k in shift = k × radius, by weighted least squares through zero,
    /// fitted twice: the second time without samples more than half a
    /// pixel off the first fit. Nil with fewer than four usable samples.
    public static func fitScale(_ samples: [Sample]) -> Float? {
        func fit(_ s: [Sample]) -> Float? {
            let num = s.reduce(Float(0)) { $0 + $1.weight * $1.shift * $1.radius }
            let den = s.reduce(Float(0)) { $0 + $1.weight * $1.radius * $1.radius }
            return den > 0 ? num / den : nil
        }
        guard samples.count >= 4, let first = fit(samples) else { return nil }
        let kept = samples.filter { abs($0.shift - first * $0.radius) <= 0.5 }
        guard kept.count >= 4 else { return nil }
        return fit(kept)
    }
}
