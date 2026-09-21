import Foundation
import Accelerate
import CoreGraphics
import simd
import PixelEngine

/// Find Faces and the regeneration of a stored face list into the region
/// masks the touch-up stage samples (docs/Retouch.md §7).
///
/// Two grids meet here. Vision works on the analysis render, whose pixel
/// x sits at sensor position (x + 0.5) × span on the *output* (lens
/// corrected) grid; the masks live at half sensor resolution on that
/// same grid, since the stage samples them by output position. The
/// sidecar, though, stores a face box on the *raw* grid, so the box
/// survives a lens or keystone change: `find` maps a detected box back
/// through `rawSensorPoint`, and `build` maps a stored one forward with
/// `outputSensorPoint` before seeding Vision again. Both then build the
/// masks from a seeded refit, so the editor and an export agree.
public enum TouchUpRegions {
    public struct Found: Sendable {
        /// Raw-grid boxes, left to right.
        public var faces: [TouchUpFace]
        public var tooSmall: Int
        public var masks: TouchUpMaskSet
        /// 40 pt upright crops.
        public var thumbnails: [UUID: SendableImage]

        public init(faces: [TouchUpFace], tooSmall: Int, masks: TouchUpMaskSet, thumbnails: [UUID: SendableImage]) {
            self.faces = faces
            self.tooSmall = tooSmall
            self.masks = masks
            self.thumbnails = thumbnails
        }
    }

    /// A face narrower than this in the upright analysis render is
    /// dropped and counted: the 76-point fit is unreliable below it and
    /// there is nothing to smooth at that size.
    static let minimumFaceWidth: CGFloat = 64
    /// The thumbnail's side in pixels: 40 pt at the Retina scale.
    static let thumbnailSide = 80

    /// Find Faces: detect, map boxes output → raw (rawSensorPoint), refit
    /// from those seeds, build masks.
    public static func find(in render: TouchUpAnalysis.Render, session: ImageSession, pipeline: RenderPipeline,
                            parameters: EditParameters) -> Found {
        let image = render.image
        let sensorSize = CGSize(width: image.width, height: image.height)
        let detected = FaceLandmarker.detect(in: image, rotation: render.rotation)
        var kept: [(face: FaceObservation, width: CGFloat)] = []
        var tooSmall = 0
        for face in detected {
            // The box is in normalised sensor coordinates; its width in
            // the upright image is its sensor height when the turn swaps
            // the axes.
            let width = render.rotation.swapsAxes ? face.boundingBox.height * sensorSize.height
                                                  : face.boundingBox.width * sensorSize.width
            if width < minimumFaceWidth { tooSmall += 1 } else { kept.append((face, width)) }
        }
        // The module holds at most 16 faces: the widest ones, which are
        // the ones a retouch is for, back in left-to-right order.
        if kept.count > TouchUp.maximumFaces {
            kept = Array(kept.sorted { $0.width > $1.width }.prefix(TouchUp.maximumFaces))
            kept.sort { uprightX($0.face, render: render) < uprightX($1.face, render: render) }
        }
        let summary = session.file.summary
        let rawSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        var touchUp = TouchUp()
        touchUp.modelVersion = FaceLandmarker.modelVersion
        var thumbnails: [UUID: SendableImage] = [:]
        for (face, _) in kept {
            let box = rawBox(of: face, render: render, rawSize: rawSize, session: session,
                             pipeline: pipeline, parameters: parameters)
            let stored = TouchUpFace(boundingBox: box)
            touchUp.faces.append(stored)
            if let thumbnail = thumbnail(of: face, render: render) {
                thumbnails[stored.id] = SendableImage(cgImage: thumbnail)
            }
        }
        let (masks, _) = build(touchUp, from: render, session: session, pipeline: pipeline, parameters: parameters)
        return Found(faces: touchUp.faces, tooSmall: tooSmall, masks: masks, thumbnails: thumbnails)
    }

