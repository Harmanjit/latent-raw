import XCTest
import CoreGraphics
import simd
import RawCore
import PixelEngine
@testable import MLKit

/// The region masks: a drawn face with hand-written landmarks (always),
/// and Find Faces, regeneration and the export entry on the portrait
/// fixture (skipped when it hasn't been fetched).
final class TouchUpRegionsTests: XCTestCase {
    // MARK: - A synthetic face

    /// A 600 x 800 analysis render (span 2, so the mask set is the same
    /// size): a skin-coloured ellipse on grey with white-and-brown eyes,
    /// dark brows, red lips and white teeth.
    static func drawnFace() -> CGImage {
        let context = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Core Graphics is y-up: flip so every rectangle reads top-left.
        context.translateBy(x: 0, y: 800)
        context.scaleBy(x: 1, y: -1)
        func fill(_ rect: CGRect, _ c: (CGFloat, CGFloat, CGFloat), ellipse: Bool = true) {
            context.setFillColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
            if ellipse { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: (CGFloat, CGFloat, CGFloat)) {
            fill(CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), c)
        }
        fill(CGRect(x: 0, y: 0, width: 600, height: 800), (120, 120, 120), ellipse: false)
        fill(CGRect(x: 150, y: 200, width: 300, height: 400), (222, 175, 145))
        for cx: CGFloat in [240, 360] {
            fill(CGRect(x: cx - 30, y: 326, width: 60, height: 28), (245, 245, 245))
            disc(cx, 340, 16, (70, 50, 35))
            disc(cx, 340, 6, (0, 0, 0))
            fill(CGRect(x: cx - 35, y: 295, width: 70, height: 10), (60, 40, 30), ellipse: false)
        }
        fill(CGRect(x: 240, y: 475, width: 120, height: 50), (190, 80, 90))
        fill(CGRect(x: 250, y: 490, width: 100, height: 20), (250, 250, 245), ellipse: false)
        return context.makeImage()!
    }

