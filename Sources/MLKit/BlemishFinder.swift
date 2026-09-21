import Foundation
import CoreGraphics
import simd
import PixelEngine

/// Find Blemishes (docs/Retouch.md §7): the classical blob detector over
/// each enabled face, weighted by its skin mask, so a spot on skin
/// becomes a heal patch and a nostril or an eye corner does not.
///
/// Two grids again. The detector runs on the analysis render (output
/// grid, `span` sensor px per pixel), looking for dark dips in log2
/// luminance and red rises in a*, with the face's skin plane (half sensor
/// resolution on the same grid) as the weight. A blob's centre and its
/// source then go through `rawSensorPoint` to the raw grid the sidecar
/// stores heal patches on, like Find Faces' boxes, so a lens or keystone
/// change never moves a blemish off its spot.
public enum BlemishFinder {
    /// The blob's radius as fractions of the face's width: a pore's
    /// shadow at the bottom, a spot the size of a fingertip at the top.
    static let radiusRange: ClosedRange<Float> = 0.004...0.025
    /// Nothing under this on the render: the detector cannot tell a
    /// pixel-sized dip from noise.
    static let minimumRadiusPixels: Float = 1.5
    /// The patch reaches this much past the blob, so the feather starts
    /// outside its soft edge.
    static let patchReach: Float = 1.6
    /// The source is tried this many patch radii away, in eight directions.
    static let sourceDistance: Float = 2.5
    /// A reddish blob must be this far above the skin's median a*: a
    /// warm highlight or a shadow's edge gives a smaller rise.
    static let minimumRedness: Float = 6

    /// The detector's tests, shared by both polarities: a peak of 2.5
    /// local noise sigmas, round, with a quiet surround. The contrast
    /// floors are in each map's units (stops, a*).
    static func parameters(radius: ClosedRange<Float>, polarity: BlobDetector.Polarity) -> BlobDetector.Parameters {
        BlobDetector.Parameters(radiusRange: radius, polarity: polarity, contrastSigma: 2.5,
                                minimumContrast: polarity == .dark ? 0.03 : 3, minimumCircularity: 0.6,
                                smoothSurround: 3, maximumSurroundGradient: nil,
                                maximumCount: HealPatch.maximumBlemishCount)
    }

    /// BlobDetector over each enabled face's box with the skin slice as
    /// weight; raw-grid HealPatches (cap 64), excluding blobs inside any
    /// of `existing` (heals + dust).
    public static func find(in render: TouchUpAnalysis.Render, masks: TouchUpMaskSet, touchUp: TouchUp,
                            existing: [HealPatch], session: ImageSession, pipeline: RenderPipeline,
                            parameters: EditParameters) -> [HealPatch] {
        let summary = session.file.summary
        let rawSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        return find(in: render, masks: masks, touchUp: touchUp, existing: existing, rawSize: rawSize) { output in
            pipeline.rawSensorPoint(forOutputPoint: output, session: session, parameters: parameters)
        }
    }

    /// A blob on one face before it becomes a patch: analysis pixels of
    /// the render, plus its centre on the raw grid in sensor px.
    struct Candidate {
        var face: Int
        var centre: SIMD2<Float>       // analysis px
        var radius: Float              // analysis px
        var score: Float
        var raw: SIMD2<Float>          // raw sensor px
    }

