import Foundation
import Accelerate
import simd

/// The classical blob detector shared by sensor dust and blemishes
/// (docs/Retouch.md contract C): dark (or reddish) round dips in a
/// Float32 map, found as difference-of-Gaussian peaks and checked for
/// size, roundness, contrast against the local noise and a smooth
/// surround. Swift and Accelerate only, so PixelEngineTests can drive it
/// on synthetic scenes without a GPU.
///
/// The heavy passes (blurs, the pyramid, peak masks, interpolation) run
/// in vImage and vDSP, so a 6 MP map is quick even in a debug build;
/// only the candidates, a few hundred at most, are walked in Swift.
public enum BlobDetector {
    public enum Polarity: Sendable, Equatable {
        /// A dip in luminance: dust shadows, dark blemishes.
        case dark
        /// A rise in a*: a red blemish on skin.
        case reddish
    }

    public struct Parameters: Sendable, Equatable {
        /// Pixels of the map.
        public var radiusRange: ClosedRange<Float>
        public var polarity: Polarity
        /// A peak counts when it is at least this many local noise sigmas.
        public var contrastSigma: Float
        /// A floor under the noise test, in map units (log2 stops, or a*).
        public var minimumContrast: Float
        /// 4πA/P², 0…1.
        public var minimumCircularity: Float
        /// The annulus residual's standard deviation may be at most this
        /// many local noise sigmas; nil doesn't require it.
        public var smoothSurround: Float?
        /// Mean |∇(G_2r∗D)| over the annulus, map units per pixel.
        public var maximumSurroundGradient: Float?
        public var maximumCount: Int

        public init(radiusRange: ClosedRange<Float>, polarity: Polarity, contrastSigma: Float, minimumContrast: Float,
                    minimumCircularity: Float, smoothSurround: Float?, maximumSurroundGradient: Float?, maximumCount: Int) {
            self.radiusRange = radiusRange
            self.polarity = polarity
            self.contrastSigma = contrastSigma
            self.minimumContrast = minimumContrast
            self.minimumCircularity = minimumCircularity
            self.smoothSurround = smoothSurround
            self.maximumSurroundGradient = maximumSurroundGradient
            self.maximumCount = maximumCount
        }
    }

    public struct Blob: Sendable, Equatable {
        /// Map pixels, pixel centres.
        public var centre: SIMD2<Float>
        /// Map pixels (r_eq = √(A/π)).
        public var radius: Float
        /// Map units.
        public var contrast: Float
        public var score: Float

        public init(centre: SIMD2<Float>, radius: Float, contrast: Float, score: Float) {
            self.centre = centre
            self.radius = radius
            self.contrast = contrast
            self.score = score
        }
    }

    public struct Map: Sendable {
        /// Row-major, width × height.
        public var values: [Float]
        public var width: Int
        public var height: Int
        /// Optional per-pixel weight 0…1 (a skin mask): a blob whose centre
        /// weight is under 0.5 is rejected, and the score is multiplied by it.
        public var weight: [Float]?

        public init(values: [Float], width: Int, height: Int, weight: [Float]? = nil) {
            self.values = values
            self.width = width
            self.height = height
            self.weight = weight
        }
    }

    /// Best first, capped at `p.maximumCount`.
    public static func detect(_ map: Map, _ p: Parameters) -> [Blob] {
        detect(map, p, noise: nil)
    }

    /// `detect` with the noise map already measured (`DustDetector.Analysis`
    /// keeps it), so a slider move doesn't estimate it again.
    public static func detect(_ map: Map, _ p: Parameters, noise: [Float]?) -> [Blob] {
        guard map.width >= 8, map.height >= 8, map.values.count == map.width * map.height,
              p.radiusRange.lowerBound > 0, p.radiusRange.lowerBound.isFinite, p.maximumCount > 0 else { return [] }
        return Field(map: map, noise: noise).detect(p)
    }

    /// One map spot checked in another image (`DustDetector.verify`): the
    /// strongest DoG peak at scale `radius` within `radius` of `centre`,
    /// put through every test of `detect` at the local threshold. Nil when
    /// no peak clears the threshold or a test fails.
    static func verify(at centre: SIMD2<Float>, radius: Float, in map: Map, _ p: Parameters, noise: [Float]?) -> Blob? {
        guard map.width >= 8, map.height >= 8, map.values.count == map.width * map.height,
              radius > 0, radius.isFinite, centre.x.isFinite, centre.y.isFinite else { return nil }
        return Field(map: map, noise: noise).verify(at: centre, radius: radius, p)
    }

    /// The contrast of a spot as `detect` measures it: the surround's plane
    /// fit at the centre minus the mean inside half the radius, in map
    /// units (positive for a dark spot). Nil off the map.
    static func contrast(at centre: SIMD2<Float>, radius: Float, in map: Map) -> Float? {
        guard map.values.count == map.width * map.height, centre.x.isFinite, centre.y.isFinite else { return nil }
        let plane = Plane(width: map.width, height: map.height, values: map.values)
        return Field.surround(of: plane, centre: centre, radius: radius)?.contrast
    }