    /// The landmarks of `drawnFace`, in normalised render coordinates.
    static func drawnLandmarks() -> FaceObservation {
        func n(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2(x / 600, y / 800) }
        // The contour: the ellipse from the left temple (eye level) down
        // round the chin to the right temple.
        let tilt: Float = asin(0.3)
        let thetaLeft: Float = Float.pi + tilt
        let thetaRight: Float = -tilt
        var contour: [SIMD2<Float>] = []
        for k in 0..<17 {
            let fraction: Float = Float(k) / 16
            let theta: Float = thetaLeft + (thetaRight - thetaLeft) * fraction
            let x: Float = 300 + 150 * cos(theta)
            let y: Float = 400 + 200 * sin(theta)
            contour.append(n(x, y))
        }
        func eye(_ cx: Float) -> [SIMD2<Float>] {
            [n(cx - 30, 340), n(cx - 15, 326), n(cx + 15, 326), n(cx + 30, 340), n(cx + 15, 354), n(cx - 15, 354)]
        }
        func brow(_ cx: Float) -> [SIMD2<Float>] {
            [n(cx - 35, 295), n(cx + 35, 295), n(cx + 35, 305), n(cx - 35, 305)]
        }
        var outerLips: [SIMD2<Float>] = []
        for k in 0..<14 {
            let theta: Float = Float(k) / 14 * 2 * Float.pi
            let x: Float = 300 + 60 * cos(theta)
            let y: Float = 500 + 25 * sin(theta)
            outerLips.append(n(x, y))
        }
        return FaceObservation(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), confidence: 1,
            faceContour: contour, leftEye: eye(240), rightEye: eye(360),
            leftPupil: [n(240, 340)], rightPupil: [n(360, 340)],
            leftEyebrow: brow(240), rightEyebrow: brow(360),
            nose: [n(300, 400), n(285, 430), n(275, 450), n(288, 460), n(300, 462), n(312, 460), n(325, 450), n(315, 430)],
            outerLips: outerLips,
            innerLips: [n(250, 490), n(300, 488), n(350, 490), n(350, 510), n(300, 512), n(250, 510)])
    }

    /// A plane's value at a mask-set pixel; 0 outside the face's crop.
    static func value(_ plane: [UInt8], _ face: TouchUpMaskSet.Face, _ x: Int, _ y: Int) -> Int {
        let lx = x - face.origin.x, ly = y - face.origin.y
        guard lx >= 0, ly >= 0, lx < face.width, ly < face.height else { return 0 }
        return Int(plane[ly * face.width + lx])
    }

    func testDrawnFaceMasksLandWhereExpected() throws {
        let render = TouchUpAnalysis.Render(image: Self.drawnFace(), span: 2, rotation: .none)
        let id = UUID()
        let face = try XCTUnwrap(FaceMaskBuilder.build(Self.drawnLandmarks(), id: id, render: render,
                                                        setWidth: 600, setHeight: 800))
        XCTAssertEqual(face.id, id)
        XCTAssertEqual(face.skin.count, face.width * face.height)
        XCTAssertEqual(face.teeth.count, face.skin.count)
        XCTAssertEqual(face.eyes.count, face.skin.count)
        func skin(_ x: Int, _ y: Int) -> Int { Self.value(face.skin, face, x, y) }
        func teeth(_ x: Int, _ y: Int) -> Int { Self.value(face.teeth, face, x, y) }
        func eyes(_ x: Int, _ y: Int) -> Int { Self.value(face.eyes, face, x, y) }

        // Skin: the cheeks, the forehead under the arc and the nose bridge.
        XCTAssertGreaterThan(skin(220, 450), 200, "left cheek")
        XCTAssertGreaterThan(skin(380, 450), 200, "right cheek")
        XCTAssertGreaterThan(skin(300, 260), 200, "forehead")
        XCTAssertGreaterThan(skin(300, 430), 200, "nose bridge")
        // Not skin: the eyes, brows, mouth, nostrils and everything
        // outside the ellipse.
        XCTAssertLessThan(skin(240, 340), 8, "left eye")
        XCTAssertLessThan(skin(360, 340), 8, "right eye")
        XCTAssertLessThan(skin(240, 300), 40, "left brow")
        XCTAssertLessThan(skin(300, 500), 8, "mouth")
        XCTAssertLessThan(skin(275, 450), 20, "left nostril")
        XCTAssertLessThan(skin(325, 450), 20, "right nostril")
        XCTAssertEqual(skin(100, 400), 0, "beside the face")
        XCTAssertEqual(skin(300, 150), 0, "above the face")
        XCTAssertEqual(skin(300, 700), 0, "below the chin")

        // Teeth: the white strip between the lips, nothing on the lips.
        XCTAssertGreaterThan(teeth(300, 500), 200)
        XCTAssertGreaterThan(teeth(270, 500), 200)
        XCTAssertLessThan(teeth(300, 478), 8, "upper lip")
        XCTAssertLessThan(teeth(300, 522), 8, "lower lip")

        // Eyes: the pupil at 0, the iris ring at 128, the sclera at 255.
        XCTAssertLessThan(eyes(240, 340), 8, "pupil")
        XCTAssertEqual(eyes(253, 340), 128, accuracy: 24, "iris")
        XCTAssertGreaterThan(eyes(264, 340), 200, "sclera")
        XCTAssertGreaterThan(eyes(336, 340), 200, "other sclera")
        XCTAssertEqual(eyes(300, 340), 0, "between the eyes")

        // Nothing outside the box: every set pixel of every plane lies
        // within the ellipse plus the feather's reach, the teeth within
        // the inner lips and the eyes within their outlines.
        for y in 0..<face.height {
            for x in 0..<face.width {
                let sx = Float(x + face.origin.x) + 0.5, sy = Float(y + face.origin.y) + 0.5
                let i = y * face.width + x
                if face.skin[i] > 0 {
                    let ex: Float = (sx - 300) / 170, ey: Float = (sy - 400) / 220
                    let d: Float = ex * ex + ey * ey
                    XCTAssertLessThanOrEqual(d, 1, "skin at \(sx), \(sy)")
                    if d > 1 { return }
                }
                if face.teeth[i] > 0 {
                    XCTAssertTrue((246...354).contains(sx) && (484...516).contains(sy), "teeth at \(sx), \(sy)")
                    if !((246...354).contains(sx) && (484...516).contains(sy)) { return }
                }
                if face.eyes[i] > 0 {
                    let inEye = (322...358).contains(sy) && ((206...274).contains(sx) || (326...394).contains(sx))
                    XCTAssertTrue(inEye, "eyes at \(sx), \(sy)")
                    if !inEye { return }
                }
            }
        }
    }

    /// A face too thin to draw (no contour) builds nothing, and a mask
    /// set with such a face composites to nothing.
    func testTooFewLandmarksBuildNothing() {
        let render = TouchUpAnalysis.Render(image: Self.drawnFace(), span: 2, rotation: .none)
        var landmarks = Self.drawnLandmarks()
        landmarks.faceContour = []
        XCTAssertNil(FaceMaskBuilder.build(landmarks, id: UUID(), render: render, setWidth: 600, setHeight: 800))
    }

    /// The masks at a coarser analysis render land on the same half-res
    /// pixels: the drawn face at span 4 (the render is half the size, the
    /// set the same) gives the same skin within a few pixels' feather.
    func testCoarserRenderGivesTheSameMasks() throws {
        let fine = TouchUpAnalysis.Render(image: Self.drawnFace(), span: 2, rotation: .none)
        let full = Self.drawnFace()
        let half = try XCTUnwrap(CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        half.interpolationQuality = .high
        half.draw(full, in: CGRect(x: 0, y: 0, width: 300, height: 400))
        let coarse = TouchUpAnalysis.Render(image: try XCTUnwrap(half.makeImage()), span: 4, rotation: .none)
        let landmarks = Self.drawnLandmarks()
        let a = try XCTUnwrap(FaceMaskBuilder.build(landmarks, id: UUID(), render: fine, setWidth: 600, setHeight: 800))
        let b = try XCTUnwrap(FaceMaskBuilder.build(landmarks, id: UUID(), render: coarse, setWidth: 600, setHeight: 800))
        XCTAssertEqual(a.origin, b.origin)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        XCTAssertGreaterThan(Self.iou(a.skin, b.skin), 0.95)
        XCTAssertGreaterThan(Self.iou(a.teeth, b.teeth), 0.8)
    }

    /// Intersection over union of two planes at half.
    static func iou(_ a: [UInt8], _ b: [UInt8], threshold: UInt8 = 127) -> Double {
        var shared = 0, either = 0
        for (x, y) in zip(a, b) {
            let p = x > threshold, q = y > threshold
            if p && q { shared += 1 }
            if p || q { either += 1 }
        }
        return either > 0 ? Double(shared) / Double(either) : 1
    }

    // MARK: - The portrait

    struct Portrait {
        let gpu: GPUContext
        let session: ImageSession
        let pipeline: RenderPipeline
        let parameters: EditParameters
        let rotation: ImageRotation
    }

    func portrait() throws -> Portrait {
        let url = try PortraitFixture.dngURL()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        return Portrait(gpu: gpu, session: session, pipeline: RenderPipeline(gpu: gpu), parameters: parameters,
                        rotation: ExportPlan.rotation(for: session.file.summary, userRotation: 0))
    }

    func render(_ p: Portrait) throws -> TouchUpAnalysis.Render {
        try TouchUpAnalysis.render(session: p.session, pipeline: p.pipeline, gpu: p.gpu,
                                   parameters: p.parameters, rotation: p.rotation)
    }

    /// The analysis render is the whole sensor at the plan's bin factor.
    func testAnalysisRenderCoversTheSensor() throws {
        let p = try portrait()
        let summary = p.session.file.summary
        let render = try self.render(p)
        let quads = max(1, max(summary.rawWidth, summary.rawHeight) / 4000)
        XCTAssertEqual(render.span, 2 * quads)
        XCTAssertEqual(render.image.width, summary.rawWidth / render.span, accuracy: 1)
        XCTAssertEqual(render.image.height, summary.rawHeight / render.span, accuracy: 1)
        XCTAssertEqual(render.rotation, p.rotation)
        XCTAssertEqual(render.image.bitsPerPixel, 32)
    }

    /// Find Faces on the portrait: one face with a skin mask centred in
    /// its box, teeth (she smiles), a thumbnail, and the version stamp.
    func testFindGivesOneFaceWithSkinAndTeeth() throws {
        let p = try portrait()
        let render = try self.render(p)
        let started = Date()
        let found = TouchUpRegions.find(in: render, session: p.session, pipeline: p.pipeline, parameters: p.parameters)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(found.faces.count, 1)
        XCTAssertEqual(found.tooSmall, 0)
        XCTAssertEqual(found.masks.faces.count, 1)
        XCTAssertEqual(found.masks.modelVersion, FaceLandmarker.modelVersion)
        let face = try XCTUnwrap(found.faces.first)
        let box = face.boundingBox
        XCTAssertTrue(face.enabled)
        XCTAssertTrue(box.x >= 0 && box.y >= 0 && box.x + box.z <= 1 && box.y + box.w <= 1, "\(box)")
        XCTAssertGreaterThan(box.z, 0.2, "a portrait's face fills a good part of the frame")

        let mask = try XCTUnwrap(found.masks.faces.first)
        XCTAssertEqual(mask.id, face.id)
        var sum = SIMD2<Double>(0, 0), count = 0.0
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.skin[y * mask.width + x] > 127 {
                sum += SIMD2(Double(x + mask.origin.x), Double(y + mask.origin.y))
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 10_000, "skin pixels")
        let centroid = sum / count
        // The box is on the raw grid; without a lens profile the output
        // grid is the same, and the set is at half resolution.
        let set = SIMD2(Double(found.masks.width), Double(found.masks.height))
        XCTAssertGreaterThan(centroid.x, Double(box.x) * set.x)
        XCTAssertLessThan(centroid.x, Double(box.x + box.z) * set.x)
        XCTAssertGreaterThan(centroid.y, Double(box.y) * set.y)
        XCTAssertLessThan(centroid.y, Double(box.y + box.w) * set.y)
        XCTAssertGreaterThan(mask.teeth.filter { $0 > 127 }.count, 16, "teeth")
        XCTAssertGreaterThan(mask.eyes.filter { $0 > 127 }.count, 16, "eyes")

        let thumbnail = try XCTUnwrap(found.thumbnails[face.id]).cgImage
        XCTAssertEqual(thumbnail.width, 80)
        XCTAssertEqual(thumbnail.height, 80)
        print("Find Faces on the portrait: \(Int(elapsed * 1000)) ms for \(found.faces.count) face, "
              + "crop \(mask.width) x \(mask.height)")
    }

    /// Regeneration from the stored boxes gives the masks Find Faces
    /// built, and nothing is missing.
    func testBuildFromStoredBoxesReproducesFind() throws {
        let p = try portrait()
        let render = try self.render(p)
        let found = TouchUpRegions.find(in: render, session: p.session, pipeline: p.pipeline, parameters: p.parameters)
        var touchUp = TouchUp()
        touchUp.faces = found.faces
        let started = Date()
        let (masks, missing) = TouchUpRegions.build(touchUp, from: render, session: p.session, pipeline: p.pipeline,
                                                    parameters: p.parameters)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(masks.faces.count, 1)
        let enabled = touchUp.enabledFaceIDs
        let a = found.masks.composite(enabled: enabled), b = masks.composite(enabled: enabled)
        XCTAssertGreaterThanOrEqual(Self.iou(a.skin, b.skin), 0.9)
        XCTAssertGreaterThanOrEqual(Self.iou(a.teeth, b.teeth), 0.9)
        XCTAssertGreaterThanOrEqual(Self.iou(a.eyes, b.eyes, threshold: 0), 0.9)
        print("Regeneration on the portrait: \(Int(elapsed * 1000)) ms for 1 face")
    }

    /// A box Vision cannot refit (empty sky) keeps its face with an empty
    /// mask and is reported.
    func testABoxWithNoFaceIsReportedMissing() throws {
        let p = try portrait()
        let render = try self.render(p)
        var touchUp = TouchUp()
        let ghost = TouchUpFace(boundingBox: SIMD4(0.02, 0.02, 0.1, 0.06))
        touchUp.faces = [ghost]
        let (masks, missing) = TouchUpRegions.build(touchUp, from: render, session: p.session, pipeline: p.pipeline,
                                                    parameters: p.parameters)
        XCTAssertEqual(missing, [ghost.id])
        XCTAssertEqual(masks.faces.count, 1)
        XCTAssertEqual(masks.faces.first?.width, 0)
        let planes = masks.composite(enabled: [ghost.id])
        XCTAssertFalse(planes.skin.contains { $0 > 0 })
    }

    /// The export entry: nothing happens for a module that wants no
    /// masks; with a face and a slider the session gets the set.
    func testRegenerateSetsTheSessionMasksWhenWanted() throws {
        let p = try portrait()
        let render = try self.render(p)
        let found = TouchUpRegions.find(in: render, session: p.session, pipeline: p.pipeline, parameters: p.parameters)
        var touchUp = TouchUp()
        touchUp.faces = found.faces
        XCTAssertEqual(try TouchUpRegions.regenerate(touchUp, session: p.session, pipeline: p.pipeline, gpu: p.gpu,
                                                     parameters: p.parameters, rotation: p.rotation), [])
        XCTAssertNil(p.session.touchUpMasks, "no slider, no masks")
        touchUp.skinSmoothing = 40
        XCTAssertEqual(try TouchUpRegions.regenerate(touchUp, session: p.session, pipeline: p.pipeline, gpu: p.gpu,
                                                     parameters: p.parameters, rotation: p.rotation), [])
        let masks = try XCTUnwrap(p.session.touchUpMasks)
        XCTAssertEqual(masks.faces.map(\.id), found.faces.map(\.id))
        XCTAssertGreaterThan(masks.composite(enabled: touchUp.enabledFaceIDs).skin.filter { $0 > 127 }.count, 10_000)
    }
}
