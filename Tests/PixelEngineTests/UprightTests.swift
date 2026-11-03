import XCTest
import simd
@testable import PixelEngine

/// Upright and the Transform sliders: the line detector, the solver for
/// each mode, the composed matrix, flips, Constrain Crop and how the new
/// fields are stored.
final class UprightTests: XCTestCase {
    /// A unit-ish picture: 3:2, in PerspectiveSpace (half the short side is 1).
    let corners: [SIMD2<Float>] = [SIMD2(-1.5, -1), SIMD2(1.5, -1), SIMD2(1.5, 1), SIMD2(-1.5, 1)]

    // MARK: - Line detection

    /// Draws anti-aliased dark lines on a light ground and checks they are
    /// found, at the right angle, and that nothing else is.
    func testDetectorFindsDrawnLinesAtTheirAngle() {
        let width = 480, height = 320
        var image = [Float](repeating: 0.8, count: width * height)
        let lines: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(40, 60), SIMD2(440, 74)),      // nearly level, about 2°
            (SIMD2(100, 30), SIMD2(108, 290)),    // nearly plumb
            (SIMD2(300, 40), SIMD2(330, 280)),    // leaning, about 7° off plumb
        ]
        for (a, b) in lines { draw(&image, width: width, height: height, from: a, to: b, halfWidth: 1.5) }
        let found = LineDetector.segments(luminance: image, width: width, height: height)
        for (a, b) in lines {
            let expected = LineSegment(a, b).angle
            // Each edge of a drawn line is a segment of its own (dark to
            // light, light to dark), both at the line's angle.
            let matches = found.filter { abs($0.angle - expected) < 0.5 && $0.length > LineSegment(a, b).length * 0.8 }
            XCTAssertFalse(matches.isEmpty, "line at \(expected)° found; got \(found.map(\.angle))")
        }
        XCTAssertLessThanOrEqual(found.count, 8, "no stray segments in a clean picture")
    }

    func testDetectorFindsNothingInAFlatOrNoisyPicture() {
        let width = 200, height = 150
        XCTAssertTrue(LineDetector.segments(luminance: [Float](repeating: 0.5, count: width * height),
                                            width: width, height: height).isEmpty)
        var generator = SeededGenerator(seed: 7)
        let noise = (0..<(width * height)).map { _ in 0.5 + Float.random(in: -0.01...0.01, using: &generator) }
        XCTAssertTrue(LineDetector.segments(luminance: noise, width: width, height: height).isEmpty)
    }

    // MARK: - Solving

    func testLevelTurnsTiltedHorizontalsLevel() throws {
        let tilt: Float = 2.5
        let lines = (0..<5).map { i -> LineSegment in
            let y = Float(i) * 0.3 - 0.6
            return rotated(LineSegment(SIMD2(-1, y), SIMD2(1, y)), degrees: tilt)
        }
        let forward = try XCTUnwrap(UprightSolver.solve(.level, lines: lines, corners: corners))
        for line in lines {
            XCTAssertEqual(line.transformed(by: forward).angle, 0, accuracy: 0.05)
        }
        XCTAssertEqual(UprightSolver.autoStraightenAngle(lines) ?? 99, -tilt, accuracy: 0.05)
    }

    func testVerticalMakesConvergingVerticalsParallelAndPlumb() throws {
        let lines = convergingVerticals(vanishingAt: SIMD2(0.1, -6))
        let forward = try XCTUnwrap(UprightSolver.solve(.vertical, lines: lines, corners: corners))
        for line in lines {
            XCTAssertEqual(abs(line.transformed(by: forward).angle), 90, accuracy: 0.1)
        }
        // The centre stays put and the picture keeps about its size.
        XCTAssertEqual(simd_length(forward.applied(to: .zero)), 0, accuracy: 1e-4)
        let area = UprightSolver.area(corners.map { forward.applied(to: $0) })
        XCTAssertEqual(area / UprightSolver.area(corners), 1, accuracy: 0.01)
    }

    func testAutoEasesAStrongConvergence() throws {
        let lines = convergingVerticals(vanishingAt: SIMD2(0, -2.2))
        let full = try XCTUnwrap(UprightSolver.solve(.vertical, lines: lines, corners: corners))
        let auto = try XCTUnwrap(UprightSolver.solve(.auto, lines: lines, corners: corners))
        let spread = { (m: simd_float3x3) -> Float in
            let angles = lines.map { abs($0.transformed(by: m).angle) }
            return angles.max()! - angles.min()!
        }
        XCTAssertLessThan(spread(full), 0.2, "Vertical straightens them")
        XCTAssertGreaterThan(spread(auto), spread(full), "Auto holds back")
        XCTAssertLessThan(spread(auto), lines.map { abs($0.angle) }.max()! - lines.map { abs($0.angle) }.min()!,
                          "but still corrects some")
    }

    func testFullStraightensBothFamilies() throws {
        let verticals = convergingVerticals(vanishingAt: SIMD2(-0.3, -7))
        let horizontals = [-0.7, -0.2, 0.4, 0.8].map { y -> LineSegment in
            // Converging on a point far to the right.
            let vp = SIMD2<Float>(9, 0.2)
            let a = SIMD2<Float>(-1.2, Float(y))
            return LineSegment(a, a + (vp - a) * 0.2)
        }
        let forward = try XCTUnwrap(UprightSolver.solve(.full, lines: verticals + horizontals, corners: corners))
        for line in verticals { XCTAssertEqual(abs(line.transformed(by: forward).angle), 90, accuracy: 0.15) }
        for line in horizontals { XCTAssertEqual(line.transformed(by: forward).angle, 0, accuracy: 0.15) }
    }

    func testGuidedFromTwoVerticalsAndOneHorizontal() throws {
        let guides = [LineSegment(SIMD2(-0.8, 0.8), SIMD2(-0.7, -0.8)),
                      LineSegment(SIMD2(0.8, 0.8), SIMD2(0.68, -0.8)),
                      LineSegment(SIMD2(-0.6, 0.3), SIMD2(0.6, 0.36))]
        let forward = try XCTUnwrap(UprightSolver.solveGuided(guides, corners: corners))
        XCTAssertEqual(abs(guides[0].transformed(by: forward).angle), 90, accuracy: 0.05)
        XCTAssertEqual(abs(guides[1].transformed(by: forward).angle), 90, accuracy: 0.05)
        XCTAssertEqual(guides[2].transformed(by: forward).angle, 0, accuracy: 0.05)
    }

    func testGuidedFromOneLineOnlyLevels() throws {
        let guide = LineSegment(SIMD2(-0.6, 0.1), SIMD2(0.6, 0.0))
        let forward = try XCTUnwrap(UprightSolver.solveGuided([guide], corners: corners))
        XCTAssertEqual(guide.transformed(by: forward).angle, 0, accuracy: 0.01)
        XCTAssertEqual(forward.determinant, 1, accuracy: 1e-3, "a rotation only")
    }

    func testNothingToGoOnGivesNoCorrection() {
        XCTAssertNil(UprightSolver.solve(.vertical, lines: [], corners: corners))
        XCTAssertNil(UprightSolver.solve(.level, lines: [LineSegment(SIMD2(0, 0), SIMD2(0.3, 0.3))], corners: corners))
        XCTAssertNil(UprightSolver.autoStraightenAngle([]))
    }

    /// A drawn line asks for whichever of level or plumb is nearer.
    func testStraightenAngleForADrawnLine() {
        XCTAssertEqual(UprightSolver.straightenAngle(for: LineSegment(SIMD2(0, 0), SIMD2(100, 5))),
                       -atan2(5, 100) * 180 / .pi, accuracy: 1e-4)
        XCTAssertEqual(UprightSolver.straightenAngle(for: LineSegment(SIMD2(0, 0), SIMD2(4, 100))),
                       90 - atan2(100, 4) * 180 / .pi, accuracy: 1e-4)
    }

    /// End to end on pixels: a synthetic building whose verticals lean in
    /// is found and corrected by the detector and solver together.
    func testDetectorAndSolverTogether() throws {
        let width = 600, height = 400
        var image = [Float](repeating: 0.85, count: width * height)
        // Verticals meeting far above the frame, as a camera tilted up sees them.
        let vp = SIMD2<Float>(300, -1400)
        for x in stride(from: 80, through: 520, by: 88) {
            let bottom = SIMD2<Float>(Float(x), 380)
            let top = bottom + (vp - bottom) * (340 / 1780)
            draw(&image, width: width, height: height, from: bottom, to: top, halfWidth: 2)
        }
        let found = LineDetector.segments(luminance: image, width: width, height: height)
        let space = PerspectiveSpace(sensorSize: CGSize(width: width, height: height))
        let lines = found.map { LineSegment(space.normalized(CGPoint(x: CGFloat($0.a.x), y: CGFloat($0.a.y))),
                                            space.normalized(CGPoint(x: CGFloat($0.b.x), y: CGFloat($0.b.y)))) }
        let forward = try XCTUnwrap(UprightSolver.solve(.vertical, lines: lines, corners: space.corners))
        for line in lines where abs(line.angle) > 60 {
            XCTAssertEqual(abs(line.transformed(by: forward).angle), 90, accuracy: 0.3)
        }
    }

    // MARK: - The composed matrix

    /// With every new field at its default the matrix is the keystone-only
    /// one, exactly, so old edits render as they did.
    func testDefaultsLeaveTheKeystoneMatrixUntouched() {
        let keystone = PerspectiveCorrection(vertical: 0.3, horizontal: -0.2)
        let h: Float = 0.2 * 0.5, v: Float = -0.3 * 0.5
        let expected = simd_float3x3(columns: (SIMD3(1, 0, h), SIMD3(0, 1, v), SIMD3(0, 0, 1)))
        XCTAssertEqual(keystone.inverseMatrix, expected)
        var withTool = keystone
        withTool.constrainCrop = true
        withTool.upright = UprightCorrection(mode: .guided)
        XCTAssertEqual(withTool.inverseMatrix, expected, "a mode without a result, and a tool setting, change nothing")
        XCTAssertFalse(withTool.isNeutral)
        XCTAssertTrue(PerspectiveCorrection.none.isIdentity)
    }

    func testTransformSlidersMoveThePictureAsDescribed() {
        var t = PerspectiveCorrection()
        t.offsetX = 0.2
        XCTAssertEqual(t.outputPoint(forSource: .zero), SIMD2(0.2, 0), "X Offset moves the picture right")
        t = PerspectiveCorrection()
        t.scale = 1.25
        XCTAssertEqual(t.outputPoint(forSource: SIMD2(0.4, 0)).x, 0.5, accuracy: 1e-6)
        t = PerspectiveCorrection()
        t.rotate = 90
        let p = t.outputPoint(forSource: SIMD2(1, 0))
        XCTAssertEqual(p.x, 0, accuracy: 1e-6)
        XCTAssertEqual(p.y, 1, accuracy: 1e-6, "positive Rotate turns clockwise on screen (y down)")
        t = PerspectiveCorrection()
        t.aspect = 1
        let q = t.outputPoint(forSource: SIMD2(1, 1))
        XCTAssertGreaterThan(q.x, 1)
        XCTAssertLessThan(q.y, 1)
        XCTAssertEqual(q.x * q.y, 1, accuracy: 1e-5, "Aspect keeps the area")
    }

    /// Flipping shows exactly the mirror image of what was there, whatever
    /// the other sliders and Upright are doing.
    func testFlipIsAnExactMirrorOfTheCurrentPicture() {
        var t = PerspectiveCorrection(vertical: 0.25, horizontal: -0.3)
        t.rotate = 3; t.aspect = 0.2; t.scale = 1.1; t.offsetX = 0.1; t.offsetY = -0.05
        t.upright = UprightCorrection(mode: .vertical, matrix: UprightCorrection.encoded(
            simd_float3x3(rows: [SIMD3(1, 0.02, 0), SIMD3(0, 1, 0), SIMD3(0.05, -0.1, 1)])))
        for horizontal in [true, false] {
            var flipped = t
            flipped.flip(horizontal: horizontal)
            for p in [SIMD2<Float>(0.3, 0.2), SIMD2(-0.9, 0.6), SIMD2(1.2, -0.7)] {
                let mirror = horizontal ? SIMD2(-p.x, p.y) : SIMD2(p.x, -p.y)
                let a = t.sourcePoint(forOutput: p), b = flipped.sourcePoint(forOutput: mirror)
                XCTAssertEqual(a.x, b.x, accuracy: 1e-5)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-5)
            }
            var back = flipped
            back.flip(horizontal: horizontal)
            XCTAssertEqual(back, t, "flipping twice is no flip")
        }
    }

    func testResetTransformKeepsConstrainCrop() {
        var t = PerspectiveCorrection(vertical: 0.4)
        t.scale = 1.3; t.flipVertical = true; t.constrainCrop = true
        t.upright = UprightCorrection(mode: .level)
        t.resetTransform()
        XCTAssertTrue(t.isIdentity)
        XCTAssertNil(t.upright)
        XCTAssertTrue(t.constrainCrop)
    }

    // MARK: - Crop

    func testMirroredCropAndMasks() {
        let crop = CropParameters(centre: [0.3, 0.6], size: [0.5, 0.4], angle: 5, aspect: 1.5)
        let h = crop.mirrored(horizontal: true)
        XCTAssertEqual(h.centre, [0.7, 0.6])
        XCTAssertEqual(h.angle, -5)
        XCTAssertEqual(h.size, crop.size)
        XCTAssertEqual(h.mirrored(horizontal: true), crop)
        XCTAssertEqual(MaskShape.linear(start: [0.2, 0.3], end: [0.4, 0.9]).mirrored(horizontal: false),
                       .linear(start: [0.2, 1 - Float(0.3)], end: [0.4, 1 - Float(0.9)]))
    }

    /// Constrain Crop finds the largest crop of the shape whose every edge
    /// shows the picture, and no larger.
    func testFittedCropStaysOnThePicture() {
        let sensor = CGSize(width: 3000, height: 2000)
        var t = PerspectiveCorrection(vertical: 0.5)
        t.rotate = 4
        let space = PerspectiveSpace(sensorSize: sensor)
        let onPicture = { (p: CGPoint) -> Bool in
            let s = space.sensorPoint(t.sourcePoint(forOutput: space.normalized(p)))
            return s.x >= 0 && s.y >= 0 && s.x <= sensor.width && s.y <= sensor.height
        }
        let fitted = CropParameters(aspect: 1.5).fitted(sensorSize: sensor, onPicture: onPicture)
        XCTAssertEqual(fitted.ratio(sensorSize: sensor), 1.5, accuracy: 0.01)
        XCTAssertLessThan(fitted.size.x, 1)
        XCTAssertGreaterThan(fitted.size.x, 0.4)
        func onPictureAllRound(_ crop: CropParameters) -> Bool {
            let frame = CropFrame(sensorSize: sensor, crop: crop)
            let canvas = frame.canvasSize
            // Around the edge, a pixel in.
            let w = canvas.width - 2, h = canvas.height - 2
            let edge = (0...20).flatMap { i -> [CGPoint] in
                let t = CGFloat(i) / 20
                return [CGPoint(x: 1 + t * w, y: 1), CGPoint(x: 1 + t * w, y: 1 + h),
                        CGPoint(x: 1, y: 1 + t * h), CGPoint(x: 1 + w, y: 1 + t * h)]
            }
            return edge.allSatisfy { onPicture(frame.sensorPoint(fromCanvasPoint: $0)) }
        }
        XCTAssertTrue(onPictureAllRound(fitted))
        var larger = fitted
        larger.size *= 1.03
        XCTAssertFalse(onPictureAllRound(larger), "a little larger would not be")
    }

    // MARK: - Stored form

    /// An old stack's perspective block (keystone only) reads and writes
    /// back exactly as before: no new keys appear.
    func testKeystoneOnlyStackEncodesAsBefore() throws {
        var p = EditParameters()
        p.perspective = PerspectiveCorrection(vertical: 0.3, horizontal: -0.2)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"perspective\":{\"horizontal\":-0.2,\"vertical\":0.3}"), json)
        let old = """
        {"modules":{"perspective":{"horizontal":-0.2,"vertical":0.3}},"process":"1.0","schema":1}
        """
        let decoded = try EditStack.decode(json: old).parameters()
        XCTAssertEqual(decoded.perspective, PerspectiveCorrection(vertical: 0.3, horizontal: -0.2))
    }

    /// Every new field survives a save and a reload.
    func testTransformRoundTrips() throws {
        var p = EditParameters()
        var t = PerspectiveCorrection(vertical: 0.1, horizontal: 0.05)
        t.rotate = -2.5; t.aspect = 0.3; t.scale = 0.9; t.offsetX = 0.12; t.offsetY = -0.2
        t.flipHorizontal = true; t.flipVertical = true; t.constrainCrop = true
        t.upright = UprightCorrection(mode: .guided,
                                      matrix: UprightCorrection.encoded(UprightSolver.rotation(degrees: 1.5).inverse),
                                      guides: [UprightGuide(x0: -0.5, y0: 0.6, x1: -0.45, y1: -0.6),
                                               UprightGuide(x0: 0.5, y0: 0.6, x1: 0.44, y1: -0.6)])
        p.perspective = t
        let json = try EditStack(parameters: p).encodeJSON()
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.perspective, t)
        XCTAssertEqual(back.perspective.inverseMatrix, t.inverseMatrix)
        XCTAssertEqual(try EditStack(parameters: back).encodeJSON(), json)
    }

    /// A Constrain Crop preference alone is stored; nothing at all is not.
    func testNeutralTransformIsNotStored() throws {
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.perspective)
        var p = EditParameters()
        p.perspective.constrainCrop = true
        XCTAssertEqual(try EditStack.decode(json: EditStack(parameters: p).encodeJSON()).parameters().perspective, p.perspective)
    }

    /// A hand-edited file can't ask for a broken matrix or wild sliders.
    func testHandEditedValuesAreSanitised() throws {
        let json = """
        {"modules":{"perspective":{"horizontal":0,"vertical":0,"scale":40,"rotate":-300,
        "upright":{"mode":"full","matrix":[1,0,0,0,0,0,0,0,0],"guides":[{"x0":1e9,"y0":0,"x1":0,"y1":0}]}}},
        "process":"1.0","schema":1}
        """
        let t = try EditStack.decode(json: json).parameters().perspective
        XCTAssertEqual(t.scale, TransformRanges.scale.upperBound)
        XCTAssertEqual(t.rotate, TransformRanges.rotate.lowerBound)
        XCTAssertNil(t.upright?.matrix, "a singular matrix is dropped")
        XCTAssertNil(t.upright?.guides)
        XCTAssertEqual(t.upright?.mode, .full)
    }

    // MARK: - Helpers

    private func convergingVerticals(vanishingAt vp: SIMD2<Float>) -> [LineSegment] {
        [-1.2, -0.6, 0.0, 0.5, 1.1].map { x -> LineSegment in
            let bottom = SIMD2<Float>(Float(x), 0.9)
            return LineSegment(bottom, bottom + (vp - bottom) * (1.6 / simd_distance(vp, bottom)))
        }
    }

    private func rotated(_ s: LineSegment, degrees: Float) -> LineSegment {
        s.transformed(by: UprightSolver.rotation(degrees: degrees))
    }

    /// An anti-aliased dark line: coverage from the distance to the segment.
    private func draw(_ image: inout [Float], width: Int, height: Int,
                      from a: SIMD2<Float>, to b: SIMD2<Float>, halfWidth: Float) {
        let d = b - a, length = simd_length(d), u = d / length
        for y in 0..<height {
            for x in 0..<width {
                let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - a
                let along = simd_dot(p, u)
                guard along >= 0, along <= length else { continue }
                let across = abs(p.x * u.y - p.y * u.x)
                let coverage = min(1, max(0, halfWidth + 0.5 - across))
                image[y * width + x] = image[y * width + x] * (1 - coverage) + 0.1 * coverage
            }
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
        return z ^ (z >> 33)
    }
}