    /// 1.4826 × MAD of (D − G₁∗D) per `tile`² tile, bilinearly interpolated
    /// back to the map's size.
    public static func localNoise(_ map: Map, tile: Int = 64) -> [Float] {
        let w = map.width, h = map.height
        guard w > 0, h > 0, map.values.count == w * h else { return [] }
        let tile = max(tile, 2)
        let plane = Plane(width: w, height: h, values: map.values)
        // The residual after a one-pixel blur is nearly all noise: a scene
        // changes slowly over a pixel, noise doesn't.
        var residual = plane.blurred(sigma: 1).values
        residual.withUnsafeMutableBufferPointer { r in
            map.values.withUnsafeBufferPointer { d in
                vDSP_vsub(r.baseAddress!, 1, d.baseAddress!, 1, r.baseAddress!, 1, vDSP_Length(w * h))
            }
        }
        let tilesX = (w + tile - 1) / tile, tilesY = (h + tile - 1) / tile
        var sigma = [Float](repeating: 0, count: tilesX * tilesY)
        var centresX = [Float](repeating: 0, count: tilesX), centresY = [Float](repeating: 0, count: tilesY)
        var scratch = [Float](repeating: 0, count: tile * tile)
        var last: Float = 0
        for ty in 0..<tilesY {
            let y0 = ty * tile, th = min(tile, h - y0)
            centresY[ty] = Float(2 * y0 + th - 1) / 2
            for tx in 0..<tilesX {
                let x0 = tx * tile, tw = min(tile, w - x0)
                centresX[tx] = Float(2 * x0 + tw - 1) / 2
                // Every other row and column: a median from a quarter of
                // the pixels is as good as one from all of them, at a
                // quarter of the sorting.
                let sw = (tw + 1) / 2, sh = (th + 1) / 2
                let n = sw * sh
                // A sliver of a tile at the edge says little; it takes its
                // neighbour's estimate.
                guard n >= 16 else { sigma[ty * tilesX + tx] = last; continue }
                residual.withUnsafeBufferPointer { r in
                    scratch.withUnsafeMutableBufferPointer { s in
                        var zero: Float = 0
                        for row in 0..<sh {
                            vDSP_vsadd(r.baseAddress! + (y0 + 2 * row) * w + x0, 2, &zero, s.baseAddress! + row * sw, 1, vDSP_Length(sw))
                        }
                        vDSP_vsort(s.baseAddress!, vDSP_Length(n), 1)
                        var negMedian = -median(s.baseAddress!, n)
                        vDSP_vsadd(s.baseAddress!, 1, &negMedian, s.baseAddress!, 1, vDSP_Length(n))
                        vDSP_vabs(s.baseAddress!, 1, s.baseAddress!, 1, vDSP_Length(n))
                        vDSP_vsort(s.baseAddress!, vDSP_Length(n), 1)
                        last = 1.4826 * median(s.baseAddress!, n)
                    }
                }
                sigma[ty * tilesX + tx] = last
            }
        }
        let grid = Plane(width: tilesX, height: tilesY, values: sigma)
        return grid.resampled(width: w, height: h, centresX: centresX, centresY: centresY)
    }

    /// G_{3σ}∗D − G_σ∗D through a pyramid (σ ≤ 4 px per level), upsampled
    /// to the map's size.
    public static func differenceOfGaussians(_ map: Map, sigma: Float) -> [Float] {
        let w = map.width, h = map.height
        guard w > 0, h > 0, map.values.count == w * h, sigma > 0, sigma.isFinite else {
            return [Float](repeating: 0, count: max(0, w * h))
        }
        let pyramid = Pyramid(base: Plane(width: w, height: h, values: map.values))
        let (response, level) = pyramid.differenceOfGaussians(sigma: sigma)
        return response.upsampled(by: 1 << level, width: w, height: h)
    }

    // MARK: - Working state

    /// The map, its pyramid and its noise, shared by `detect` and `verify`.
    /// A `.reddish` search negates the response, so every later test
    /// looks for a dip whatever the polarity.
    final class Field {
        let base: Plane
        let weight: [Float]?
        let noise: Plane
        let pyramid: Pyramid
        private var noiseLevels: [Plane]

        init(map: Map, noise: [Float]?) {
            base = Plane(width: map.width, height: map.height, values: map.values)
            weight = map.weight?.count == map.width * map.height ? map.weight : nil
            let sigma: [Float]
            if let noise, noise.count == map.width * map.height {
                sigma = noise
            } else {
                sigma = BlobDetector.localNoise(map)
            }
            self.noise = Plane(width: map.width, height: map.height, values: sigma)
            noiseLevels = [self.noise]
            pyramid = Pyramid(base: base)
        }

        /// The noise map at pyramid level `k` (box-averaged like the map).
        func noiseLevel(_ k: Int) -> Plane {
            while noiseLevels.count <= k { noiseLevels.append(noiseLevels.last!.halved()) }
            return noiseLevels[k]
        }