    /// Regeneration: stored raw boxes → output grid (outputSensorPoint) →
    /// seeded refit → masks; `missing` are faces kept with an empty mask
    /// because Vision could not refit them.
    public static func build(_ touchUp: TouchUp, from render: TouchUpAnalysis.Render, session: ImageSession,
                             pipeline: RenderPipeline, parameters: EditParameters) -> (masks: TouchUpMaskSet, missing: [UUID]) {
        let summary = session.file.summary
        let size = TouchUpMaskSet.size(sensorWidth: summary.rawWidth, sensorHeight: summary.rawHeight)
        var set = TouchUpMaskSet(faces: [], width: size.width, height: size.height,
                                 modelVersion: FaceLandmarker.modelVersion)
        guard !touchUp.faces.isEmpty else { return (set, []) }
        let rawSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        let seeds = touchUp.faces.map {
            outputSeed(for: $0.boundingBox, render: render, rawSize: rawSize, session: session,
                       pipeline: pipeline, parameters: parameters)
        }
        let fits = FaceLandmarker.refit(in: render.image, rotation: render.rotation, seeds: seeds)
        var missing: [UUID] = []
        for (face, fit) in zip(touchUp.faces, fits) {
            if let fit, let built = FaceMaskBuilder.build(fit, id: face.id, render: render,
                                                          setWidth: size.width, setHeight: size.height) {
                set.faces.append(built)
            } else {
                missing.append(face.id)
                set.faces.append(.init(id: face.id, origin: SIMD2(0, 0), width: 0, height: 0,
                                       skin: [], teeth: [], eyes: []))
            }
        }
        return (set, missing)
    }

    /// ExportWorker's entry: render + build + session.setTouchUpMasks;
    /// no-op unless touchUp.wantsMasks.
    @discardableResult
    public static func regenerate(_ touchUp: TouchUp, session: ImageSession, pipeline: RenderPipeline, gpu: GPUContext,
                                  parameters: EditParameters, rotation: ImageRotation) throws -> [UUID] {
        guard touchUp.wantsMasks else { return [] }
        let render = try TouchUpAnalysis.render(session: session, pipeline: pipeline, gpu: gpu,
                                                parameters: parameters, rotation: rotation)
        let (masks, missing) = build(touchUp, from: render, session: session, pipeline: pipeline,
                                     parameters: parameters)
        session.setTouchUpMasks(masks)
        return missing
    }

    // MARK: - Boxes between the grids

    /// A detected box (normalised on the render) as a raw-grid box
    /// normalised by the sensor: the four corners go through the lens map
    /// and the result is their extent.
    static func rawBox(of face: FaceObservation, render: TouchUpAnalysis.Render, rawSize: SIMD2<Float>,
                       session: ImageSession, pipeline: RenderPipeline, parameters: EditParameters) -> SIMD4<Float> {
        let span = Float(render.span)
        let b = face.boundingBox
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                       CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)].map { corner in
            let output = SIMD2(Float(corner.x) * Float(render.image.width) * span,
                               Float(corner.y) * Float(render.image.height) * span)
            return pipeline.rawSensorPoint(forOutputPoint: output, session: session, parameters: parameters) / rawSize
        }
        return extent(of: corners)
    }

    /// A stored raw-grid box as a seed on the render: normalised by the
    /// render's sensor extent (width × span), the frame `FaceLandmarker`
    /// takes seeds in.
    static func outputSeed(for box: SIMD4<Float>, render: TouchUpAnalysis.Render, rawSize: SIMD2<Float>,
                           session: ImageSession, pipeline: RenderPipeline, parameters: EditParameters) -> CGRect {
        let span = Float(render.span)
        let renderSize = SIMD2(Float(render.image.width) * span, Float(render.image.height) * span)
        let corners = [SIMD2(box.x, box.y), SIMD2(box.x + box.z, box.y),
                       SIMD2(box.x, box.y + box.w), SIMD2(box.x + box.z, box.y + box.w)].map { corner in
            pipeline.outputSensorPoint(forRawPoint: corner * rawSize, session: session, parameters: parameters) / renderSize
        }
        let e = extent(of: corners)
        return CGRect(x: CGFloat(e.x), y: CGFloat(e.y), width: CGFloat(e.z), height: CGFloat(e.w))
    }

    /// x, y, w, h of the points' bounding box.
    static func extent(of points: [SIMD2<Float>]) -> SIMD4<Float> {
        var lo = points[0], hi = points[0]
        for p in points.dropFirst() { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return SIMD4(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y)
    }

    /// The box's centre in the upright image, for left-to-right order.
    static func uprightX(_ face: FaceObservation, render: TouchUpAnalysis.Render) -> CGFloat {
        let size = CGSize(width: render.image.width, height: render.image.height)
        let centre = CGPoint(x: face.boundingBox.midX * size.width, y: face.boundingBox.midY * size.height)
        return render.rotation.imagePoint(fromSensorPoint: centre, sensorSize: size).x
    }

    /// A square crop around the face, turned upright and scaled to the
    /// row's thumbnail size.
    static func thumbnail(of face: FaceObservation, render: TouchUpAnalysis.Render) -> CGImage? {
        let image = render.image
        let size = CGSize(width: image.width, height: image.height)
        let b = face.boundingBox
        let box = CGRect(x: b.minX * size.width, y: b.minY * size.height,
                         width: b.width * size.width, height: b.height * size.height)
        let side = max(box.width, box.height) * 1.2
        let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size)).integral
        guard square.width >= 1, square.height >= 1,
              let crop = image.cropping(to: square),
              let upright = UprightImage.rotated(crop, by: render.rotation),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: thumbnailSide, height: thumbnailSide, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Fit the crop in the square, centred, on a clear background.
        let scale = CGFloat(thumbnailSide) / CGFloat(max(upright.width, upright.height))
        let w = CGFloat(upright.width) * scale, h = CGFloat(upright.height) * scale
        context.interpolationQuality = .high
        context.draw(upright, in: CGRect(x: (CGFloat(thumbnailSide) - w) / 2, y: (CGFloat(thumbnailSide) - h) / 2,
                                         width: w, height: h))
        return context.makeImage()
    }
}