    /// The same without a session: `rawSize` is the sensor in px and
    /// `toRaw` maps an output-grid sensor point to the raw grid (the
    /// identity without lens correction). What the tests drive.
    static func find(in render: TouchUpAnalysis.Render, masks: TouchUpMaskSet, touchUp: TouchUp,
                     existing: [HealPatch], rawSize: SIMD2<Float>,
                     toRaw: (SIMD2<Float>) -> SIMD2<Float>) -> [HealPatch] {
        let span = Float(render.span)
        let shortSide = min(rawSize.x, rawSize.y)
        guard span > 0, shortSide > 0 else { return [] }
        func output(_ analysis: SIMD2<Float>) -> SIMD2<Float> { (analysis + 0.5) * span }

        // One crop per enabled face with a mask: its blobs, scored.
        var crops: [FaceCrop] = []
        var candidates: [Candidate] = []
        for face in touchUp.faces where face.enabled {
            guard let plane = masks.faces.first(where: { $0.id == face.id }),
                  let crop = FaceCrop(render: render, plane: plane, faceWidthSensorPx: face.boundingBox.z * rawSize.x) else {
                continue
            }
            let index = crops.count
            crops.append(crop)
            for blob in crop.blobs() {
                let centre = crop.origin + blob.centre
                candidates.append(Candidate(face: index, centre: centre, radius: blob.radius, score: blob.score,
                                            raw: toRaw(output(centre))))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Best first; a blob found in both maps, or by two faces that
        // overlap, is kept once. Then nothing inside a patch that is
        // already there: the user's own, or a dust spot.
        candidates.sort { $0.score > $1.score }
        let existingSpots = existing.flatMap { patch in
            patch.pathPoints().map { (centre: $0 * rawSize, radius: patch.radius * shortSide) }
        }
        var kept: [Candidate] = []
        for candidate in candidates {
            let sensorRadius = candidate.radius * span
            let duplicate = kept.contains {
                simd_distance($0.raw, candidate.raw) < 1.5 * ($0.radius * span + sensorRadius)
            }
            if duplicate { continue }
            let healed = existingSpots.contains { simd_distance(candidate.raw, $0.centre) < $0.radius }
            if healed { continue }
            kept.append(candidate)
        }

        var patches: [HealPatch] = []
        for candidate in kept {
            guard patches.count < HealPatch.maximumBlemishCount else { break }
            let sensorRadius = candidate.radius * span
            let patchRadius = patchReach * sensorRadius
            guard let source = sourceCentre(for: candidate, patchRadius: patchRadius, crop: crops[candidate.face],
                                            others: kept, existing: existingSpots, span: span, toRaw: toRaw) else {
                continue
            }
            patches.append(HealPatch(target: candidate.raw / rawSize, source: source / rawSize,
                                     radius: patchRadius / shortSide, feather: 0.5, mode: .heal))
        }
        return patches
    }

    /// Where the patch copies from: `HealPatch.automaticBlemishOffset`
    /// in the plan's words. Eight directions `sourceDistance` patch radii
    /// from the blob, on the render; a candidate must sit on the face's
    /// skin (weight at least a half, which also keeps it inside the face
    /// outline) and clear of every other blob and existing patch, and
    /// the one with the most skin under it wins, the direction to the
    /// right first among equals. Nil when nowhere near is clean: the
    /// blob is dropped rather than healed from an eye or a lip.
    static func sourceCentre(for candidate: Candidate, patchRadius: Float, crop: FaceCrop, others: [Candidate],
                             existing: [(centre: SIMD2<Float>, radius: Float)], span: Float,
                             toRaw: (SIMD2<Float>) -> SIMD2<Float>) -> SIMD2<Float>? {
        let distance = sourceDistance * patchRadius / span
        let directions: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1),
            SIMD2(0.7071, 0.7071), SIMD2(-0.7071, 0.7071), SIMD2(0.7071, -0.7071), SIMD2(-0.7071, -0.7071)]
        var best: (centre: SIMD2<Float>, weight: Float)?
        for direction in directions {
            let centre = candidate.centre + direction * distance
            let weight = crop.weight(at: centre)
            guard weight >= 0.5 else { continue }
            let raw = toRaw((centre + 0.5) * span)
            let overlapsBlob = others.contains { other in
                other.centre != candidate.centre && simd_distance(raw, other.raw) < patchRadius + other.radius * span
            }
            if overlapsBlob { continue }
            let overlapsPatch = existing.contains { simd_distance(raw, $0.centre) < patchRadius + $0.radius }
            if overlapsPatch { continue }
            if best.map({ weight > $0.weight }) ?? true { best = (raw, weight) }
        }
        return best?.centre
    }

    // MARK: - One face

    /// A face's crop of the analysis render as the detector sees it: log2
    /// luminance and a* planes, and the skin plane resampled from the
    /// mask set as the weight. Analysis pixel x covers half-res pixels
    /// x × quads ..< (x + 1) × quads, so the weight is the skin value at
    /// the pixel's first half-res sample.
    struct FaceCrop {
        /// Analysis px of the crop's top-left corner.
        let origin: SIMD2<Float>
        let width: Int, height: Int
        let luminance: [Float]
        let redness: [Float]
        let weight: [Float]
        /// Analysis px.
        let radius: ClosedRange<Float>
        /// The skin's median a*, for the redness test.
        let medianA: Float