        /// A DoG peak, before the region and surround tests.
        struct Candidate {
            var position: SIMD2<Float>    // map px (pixel-index frame)
            var value: Float              // normalised response
            var scale: Float
        }

        /// The response's gain on a disc dip of contrast c and radius s
        /// ((1 − e^{−1/2}) − (1 − e^{−1/18})): the DoG is divided by it so a
        /// blob at least as big as its scale reads at least its contrast,
        /// and the noise test compares like with like.
        static let matchedGain: Float = 0.3394

        func detect(_ p: Parameters) -> [Blob] {
            let lo = p.radiusRange.lowerBound, hi = max(p.radiusRange.upperBound, lo)
            let scales: [Float] = [lo, (lo * hi).squareRoot(), hi]
            var blobs: [Blob] = []
            // One scale at a time: the response of the scale before stays
            // until its candidates have been compared with this one's.
            var previous: (response: Plane, maximum: Plane, level: Int, scale: Float, pending: [Candidate])?
            for s in scales {
                let (response, level) = normalisedResponse(sigma: s, p)
                var (candidates, maximum) = peaks(in: response, level: level, scale: s, p)
                if let prev = previous {
                    // Across-scale maxima, compared as s·R against the other
                    // scale's 3×3 maximum (so a peak a pixel off is the same
                    // peak): the plain DoG peaks at about r = 2.2s, so a scale
                    // under half the blob would win and the 2s flood fill
                    // would clip it; weighting by s keeps the winner within a
                    // factor of two of the blob.
                    let factor = 1 << level, prevFactor = 1 << prev.level
                    for c in prev.pending where c.value * c.scale >= maximum.bilinear(at: c.position, factor: factor) * s {
                        if let blob = evaluate(c, response: prev.response, level: prev.level, p) { blobs.append(blob) }
                    }
                    candidates = candidates.filter { c in
                        c.value * c.scale > prev.maximum.bilinear(at: c.position, factor: prevFactor) * prev.scale
                    }
                }
                previous = (response, maximum, level, s, candidates)
            }
            if let prev = previous {
                for c in prev.pending {
                    if let blob = evaluate(c, response: prev.response, level: prev.level, p) { blobs.append(blob) }
                }
            }
            return Self.merged(blobs, cap: p.maximumCount)
        }

        /// The DoG at a scale, signed for the polarity and divided by the
        /// matched gain, at its pyramid level.
        private func normalisedResponse(sigma s: Float, _ p: Parameters) -> (Plane, Int) {
            let sign: Float = p.polarity == .reddish ? -1 : 1
            let (difference, level) = pyramid.differenceOfGaussians(sigma: s)
            var response = difference
            var gain = sign / Self.matchedGain
            response.values.withUnsafeMutableBufferPointer { r in
                vDSP_vsmul(r.baseAddress!, 1, &gain, r.baseAddress!, 1, vDSP_Length(r.count))
            }
            return (response, level)
        }

        func verify(at centre: SIMD2<Float>, radius r: Float, _ p: Parameters) -> Blob? {
            let sign: Float = p.polarity == .reddish ? -1 : 1
            let level = Pyramid.level(forSigma: r)
            let factor = Float(1 << level)
            let sigma = r / factor
            // The DoG on a window around the spot, both Gaussians at the
            // scale's level: cheaper than the whole map for one spot. The
            // window reaches past the wider blur's kernel and the 2s flood
            // fill of a peak at the search radius.
            let search = r / factor
            let half = Int((3 * search + 9 * sigma).rounded(.up)) + 2
            let window = base.window(centre: centre, half: half, level: level)
            var response = window.plane.blurred(sigma: 3 * sigma)
            let narrow = window.plane.blurred(sigma: sigma)
            response.values.withUnsafeMutableBufferPointer { out in
                narrow.values.withUnsafeBufferPointer { n in
                    vDSP_vsub(n.baseAddress!, 1, out.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(out.count))
                }
                var gain = sign / Self.matchedGain
                vDSP_vsmul(out.baseAddress!, 1, &gain, out.baseAddress!, 1, vDSP_Length(out.count))
            }
            // The strongest response within ±r of the spot.
            var best: (x: Int, y: Int, value: Float)?
            let cx = window.centre.x, cy = window.centre.y
            for y in 0..<response.height {
                for x in 0..<response.width {
                    let dx = Float(x) - cx, dy = Float(y) - cy
                    guard dx * dx + dy * dy <= search * search else { continue }
                    let v = response.values[y * response.width + x]
                    if best == nil || v > best!.value { best = (x, y, v) }
                }
            }
            guard let best else { return nil }
            let position = window.origin + SIMD2(Float(best.x), Float(best.y)) * factor
            let clamped = SIMD2(min(max(position.x, 0), Float(base.width - 1)), min(max(position.y, 0), Float(base.height - 1)))
            guard best.value >= threshold(at: clamped, p) else { return nil }
            let candidate = Candidate(position: clamped, value: best.value, scale: r)
            return evaluate(candidate, response: response, level: level, origin: window.origin, p)
        }