/// CGImage across a detached task (the public form of the app's wrapper).
/// CGImage is immutable, but the SDK doesn't say it is Sendable.
public struct SendableImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(cgImage: CGImage) { self.cgImage = cgImage }
}

// MARK: - One face's masks

/// Builds a face's skin, teeth and eyes planes at half sensor resolution
/// on the output grid from its landmarks (docs/Retouch.md §7 Regions).
///
/// Everything is drawn from the points themselves, never from Vision's
/// roll angle or the upright frame, so a face in a portrait shot (its
/// landmarks sideways on the sensor) gets the same masks as an upright
/// one. The work is over the face's crop alone (a few hundred thousand
/// pixels for a typical face): the fills, the colour gates and the
/// histograms are Swift loops on unsafe buffers, the morphology and the
/// feather are vImage.
struct FaceMaskBuilder {
    /// Half-res pixels per analysis pixel.
    let quads: Int
    /// The crop's origin and size, half-res pixels of the mask set.
    let originX: Int, originY: Int, width: Int, height: Int
    /// CIELAB of the crop, one value per pixel.
    let lab: LabPlanes
    /// The landmarks in crop pixels.
    let face: FaceObservation
    /// Temple to temple, in crop pixels: the face's width the plan's
    /// sizes are fractions of.
    let faceWidth: Float
    /// Unit vector from the first temple to the last, and the up axis
    /// perpendicular to it pointing away from the chin.
    let across: SIMD2<Float>, up: SIMD2<Float>

    static func build(_ observation: FaceObservation, id: UUID, render: TouchUpAnalysis.Render,
                      setWidth: Int, setHeight: Int) -> TouchUpMaskSet.Face? {
        guard let builder = FaceMaskBuilder(observation, render: render, setWidth: setWidth, setHeight: setHeight),
              builder.width > 0, builder.height > 0 else { return nil }
        return TouchUpMaskSet.Face(id: id, origin: SIMD2(builder.originX, builder.originY),
                                   width: builder.width, height: builder.height,
                                   skin: builder.skin(), teeth: builder.teeth(), eyes: builder.eyes())
    }