        init?(render: TouchUpAnalysis.Render, plane: TouchUpMaskSet.Face, faceWidthSensorPx: Float) {
            let quads = max(1, render.quads)
            let image = render.image
            // The mask's crop, in analysis pixels, clipped to the render.
            let x0 = max(0, plane.origin.x / quads), y0 = max(0, plane.origin.y / quads)
            let x1 = min(image.width, (plane.origin.x + plane.width + quads - 1) / quads)
            let y1 = min(image.height, (plane.origin.y + plane.height + quads - 1) / quads)
            let width = x1 - x0, height = y1 - y0
            guard width >= 8, height >= 8, plane.skin.count == plane.width * plane.height,
                  let lab = LabPlanes(of: image, quads: 1, originX: x0, originY: y0, width: width, height: height) else {
                return nil
            }
            let faceWidth = faceWidthSensorPx / Float(render.span)
            let lo = max(BlemishFinder.radiusRange.lowerBound * faceWidth, BlemishFinder.minimumRadiusPixels)
            let hi = max(BlemishFinder.radiusRange.upperBound * faceWidth, lo + 0.5)
            origin = SIMD2(Float(x0), Float(y0))
            self.width = width
            self.height = height
            radius = lo...hi

            let count = width * height
            var luminance = [Float](repeating: 0, count: count)
            var redness = [Float](repeating: 0, count: count)
            var weight = [Float](repeating: 0, count: count)
            var skinMask = [UInt8](repeating: 0, count: count)
            plane.skin.withUnsafeBufferPointer { skin in
                for y in 0..<height {
                    let hy = (y0 + y) * quads - plane.origin.y
                    for x in 0..<width {
                        let i = y * width + x
                        luminance[i] = log2(max(FaceCrop.luminance(fromLightness: lab.L[i]), 1e-4))
                        redness[i] = lab.a[i]
                        let hx = (x0 + x) * quads - plane.origin.x
                        if hx >= 0, hy >= 0, hx < plane.width, hy < plane.height {
                            let s = skin[hy * plane.width + hx]
                            weight[i] = Float(s) / 255
                            skinMask[i] = s
                        }
                    }
                }
            }
            self.luminance = luminance
            self.redness = redness
            self.weight = weight
            medianA = lab.a.percentile(0.5, where: skinMask)
        }

        /// L* back to relative luminance: the Lab curve undone.
        static func luminance(fromLightness L: Float) -> Float {
            let fy: Float = (L + 16) / 116
            let knee: Float = 6.0 / 29.0
            if fy > knee { return fy * fy * fy }
            return 3 * knee * knee * (fy - 4.0 / 29.0)
        }

        /// Dark dips and red rises on the skin, each list best first.
        func blobs() -> [BlobDetector.Blob] {
            let dark = BlobDetector.detect(BlobDetector.Map(values: luminance, width: width, height: height, weight: weight),
                                           BlemishFinder.parameters(radius: radius, polarity: .dark))
            let red = BlobDetector.detect(BlobDetector.Map(values: redness, width: width, height: height, weight: weight),
                                          BlemishFinder.parameters(radius: radius, polarity: .reddish))
                .filter { rednessAt($0.centre, radius: $0.radius) - medianA > BlemishFinder.minimumRedness }
            return dark + red
        }

        /// The mean a* within half the radius of `centre`.
        func rednessAt(_ centre: SIMD2<Float>, radius: Float) -> Float {
            let r = max(0.5 * radius, 0.5)
            let x0 = max(Int((centre.x - r).rounded(.down)), 0), x1 = min(Int((centre.x + r).rounded(.up)), width - 1)
            let y0 = max(Int((centre.y - r).rounded(.down)), 0), y1 = min(Int((centre.y + r).rounded(.up)), height - 1)
            guard x1 >= x0, y1 >= y0 else { return redness[index(of: centre)] }
            var sum: Float = 0, n = 0
            for y in y0...y1 {
                for x in x0...x1 where simd_distance(SIMD2(Float(x), Float(y)), centre) <= r {
                    sum += redness[y * width + x]; n += 1
                }
            }
            return n > 0 ? sum / Float(n) : redness[index(of: centre)]
        }

        /// The skin weight at an analysis point of the render; 0 outside
        /// the crop.
        func weight(at point: SIMD2<Float>) -> Float {
            let local = point - origin
            guard local.x >= 0, local.y >= 0, local.x < Float(width), local.y < Float(height) else { return 0 }
            return weight[index(of: local)]
        }

        private func index(of local: SIMD2<Float>) -> Int {
            let x = min(max(Int(local.x.rounded()), 0), width - 1), y = min(max(Int(local.y.rounded()), 0), height - 1)
            return y * width + x
        }
    }
}