        /// σ_local at a map position.
        func sigma(at position: SIMD2<Float>) -> Float {
            let x = min(max(Int(position.x.rounded()), 0), noise.width - 1)
            let y = min(max(Int(position.y.rounded()), 0), noise.height - 1)
            return noise.values[y * noise.width + x]
        }

        /// max(minimumContrast, contrastSigma × σ_local) at a map position.
        func threshold(at position: SIMD2<Float>, _ p: Parameters) -> Float {
            max(p.minimumContrast, p.contrastSigma * sigma(at: position), 1e-6)
        }

        /// 3×3 maxima of the response at its level that clear the local
        /// threshold, as positions on the map, with the 3×3 maximum plane
        /// itself. The mask is built in vImage and vDSP; only the survivors
        /// are visited.
        func peaks(in response: Plane, level: Int, scale: Float, _ p: Parameters) -> (candidates: [Candidate], maximum: Plane) {
            let w = response.width, h = response.height, n = w * h
            guard w >= 3, h >= 3 else { return ([], response) }
            let factor = Float(1 << level)
            let noiseK = noiseLevel(level)
            guard noiseK.width == w, noiseK.height == h else { return ([], response) }
            var thr = [Float](repeating: 0, count: n)
            var floor = max(p.minimumContrast, 1e-6), cs = p.contrastSigma
            var maximum = [Float](repeating: 0, count: n)
            var mask = [Float](repeating: 0, count: n)
            let ok: Bool = response.values.withUnsafeBufferPointer { r in
                noiseK.values.withUnsafeBufferPointer { s in
                    thr.withUnsafeMutableBufferPointer { t in
                        maximum.withUnsafeMutableBufferPointer { m in
                            mask.withUnsafeMutableBufferPointer { k in
                                // Threshold plane: max(minimumContrast, contrastSigma × σ).
                                vDSP_vsmul(s.baseAddress!, 1, &cs, t.baseAddress!, 1, vDSP_Length(n))
                                vDSP_vthr(t.baseAddress!, 1, &floor, t.baseAddress!, 1, vDSP_Length(n))
                                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: r.baseAddress!),
                                                        height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                                var dst = vImage_Buffer(data: m.baseAddress!, height: vImagePixelCount(h),
                                                        width: vImagePixelCount(w), rowBytes: w * 4)
                                guard vImageMax_PlanarF(&src, &dst, nil, 0, 0, 3, 3, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
                                else { return false }
                                // mask = min(R − max3, R − thr) ≥ 0 → 1, else 0.
                                vDSP_vsub(m.baseAddress!, 1, r.baseAddress!, 1, k.baseAddress!, 1, vDSP_Length(n))
                                vDSP_vsub(t.baseAddress!, 1, r.baseAddress!, 1, t.baseAddress!, 1, vDSP_Length(n))
                                vDSP_vmin(k.baseAddress!, 1, t.baseAddress!, 1, k.baseAddress!, 1, vDSP_Length(n))
                                var zero: Float = 0, one: Float = 1
                                vDSP_vlim(k.baseAddress!, 1, &zero, &one, k.baseAddress!, 1, vDSP_Length(n))
                                vDSP_vthr(k.baseAddress!, 1, &zero, k.baseAddress!, 1, vDSP_Length(n))
                                return true
                            }
                        }
                    }
                }
            }
            let maximumPlane = Plane(width: w, height: h, values: maximum)
            guard ok else { return ([], maximumPlane) }
            var count: Float = 0
            vDSP_sve(mask, 1, &count, vDSP_Length(n))
            let found = Int(count)
            guard found > 0 else { return ([], maximumPlane) }
            // The indices of the set pixels: a ramp compressed by the mask.
            var ramp = [Float](repeating: 0, count: n)
            var start: Float = 0, step: Float = 1
            vDSP_vramp(&start, &step, &ramp, 1, vDSP_Length(n))
            var indices = [Float](repeating: 0, count: n)
            vDSP_vcmprs(ramp, 1, mask, 1, &indices, 1, vDSP_Length(n))
            var candidates: [Candidate] = []
            candidates.reserveCapacity(found)
            for i in 0..<found {
                let index = Int(indices[i])
                let x = index % w, y = index / w
                let position = SIMD2(Float(x), Float(y)) * factor + SIMD2(repeating: (factor - 1) / 2)
                candidates.append(Candidate(position: position, value: response.values[index], scale: scale))
            }
            // A flood of noise peaks at a loose threshold would take
            // seconds to check one by one; the strongest are the ones
            // that could matter.
            if candidates.count > Self.candidateCap {
                candidates.sort { $0.value > $1.value }
                candidates.removeLast(candidates.count - Self.candidateCap)
            }
            return (candidates, maximumPlane)
        }

        static let candidateCap = 4000