    /// Nil when the landmarks are too few to draw a face from.
    init?(_ observation: FaceObservation, render: TouchUpAnalysis.Render, setWidth: Int, setHeight: Int) {
        guard observation.faceContour.count >= 5, observation.leftEye.count >= 3, observation.rightEye.count >= 3 else {
            return nil
        }
        quads = max(1, render.quads)
        let image = render.image
        // Normalised render coordinates to half-res pixels: sensor is
        // norm × width × span, and half-res is half of that.
        let scale = SIMD2(Float(image.width) * Float(quads), Float(image.height) * Float(quads))
        var f = observation.mapped { $0 * scale }
        let box = CGRect(x: f.boundingBox.minX * CGFloat(scale.x), y: f.boundingBox.minY * CGFloat(scale.y),
                         width: f.boundingBox.width * CGFloat(scale.x), height: f.boundingBox.height * CGFloat(scale.y))

        // The axes and the face width from the temples, before the crop
        // is known: the forehead arc's apex may reach above the box.
        let t0 = f.faceContour[0], t1 = f.faceContour[f.faceContour.count - 1]
        let chin = f.faceContour[f.faceContour.count / 2]
        let temples = t1 - t0
        let templeDistance = simd_length(temples)
        guard templeDistance > 1 else { return nil }
        across = temples / templeDistance
        let mid = (t0 + t1) / 2
        var perpendicular = SIMD2(-across.y, across.x)
        if simd_dot(perpendicular, mid - chin) < 0 { perpendicular = -perpendicular }
        up = perpendicular
        faceWidth = templeDistance
        let apex = mid + up * (0.55 * abs(simd_dot(chin - mid, up)))

        // The crop: the box widened a quarter, taking in every landmark
        // and the arc with room for the feather, inside the mask set.
        var extent = box.insetBy(dx: -box.width * 0.125, dy: -box.height * 0.125)
        let all = f.faceContour + f.leftEye + f.rightEye + f.leftEyebrow + f.rightEyebrow + f.nose
            + f.outerLips + f.innerLips + [apex]
        for p in all { extent = extent.union(CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0)) }
        let reach = CGFloat(Self.featherSigma(faceWidth: templeDistance) * 3 + 4)
        extent = extent.insetBy(dx: -reach, dy: -reach)
        let x0 = max(0, Int(extent.minX.rounded(.down))), y0 = max(0, Int(extent.minY.rounded(.down)))
        let x1 = min(setWidth, Int(extent.maxX.rounded(.up))), y1 = min(setHeight, Int(extent.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        originX = x0; originY = y0; width = x1 - x0; height = y1 - y0

        let shift = SIMD2(Float(x0), Float(y0))
        f = f.mapped { $0 - shift }
        face = f

        guard let planes = LabPlanes(of: image, quads: quads, originX: x0, originY: y0, width: width, height: height) else {
            return nil
        }
        lab = planes
    }

    /// The feather's sigma in half-res pixels: 0.015 × the face width.
    static func featherSigma(faceWidth: Float) -> Float { 0.015 * faceWidth }

    // MARK: Skin

    /// The face contour closed by the forehead arc, gated to the skin's
    /// own colour, minus the eyes, brows, lips and nostrils; closed and
    /// feathered.
    func skin() -> [UInt8] {
        let sigma = Self.featherSigma(faceWidth: faceWidth)
        var raster = Raster(width: width, height: height)
        raster.fillPolygon(foreheadPolygon())

        // The chroma gate: within 8 Δab of the polygon's median colour is
        // skin, past 16 it is hair, a collar or a background seen through
        // the arc; a lightness far from the median is a shadowed neck or
        // a highlight on glasses.
        let (medianL, medianA, medianB) = lab.medians(where: raster.pixels)
        raster.pixels.withUnsafeMutableBufferPointer { m in
            for i in 0..<m.count where m[i] > 0 {
                let da = lab.a[i] - medianA, db = lab.b[i] - medianB
                let gate = abs(lab.L[i] - medianL) < 35 ? 1 - Self.smoothstep(8, 16, (da * da + db * db).squareRoot()) : 0
                m[i] = UInt8(gate * 255 + 0.5)
            }
        }

        // What is not skin inside the outline.
        var cut = Raster(width: width, height: height)
        cut.fillPolygon(Self.scaled(face.leftEye, by: 1.25))
        cut.fillPolygon(Self.scaled(face.rightEye, by: 1.25))
        for nostril in nostrils() { cut.fillDisc(centre: nostril, radius: 0.05 * faceWidth) }
        var brows = Raster(width: width, height: height)
        brows.fillPolygon(face.leftEyebrow)
        brows.fillPolygon(face.rightEyebrow)
        brows.dilate(radius: max(1, Int(sigma.rounded())))
        var lips = Raster(width: width, height: height)
        lips.fillPolygon(face.outerLips)
        lips.dilate(radius: max(1, Int((sigma / 2).rounded())))
        raster.subtract(cut)
        raster.subtract(brows)
        raster.subtract(lips)

        // Closing fills the pinholes the gate leaves (a freckle, a pore's
        // shadow); the gate's soft edge is kept where it was.
        raster.closeKeepingSoftEdges(radius: 3)
        raster.blur(sigma: sigma)
        return raster.pixels
    }

    /// The contour from temple to temple, then back over the forehead on
    /// half an ellipse whose apex sits 0.55 × the contour's height above
    /// the temple midpoint along the up axis.
    func foreheadPolygon() -> [SIMD2<Float>] {
        let t0 = face.faceContour[0], t1 = face.faceContour[face.faceContour.count - 1]
        let chin = face.faceContour[face.faceContour.count / 2]
        let mid = (t0 + t1) / 2
        let halfWidth = simd_length(t1 - t0) / 2
        let rise = 0.55 * abs(simd_dot(chin - mid, up))
        var polygon = face.faceContour
        let steps = 24
        for k in 1..<steps {
            let theta = Float(k) / Float(steps) * .pi
            polygon.append(mid + across * (halfWidth * cos(theta)) + up * (rise * sin(theta)))
        }
        return polygon
    }

    /// Where the nostrils are: the nose outline's two ends along the
    /// across axis (the wings), which is where the outline is widest.
    func nostrils() -> [SIMD2<Float>] {
        guard face.nose.count >= 2 else { return [] }
        let along = face.nose.map { simd_dot($0, across) }
        let left = face.nose[along.indices.min { along[$0] < along[$1] }!]
        let right = face.nose[along.indices.max { along[$0] < along[$1] }!]
        return [left, right]
    }

    // MARK: Teeth

    /// The inner lips' fill where the pixels are brighter than the lips
    /// and nearly grey: teeth, not tongue or lip. Eroded and feathered a
    /// pixel; nothing under 16 px², which is a closed mouth's glint.
    func teeth() -> [UInt8] {
        let empty = Raster(width: width, height: height)
        guard face.innerLips.count >= 3, face.outerLips.count >= 3 else { return empty.pixels }
        var raster = Raster(width: width, height: height)
        raster.fillPolygon(face.innerLips)
        var lips = Raster(width: width, height: height)
        lips.fillPolygon(face.outerLips)
        lips.subtract(raster)
        guard lips.count > 0 else { return empty.pixels }
        let bounds = pixelBounds(of: face.outerLips)
        let lipL = lab.L.percentile(0.5, where: lips.pixels, in: bounds)
        let w = width
        raster.pixels.withUnsafeMutableBufferPointer { m in
            for y in bounds.rows {
                for i in (y * w + bounds.columns.lowerBound)..<(y * w + bounds.columns.upperBound) where m[i] > 0 {
                    let chroma = (lab.a[i] * lab.a[i] + lab.b[i] * lab.b[i]).squareRoot()
                    m[i] = (lab.L[i] > lipL + 15 && chroma < 25) ? 255 : 0
                }
            }
        }
        raster.erode(radius: 1)
        guard raster.count >= 16 else { return empty.pixels }
        raster.blur(sigma: 1)
        return raster.pixels
    }

    // MARK: Eyes

    /// Each eye's outline: sclera 255 and iris 128 told apart by
    /// lightness, the pupil disc (0.16 × the eye's width) at 0, feathered
    /// a pixel.
    func eyes() -> [UInt8] {
        var raster = Raster(width: width, height: height)
        for (outline, pupil) in [(face.leftEye, face.leftPupil), (face.rightEye, face.rightPupil)] {
            guard outline.count >= 3 else { continue }
            var fill = Raster(width: width, height: height)
            fill.fillPolygon(outline)
            guard fill.count > 0 else { continue }
            let along = outline.map { simd_dot($0, across) }
            let eyeWidth = along.max()! - along.min()!
            let centre = pupil.first ?? outline.reduce(SIMD2<Float>(0, 0), +) / Float(outline.count)
            let pupilRadius = 0.16 * eyeWidth
            let bounds = pixelBounds(of: outline)
            let histogram = Plane.histograms([lab.L], where: fill.pixels, in: bounds)[0]
            let threshold = (Plane.percentile(0.1, of: histogram) + Plane.percentile(0.9, of: histogram)) / 2
            let w = width
            raster.pixels.withUnsafeMutableBufferPointer { m in
                fill.pixels.withUnsafeBufferPointer { inside in
                    for y in bounds.rows {
                        for x in bounds.columns where inside[y * w + x] > 0 {
                            let i = y * w + x
                            let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                            let value: UInt8 = simd_length(p - centre) <= pupilRadius ? 0 : (lab.L[i] < threshold ? 128 : 255)
                            m[i] = max(m[i], value)
                        }
                    }
                }
            }
        }
        raster.blur(sigma: 1)
        return raster.pixels
    }

    // MARK: Helpers

    /// The rows and columns of the crop a polygon can touch, so a small
    /// feature's loops don't walk the whole face.
    func pixelBounds(of polygon: [SIMD2<Float>]) -> PixelBounds {
        guard !polygon.isEmpty else { return PixelBounds(rows: 0..<0, columns: 0..<0) }
        let x0 = max(0, Int(polygon.map(\.x).min()!.rounded(.down)) - 1)
        let x1 = min(width, Int(polygon.map(\.x).max()!.rounded(.up)) + 2)
        let y0 = max(0, Int(polygon.map(\.y).min()!.rounded(.down)) - 1)
        let y1 = min(height, Int(polygon.map(\.y).max()!.rounded(.up)) + 2)
        return PixelBounds(rows: y0..<max(y0, y1), columns: x0..<max(x0, x1))
    }

    /// A polygon grown about its centroid.
    static func scaled(_ polygon: [SIMD2<Float>], by factor: Float) -> [SIMD2<Float>] {
        guard !polygon.isEmpty else { return polygon }
        let centroid = polygon.reduce(SIMD2<Float>(0, 0), +) / Float(polygon.count)
        return polygon.map { centroid + ($0 - centroid) * factor }
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

extension FaceObservation {
    /// Every landmark through `transform`; the box is left as it is.
    func mapped(_ transform: (SIMD2<Float>) -> SIMD2<Float>) -> FaceObservation {
        var f = self
        f.faceContour = faceContour.map(transform)
        f.leftEye = leftEye.map(transform); f.rightEye = rightEye.map(transform)
        f.leftPupil = leftPupil.map(transform); f.rightPupil = rightPupil.map(transform)
        f.leftEyebrow = leftEyebrow.map(transform); f.rightEyebrow = rightEyebrow.map(transform)
        f.nose = nose.map(transform)
        f.outerLips = outerLips.map(transform); f.innerLips = innerLips.map(transform)
        return f
    }
}

/// A rectangle of a crop as row and column ranges.
struct PixelBounds {
    var rows: Range<Int>
    var columns: Range<Int>
}

/// One Float per pixel of a crop, in memory that hot loops index
/// without an array's checks.
final class Plane {
    let width: Int
    let count: Int
    let values: UnsafeMutablePointer<Float>

    init(width: Int, height: Int) {
        self.width = width
        count = width * height
        values = .allocate(capacity: max(count, 1))
        values.initialize(repeating: 0, count: max(count, 1))
    }

    deinit { values.deallocate() }

    subscript(i: Int) -> Float {
        get { values[i] }
        set { values[i] = newValue }
    }

    /// The value `fraction` of the way up the values where `mask` is set
    /// (within `bounds`, when the mask is known to lie there).
    func percentile(_ fraction: Float, where mask: [UInt8], in bounds: PixelBounds? = nil) -> Float {
        Self.percentile(fraction, of: Self.histograms([self], where: mask, in: bounds)[0])
    }

    /// A sixteenth-step histogram over −128…128 (L* and a*/b* of any
    /// real pixel) of each plane where `mask` is set, in one pass, so a
    /// percentile costs the same whatever the crop's size.
    static let bins = 4096

    static func histograms(_ planes: [Plane], where mask: [UInt8], in bounds: PixelBounds? = nil) -> [[Int32]] {
        var histograms = [[Int32]](repeating: [Int32](repeating: 0, count: bins), count: planes.count)
        guard let first = planes.first, first.width > 0 else { return histograms }
        let width = first.width
        let rows = bounds?.rows ?? 0..<(first.count / width)
        let columns = bounds?.columns ?? 0..<width
        mask.withUnsafeBufferPointer { m in
            for (index, plane) in planes.enumerated() {
                let values = plane.values
                histograms[index].withUnsafeMutableBufferPointer { h in
                    for y in rows {
                        for i in (y * width + columns.lowerBound)..<(y * width + columns.upperBound) where m[i] > 0 {
                            var bin = Int((values[i] + 128) * 16)
                            if bin < 0 { bin = 0 } else if bin >= bins { bin = bins - 1 }
                            h[bin] += 1
                        }
                    }
                }
            }
        }
        return histograms
    }

    static func percentile(_ fraction: Float, of histogram: [Int32]) -> Float {
        let total = histogram.reduce(0) { $0 + Int($1) }
        guard total > 0 else { return 0 }
        let target = Int32(Float(total - 1) * fraction)
        var seen: Int32 = 0
        for bin in 0..<bins {
            seen += histogram[bin]
            if seen > target { return Float(bin) / 16 - 128 }
        }
        return 128
    }
}

/// CIELAB (D65) of a face's crop, resampled to half-res pixels.
struct LabPlanes {
    let L: Plane, a: Plane, b: Plane

    /// Analysis pixel x covers half-res pixels x × quads ..< (x + 1) ×
    /// quads exactly, so the image is drawn scaled by the quads with its
    /// edge at the crop's origin.
    init?(of image: CGImage, quads: Int, originX: Int, originY: Int, width: Int, height: Int) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = quads > 1 ? .high : .none
            // Core Graphics draws y-up: the image's top edge goes
            // `originY` above the crop's top.
            let scaledHeight = CGFloat(image.height * quads)
            context.draw(image, in: CGRect(x: CGFloat(-originX), y: CGFloat(height + originY) - scaledHeight,
                                           width: CGFloat(image.width * quads), height: scaledHeight))
            return true
        }
        guard drawn else { return nil }
        // sRGB to linear, once per code value.
        let linear = (0..<256).map { v -> Float in
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let count = width * height
        L = Plane(width: width, height: height)
        a = Plane(width: width, height: height)
        b = Plane(width: width, height: height)
        rgba.withUnsafeBufferPointer { px in
            linear.withUnsafeBufferPointer { lut in
                for i in 0..<count {
                    let r = lut[Int(px[i * 4])], g = lut[Int(px[i * 4 + 1])], bl = lut[Int(px[i * 4 + 2])]
                    // sRGB primaries to XYZ, relative to the D65 white.
                    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * bl) / 0.95047
                    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl
                    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * bl) / 1.08883
                    let fx = Self.f(x), fy = Self.f(y), fz = Self.f(z)
                    L[i] = 116 * fy - 16
                    a[i] = 500 * (fx - fy)
                    b[i] = 200 * (fy - fz)
                }
            }
        }
    }