        /// Region, roundness, contrast and surround tests on one candidate.
        /// `origin` is where `response`'s pixel (0, 0) sits on the map when
        /// it is a window rather than a whole level.
        func evaluate(_ c: Candidate, response: Plane, level: Int, origin: SIMD2<Float>? = nil, _ p: Parameters) -> Blob? {
            let factor = 1 << level
            let reach = 2 * c.scale
            let half = Int(reach.rounded(.up))
            let size = 2 * half + 1
            // The response around the peak at map resolution, then the
            // flood fill of everything above half the peak within 2s.
            var window = [Float](repeating: 0, count: size * size)
            let ox = Int(c.position.x.rounded()) - half, oy = Int(c.position.y.rounded()) - half
            for y in 0..<size {
                for x in 0..<size {
                    let position = SIMD2(Float(ox + x), Float(oy + y))
                    window[y * size + x] = response.bilinear(at: position, factor: factor, origin: origin)
                }
            }
            let cut = 0.5 * c.value
            var inRegion = [Bool](repeating: false, count: size * size)
            var stack = [half * size + half]
            inRegion[stack[0]] = true
            var area = 0, crack = 0
            var weightedSum = SIMD2<Float>.zero, weightSum: Float = 0
            var sxx: Float = 0, syy: Float = 0, sxy: Float = 0
            let reach2 = reach * reach
            // A neighbour outside the window or the 2s circle, or below the
            // cut, is a boundary edge; one above it joins the region.
            func visit(_ nx: Int, _ ny: Int) {
                let dx = Float(nx - half), dy = Float(ny - half)
                guard nx >= 0, ny >= 0, nx < size, ny < size, dx * dx + dy * dy <= reach2 else { crack += 1; return }
                let ni = ny * size + nx
                if inRegion[ni] { return }
                if window[ni] > cut {
                    inRegion[ni] = true
                    stack.append(ni)
                } else {
                    crack += 1
                }
            }
            while let index = stack.popLast() {
                let x = index % size, y = index / size
                area += 1
                let w = max(window[index] - cut, 0)
                let dx = Float(x - half), dy = Float(y - half)
                weightedSum += SIMD2(Float(ox + x), Float(oy + y)) * w
                weightSum += w
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
                visit(x - 1, y); visit(x + 1, y); visit(x, y - 1); visit(x, y + 1)
            }
            guard weightSum > 0, area >= 3 else { return nil }
            let radius = (Float(area) / .pi).squareRoot()
            guard p.radiusRange.contains(radius) else { return nil }
            // Perimeter from the crack count: pixel edges overstate a
            // curve's length by 4/π on average, so π/4 of them is it. A
            // region the 2s circle cuts short can look compact when it is a
            // piece of a line, so the axis ratio of its second moments
            // (1 for a disc) bounds the circularity as well.
            let perimeter = Float(crack) * .pi / 4
            let isoperimetric = min(4 * .pi * Float(area) / (perimeter * perimeter), 1)
            let mx = sxx / Float(area), my = syy / Float(area), mxy = sxy / Float(area)
            let spread = ((mx - my) * (mx - my) + 4 * mxy * mxy).squareRoot()
            let major = (mx + my + spread) / 2, minor = (mx + my - spread) / 2
            let axisRatio = major > 0 ? (max(minor, 0) / major).squareRoot() : 1
            let circularity = min(isoperimetric, axisRatio)
            guard circularity >= p.minimumCircularity else { return nil }
            let centre = weightedSum / weightSum
            guard centre.x >= 0, centre.y >= 0, centre.x <= Float(base.width - 1), centre.y <= Float(base.height - 1) else { return nil }

            let threshold = threshold(at: centre, p)
            let sigma = sigma(at: centre)
            guard let surround = Self.surround(of: base, centre: centre, radius: radius, sign: p.polarity == .reddish ? -1 : 1)
            else { return nil }
            guard surround.contrast >= threshold else { return nil }
            if let smooth = p.smoothSurround, surround.residualStd > smooth * sigma { return nil }
            if let maximumGradient = p.maximumSurroundGradient {
                let gradient = base.meanGradient(centre: centre, sigma: 2 * radius, innerRadius: 1.5 * radius, outerRadius: 3 * radius)
                guard gradient <= maximumGradient else { return nil }
            }
            var w: Float = 1
            if let weight {
                let x = min(max(Int(centre.x.rounded()), 0), base.width - 1)
                let y = min(max(Int(centre.y.rounded()), 0), base.height - 1)
                w = weight[y * base.width + x]
                guard w >= 0.5 else { return nil }
            }
            return Blob(centre: centre, radius: radius, contrast: surround.contrast,
                        score: surround.contrast / threshold * circularity * w)
        }

        struct Surround {
            /// The plane fitted to the annulus, at the centre, minus the
            /// mean inside half the radius.
            var contrast: Float
            /// Standard deviation of the annulus about its plane fit.
            var residualStd: Float
        }