    @inline(__always) static func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }

    /// The three medians where `mask` is set, in one pass.
    func medians(where mask: [UInt8]) -> (L: Float, a: Float, b: Float) {
        let histograms = Plane.histograms([L, a, b], where: mask)
        return (Plane.percentile(0.5, of: histograms[0]), Plane.percentile(0.5, of: histograms[1]),
                Plane.percentile(0.5, of: histograms[2]))
    }
}

/// A single-channel 8-bit raster over a face's crop, with the few
/// operations the masks need: polygon and disc fills at pixel centres,
/// morphology and a Gaussian feather. The fills are plain Swift; the
/// morphology and the blur go through vImage, whose Planar8 filters run
/// at memory speed in any build (a debug build of the same loops in
/// Swift is ten times over the budget).
struct Raster {
    let width: Int, height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
    }

    /// Pixels over a half.
    var count: Int {
        pixels.withUnsafeBufferPointer { p in
            var n = 0
            for i in 0..<p.count where p[i] > 127 { n += 1 }
            return n
        }
    }

    /// Sets the pixels whose centre is inside `polygon` (even-odd rule).
    mutating func fillPolygon(_ polygon: [SIMD2<Float>]) {
        guard polygon.count >= 3 else { return }
        let minY = max(0, Int(polygon.map(\.y).min()!.rounded(.down)))
        let maxY = min(height - 1, Int(polygon.map(\.y).max()!.rounded(.up)))
        guard minY <= maxY else { return }
        let width = width
        var crossings: [Float] = []
        pixels.withUnsafeMutableBufferPointer { m in
            for y in minY...maxY {
                let sampleY = Float(y) + 0.5
                crossings.removeAll(keepingCapacity: true)
                for i in polygon.indices {
                    let p = polygon[i], q = polygon[(i + 1) % polygon.count]
                    // An edge crosses the scanline when its ends straddle it
                    // (half-open, so a vertex on the line counts once).
                    guard (p.y <= sampleY) != (q.y <= sampleY) else { continue }
                    crossings.append(p.x + (sampleY - p.y) / (q.y - p.y) * (q.x - p.x))
                }
                crossings.sort()
                var k = 0
                while k + 1 < crossings.count {
                    let x0 = max(0, Int((crossings[k] - 0.5).rounded(.up)))
                    let x1 = min(width - 1, Int((crossings[k + 1] - 0.5).rounded(.down)))
                    if x0 <= x1 { for x in x0...x1 { m[y * width + x] = 255 } }
                    k += 2
                }
            }
        }
    }

    mutating func fillDisc(centre: SIMD2<Float>, radius: Float) {
        let minY = max(0, Int((centre.y - radius).rounded(.down))), maxY = min(height - 1, Int((centre.y + radius).rounded(.up)))
        let minX = max(0, Int((centre.x - radius).rounded(.down))), maxX = min(width - 1, Int((centre.x + radius).rounded(.up)))
        guard minY <= maxY, minX <= maxX else { return }
        let width = width
        pixels.withUnsafeMutableBufferPointer { m in
            for y in minY...maxY {
                for x in minX...maxX {
                    let d = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - centre
                    if simd_length_squared(d) <= radius * radius { m[y * width + x] = 255 }
                }
            }
        }
    }

    /// Keeps what `other` does not cover.
    mutating func subtract(_ other: Raster) {
        pixels.withUnsafeMutableBufferPointer { m in
            other.pixels.withUnsafeBufferPointer { o in
                for i in 0..<m.count { m[i] = UInt8((Int(m[i]) * (255 - Int(o[i])) + 127) / 255) }
            }
        }
    }

    /// Runs a vImage Planar8 filter from the pixels into a fresh buffer.
    /// The filters here only fail for a malformed buffer, which would be
    /// a bug in this file, so a failure stops the process.
    private mutating func filtered(_ filter: (UnsafeMutablePointer<vImage_Buffer>, UnsafeMutablePointer<vImage_Buffer>) -> vImage_Error) {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let width = width, height = height
        let error = pixels.withUnsafeMutableBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst -> vImage_Error in
                var srcBuffer = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width)
                var dstBuffer = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width)
                return filter(&srcBuffer, &dstBuffer)
            }
        }
        precondition(error == kvImageNoError, "vImage failed on a \(width) x \(height) mask: \(error)")
        pixels = out
    }

    /// Square-window dilation (the window clipped at the edges).
    mutating func dilate(radius: Int) {
        let k = vImagePixelCount(2 * radius + 1)
        filtered { vImageMax_Planar8($0, $1, nil, 0, 0, k, k, vImage_Flags(kvImageNoFlags)) }
    }

    /// Square-window erosion (the window clipped at the edges, so the
    /// border isn't eaten).
    mutating func erode(radius: Int) {
        let k = vImagePixelCount(2 * radius + 1)
        filtered { vImageMin_Planar8($0, $1, nil, 0, 0, k, k, vImage_Flags(kvImageNoFlags)) }
    }

    /// A morphological closing that leaves the soft values where they
    /// were: a hole the closing fills becomes 255, a pixel outside the
    /// closed shape 0.
    mutating func closeKeepingSoftEdges(radius: Int) {
        var closed = self
        closed.dilate(radius: radius)
        closed.erode(radius: radius)
        pixels.withUnsafeMutableBufferPointer { m in
            closed.pixels.withUnsafeBufferPointer { c in
                for i in 0..<m.count { m[i] = c[i] > 127 ? (m[i] > 0 ? m[i] : 255) : 0 }
            }
        }
    }

    /// A Gaussian of `sigma` as three box blurs of equal width (their
    /// variance is r² + r), edges extended.
    mutating func blur(sigma: Float) {
        guard sigma > 0.3 else { return }
        let r = max(1, Int(((1 + 4 * sigma * sigma).squareRoot() - 1) / 2 + 0.5))
        let k = UInt32(2 * r + 1)
        for _ in 0..<3 {
            filtered { vImageBoxConvolve_Planar8($0, $1, nil, 0, 0, k, k, 0, vImage_Flags(kvImageEdgeExtend)) }
        }
    }
}