        /// The annulus [1.5r, 3r] fitted with a plane (a sky gradient must
        /// not count as texture) and the disc inside r/2, on `plane`;
        /// `sign` −1 measures a rise instead of a dip.
        static func surround(of plane: Plane, centre: SIMD2<Float>, radius: Float, sign: Float = 1) -> Surround? {
            let r = max(radius, 1)
            let inner = 1.5 * r, outer = 3 * r, core = max(0.5 * r, 1)
            let x0 = max(Int((centre.x - outer).rounded(.down)), 0), x1 = min(Int((centre.x + outer).rounded(.up)), plane.width - 1)
            let y0 = max(Int((centre.y - outer).rounded(.down)), 0), y1 = min(Int((centre.y + outer).rounded(.up)), plane.height - 1)
            guard x0 <= x1, y0 <= y1 else { return nil }
            // Every `step`th pixel of a big annulus: a few hundred samples
            // fit a plane as well as thousands, at a fraction of the walk.
            let step = max(Int((r / 6).rounded(.up)), 1)
            let inner2 = inner * inner, outer2 = outer * outer, core2 = core * core
            // Normal equations for v ≈ a + b·dx + c·dy over the annulus.
            var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sv = 0.0, svx = 0.0, svy = 0.0
            var coreSum: Float = 0, coreCount = 0
            plane.values.withUnsafeBufferPointer { values in
                for y in stride(from: y0, through: y1, by: step) {
                    let dy = Float(y) - centre.y
                    for x in stride(from: x0, through: x1, by: step) {
                        let dx = Float(x) - centre.x
                        let d2 = dx * dx + dy * dy
                        guard d2 >= inner2 && d2 <= outer2 else { continue }
                        let fx = Double(dx), fy = Double(dy), fv = Double(values[y * plane.width + x])
                        n += 1; sx += fx; sy += fy; sxx += fx * fx; syy += fy * fy; sxy += fx * fy
                        sv += fv; svx += fv * fx; svy += fv * fy
                    }
                }
                let cx0 = max(Int((centre.x - core).rounded(.down)), 0), cx1 = min(Int((centre.x + core).rounded(.up)), plane.width - 1)
                let cy0 = max(Int((centre.y - core).rounded(.down)), 0), cy1 = min(Int((centre.y + core).rounded(.up)), plane.height - 1)
                if cx0 <= cx1, cy0 <= cy1 {
                    for y in cy0...cy1 {
                        let dy = Float(y) - centre.y
                        for x in cx0...cx1 {
                            let dx = Float(x) - centre.x
                            guard dx * dx + dy * dy <= core2 else { continue }
                            coreSum += values[y * plane.width + x]; coreCount += 1
                        }
                    }
                }
            }
            guard n >= 12, coreCount >= 1 else { return nil }
            let normal = simd_double3x3(rows: [SIMD3(n, sx, sy), SIMD3(sx, sxx, sxy), SIMD3(sy, sxy, syy)])
            guard abs(normal.determinant) > 1e-9 else { return nil }
            let fit = normal.inverse * SIMD3(sv, svx, svy)
            var residual = 0.0
            plane.values.withUnsafeBufferPointer { values in
                for y in stride(from: y0, through: y1, by: step) {
                    let dy = Float(y) - centre.y
                    for x in stride(from: x0, through: x1, by: step) {
                        let dx = Float(x) - centre.x
                        let d2 = dx * dx + dy * dy
                        guard d2 >= inner2 && d2 <= outer2 else { continue }
                        let e = Double(values[y * plane.width + x]) - (fit.x + fit.y * Double(dx) + fit.z * Double(dy))
                        residual += e * e
                    }
                }
            }
            return Surround(contrast: sign * (Float(fit.x) - coreSum / Float(coreCount)),
                            residualStd: Float((residual / n).squareRoot()))
        }

        /// Best first; a blob closer than 1.5(r₁ + r₂) to a better one is
        /// the same spot seen twice.
        static func merged(_ blobs: [Blob], cap: Int) -> [Blob] {
            var kept: [Blob] = []
            for blob in blobs.sorted(by: { $0.score > $1.score }) {
                let duplicate = kept.contains { k in
                    simd_distance(k.centre, blob.centre) < 1.5 * (k.radius + blob.radius)
                }
                if !duplicate { kept.append(blob) }
                if kept.count >= cap { break }
            }
            return kept
        }
    }

    // MARK: - Planes and the pyramid

    /// A Float32 image with the vImage and vDSP operations the detector
    /// needs. Pixel (x, y) sits at coordinate (x, y): pixel centres are
    /// whole numbers.
    struct Plane {
        var width: Int
        var height: Int
        var values: [Float]

        init(width: Int, height: Int, values: [Float]) {
            self.width = width
            self.height = height
            self.values = values
        }

        init(width: Int, height: Int) {
            self.init(width: width, height: height, values: [Float](repeating: 0, count: width * height))
        }

        /// Separable Gaussian blur with edge extension; kernel radius 3σ.
        func blurred(sigma: Float) -> Plane {
            guard sigma > 0.2, width > 0, height > 0 else { return self }
            let radius = max(Int((3 * sigma).rounded(.up)), 1)
            var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
            let sum = kernel.reduce(0, +)
            kernel = kernel.map { $0 / sum }
            var out = Plane(width: width, height: height)
            let error: vImage_Error = values.withUnsafeBufferPointer { src in
                out.values.withUnsafeMutableBufferPointer { dst in
                    var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                          height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    var d = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width * 4)
                    return vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count),
                                                     0, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
            return error == kvImageNoError ? out : self
        }

        /// 2×2 box average, dropping an odd last column or row.
        func halved() -> Plane {
            let w = width / 2, h = height / 2
            guard w > 0, h > 0 else { return self }
            var out = Plane(width: w, height: h)
            var rowSum = [Float](repeating: 0, count: w)
            var quarter: Float = 0.25
            values.withUnsafeBufferPointer { src in
                out.values.withUnsafeMutableBufferPointer { dst in
                    rowSum.withUnsafeMutableBufferPointer { tmp in
                        for y in 0..<h {
                            let a = src.baseAddress! + 2 * y * width, b = a + width
                            let o = dst.baseAddress! + y * w
                            vDSP_vadd(a, 2, a + 1, 2, tmp.baseAddress!, 1, vDSP_Length(w))
                            vDSP_vadd(b, 2, b + 1, 2, o, 1, vDSP_Length(w))
                            vDSP_vasm(tmp.baseAddress!, 1, o, 1, &quarter, o, 1, vDSP_Length(w))
                        }
                    }
                }
            }
            return out
        }

        /// Bilinear value at map coordinates when this plane is level `k`
        /// of the map's pyramid (`factor` = 2^k), or a window of that level
        /// whose pixel (0, 0) sits at `origin` on the map; clamped at the
        /// edges.
        func bilinear(at position: SIMD2<Float>, factor: Int, origin: SIMD2<Float>? = nil) -> Float {
            let f = Float(factor)
            let origin = origin ?? SIMD2(repeating: (f - 1) / 2)
            let u = min(max((position.x - origin.x) / f, 0), Float(width - 1))
            let v = min(max((position.y - origin.y) / f, 0), Float(height - 1))
            let x0 = min(Int(u), width - 1), y0 = min(Int(v), height - 1)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let tx = u - Float(x0), ty = v - Float(y0)
            let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
            let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
            return top * (1 - ty) + bottom * ty
        }

        /// Bilinear resampling to `w` × `h` with this plane's pixels at
        /// `centresX`/`centresY` (output pixel coordinates, increasing);
        /// outside the first and last centres the edge value holds. Rows
        /// through vDSP_vgenp, then pairs of rows blended by vDSP_vintb.
        func resampled(width w: Int, height h: Int, centresX: [Float], centresY: [Float]) -> [Float] {
            guard w > 0, h > 0, centresX.count == width, centresY.count == height, width > 0, height > 0 else {
                return [Float](repeating: 0, count: max(0, w * h))
            }
            var rows = [Float](repeating: 0, count: height * w)
            values.withUnsafeBufferPointer { src in
                rows.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<height {
                        let out = dst.baseAddress! + y * w
                        if width == 1 {
                            var v = src[y * width]
                            vDSP_vfill(&v, out, 1, vDSP_Length(w))
                        } else {
                            vDSP_vgenp(src.baseAddress! + y * width, 1, centresX, 1, out, 1, vDSP_Length(w), vDSP_Length(width))
                        }
                    }
                }
            }
            var out = [Float](repeating: 0, count: w * h)
            rows.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    var upper = 0
                    for y in 0..<h {
                        let fy = Float(y)
                        while upper < height - 1 && centresY[upper] < fy { upper += 1 }
                        let lower = max(upper - 1, 0)
                        let a = src.baseAddress! + lower * w, b = src.baseAddress! + upper * w
                        let o = dst.baseAddress! + y * w
                        let span = centresY[upper] - centresY[lower]
                        var t = span > 0 ? min(max((fy - centresY[lower]) / span, 0), 1) : 0
                        vDSP_vintb(a, 1, b, 1, &t, o, 1, vDSP_Length(w))
                    }
                }
            }
            return out
        }

        /// This plane, level `k` of a pyramid, back at the map's size.
        func upsampled(by factor: Int, width w: Int, height h: Int) -> [Float] {
            let f = Float(factor)
            let centresX = (0..<width).map { (Float($0) + 0.5) * f - 0.5 }
            let centresY = (0..<height).map { (Float($0) + 0.5) * f - 0.5 }
            return resampled(width: w, height: h, centresX: centresX, centresY: centresY)
        }

        /// A square window of this map at pyramid level `level`, `half`
        /// level pixels each side of `centre` (map coordinates), edges
        /// extended: the region is cut from the full map with clamped
        /// coordinates and box-averaged down, so no whole level is built
        /// for one spot. `origin` is the map coordinate of the window's
        /// pixel (0, 0) at the level; `centre` is where the spot lands in
        /// the window's own coordinates.
        func window(centre: SIMD2<Float>, half: Int, level: Int) -> (plane: Plane, origin: SIMD2<Float>, centre: SIMD2<Float>) {
            let factor = 1 << level
            let fineHalf = (half + 1) * factor
            let cx = Int(centre.x.rounded()), cy = Int(centre.y.rounded())
            let x0 = cx - fineHalf, y0 = cy - fineHalf
            let size = 2 * fineHalf + 1
            var cut = Plane(width: size, height: size)
            values.withUnsafeBufferPointer { src in
                cut.values.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<size {
                        let sy = min(max(y0 + y, 0), height - 1)
                        let row = src.baseAddress! + sy * width
                        let out = dst.baseAddress! + y * size
                        // The run inside the map is a straight copy; the
                        // rest repeats the edge pixel.
                        let first = min(max(-x0, 0), size), last = min(max(width - x0, 0), size)
                        if first > 0 { var v = row[0]; vDSP_vfill(&v, out, 1, vDSP_Length(first)) }
                        if last > first { (out + first).update(from: row + x0 + first, count: last - first) }
                        if size > last { var v = row[width - 1]; vDSP_vfill(&v, out + last, 1, vDSP_Length(size - last)) }
                    }
                }
            }
            for _ in 0..<level { cut = cut.halved() }
            let f = Float(factor)
            // Level pixel (i, j) covers map pixels [x0 + i·f, x0 + (i+1)·f).
            let origin = SIMD2(Float(x0), Float(y0)) + SIMD2(repeating: (f - 1) / 2)
            let local = (centre - origin) / f
            return (cut, origin, local)
        }

        /// Mean |∇(G_σ∗D)| over the annulus [innerRadius, outerRadius]
        /// (a disc when `innerRadius` is 0) around `centre`, in map units
        /// per map pixel, measured on the pyramid level where σ ≤ 4 px.
        func meanGradient(centre: SIMD2<Float>, sigma: Float, innerRadius: Float, outerRadius: Float) -> Float {
            let level = Pyramid.level(forSigma: sigma)
            let f = Float(1 << level)
            let s = sigma / f, outer = outerRadius / f, inner = innerRadius / f
            let half = Int((outer + 3 * s).rounded(.up)) + 2
            let window = window(centre: centre, half: half, level: level)
            let blurred = window.plane.blurred(sigma: s)
            let w = blurred.width, h = blurred.height
            guard w >= 3, h >= 3 else { return 0 }
            var sum: Float = 0, count = 0
            let inner2 = inner * inner, outer2 = outer * outer
            blurred.values.withUnsafeBufferPointer { v in
                for y in 1..<(h - 1) {
                    let dy = Float(y) - window.centre.y
                    for x in 1..<(w - 1) {
                        let dx = Float(x) - window.centre.x
                        let d2 = dx * dx + dy * dy
                        guard d2 >= inner2, d2 <= outer2 else { continue }
                        let gx = (v[y * w + x + 1] - v[y * w + x - 1]) / 2
                        let gy = (v[(y + 1) * w + x] - v[(y - 1) * w + x]) / 2
                        sum += (gx * gx + gy * gy).squareRoot()
                        count += 1
                    }
                }
            }
            return count > 0 ? sum / (Float(count) * f) : 0
        }
    }

    /// The map halved level by level, built as scales ask for it.
    final class Pyramid {
        private var levels: [Plane]

        init(base: Plane) {
            levels = [base]
        }

        /// A blur of σ at the full size costs 6σ taps a pixel each way; at
        /// the level where σ ≤ 4 px the map is 4^k times smaller.
        static func level(forSigma sigma: Float) -> Int {
            var k = 0, s = sigma
            while s > 4 && k < 12 { s /= 2; k += 1 }
            return k
        }

        /// Level `k`, or the deepest one the map allows (a level too small
        /// to blur is no use).
        func level(_ k: Int) -> (plane: Plane, level: Int) {
            while levels.count <= k {
                let next = levels.last!.halved()
                guard next.width >= 4, next.height >= 4, next.width < levels.last!.width else { break }
                levels.append(next)
            }
            let depth = min(k, levels.count - 1)
            return (levels[depth], depth)
        }

        /// G_σ∗D at the level where σ ≤ 4 px.
        func blurred(sigma: Float) -> (plane: Plane, level: Int) {
            let (plane, k) = level(Self.level(forSigma: sigma))
            return (plane.blurred(sigma: sigma / Float(1 << k)), k)
        }

        /// G_{3σ}∗D − G_σ∗D at σ's level: the wider blur is made at its own
        /// (coarser) level and brought up to σ's.
        func differenceOfGaussians(sigma: Float) -> (plane: Plane, level: Int) {
            let narrow = blurred(sigma: sigma)
            let wide = blurred(sigma: 3 * sigma)
            var out = narrow.plane
            let wideValues: [Float]
            if wide.level == narrow.level {
                wideValues = wide.plane.values
            } else {
                wideValues = wide.plane.upsampled(by: 1 << (wide.level - narrow.level), width: out.width, height: out.height)
            }
            out.values.withUnsafeMutableBufferPointer { n in
                wideValues.withUnsafeBufferPointer { w in
                    vDSP_vsub(n.baseAddress!, 1, w.baseAddress!, 1, n.baseAddress!, 1, vDSP_Length(n.count))
                }
            }
            return (out, narrow.level)
        }
    }

    /// The middle of a sorted run.
    private static func median(_ sorted: UnsafePointer<Float>, _ n: Int) -> Float {
        n % 2 == 1 ? sorted[n / 2] : 0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    }
}
