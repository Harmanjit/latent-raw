import XCTest
import CoreGraphics
import simd
import PixelEngine
@testable import MLKit

/// The shared landmark pass: the maths between Vision's upright
/// bottom-left frame and the sensor (always), and the pass itself on the
/// portrait asset (skipped when it hasn't been fetched).
final class FaceLandmarkerTests: XCTestCase {
    // MARK: - Synthetic landmarks

    /// A Vision rectangle to upright pixels and back.
    func testUprightRectRoundTrips() {
        let size = CGSize(width: 400, height: 200)
        let vision = CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.3)
        let upright = FaceLandmarker.uprightRect(vision, in: size)
        // Vision's y is from the bottom: the box's top is 0.8 up, so 0.2
        // of the height down from the top.
        XCTAssertEqual(upright.minX, 100, accuracy: 1e-9)
        XCTAssertEqual(upright.minY, 40, accuracy: 1e-9)
        XCTAssertEqual(upright.width, 80, accuracy: 1e-9)
        XCTAssertEqual(upright.height, 60, accuracy: 1e-9)
        let back = FaceLandmarker.visionRect(upright, in: size)
        XCTAssertEqual(back.minX, vision.minX, accuracy: 1e-9)
        XCTAssertEqual(back.minY, vision.minY, accuracy: 1e-9)
        XCTAssertEqual(back.width, vision.width, accuracy: 1e-9)
        XCTAssertEqual(back.height, vision.height, accuracy: 1e-9)
    }

    /// An upright face's points and box land on the sensor where
    /// `ImageRotation` puts them, normalised, under each turn.
    func testSensorMappingUnderEachRotation() {
        let sensorSize = CGSize(width: 40, height: 20)
        for rotation in ImageRotation.allCases {
            let point = CGPoint(x: 5.5, y: 3.5)
            let box = CGRect(x: 4, y: 2, width: 5, height: 3)
            let face = UprightFace(boundingBox: box, roll: 0.1, yaw: 0.2, confidence: 0.9,
                                   faceContour: [point], leftEye: [], rightEye: [], leftPupil: [point], rightPupil: [],
                                   leftEyebrow: [], rightEyebrow: [], nose: [], outerLips: [], innerLips: [])
            let observation = FaceLandmarker.sensorObservation(face, rotation: rotation, sensorSize: sensorSize)
            let sensor = rotation.sensorPoint(fromImagePoint: point, sensorSize: sensorSize)
            let expected = SIMD2(Float(sensor.x / sensorSize.width), Float(sensor.y / sensorSize.height))
            XCTAssertEqual(observation.leftPupil, [expected], "\(rotation)")
            XCTAssertEqual(observation.faceContour, [expected], "\(rotation)")
            XCTAssertTrue(observation.leftEye.isEmpty)
            let sensorBox = rotation.sensorRect(fromImageRect: box, sensorSize: sensorSize)
            XCTAssertEqual(observation.boundingBox.minX, sensorBox.minX / 40, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(observation.boundingBox.minY, sensorBox.minY / 20, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(observation.boundingBox.width, sensorBox.width / 40, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(observation.boundingBox.height, sensorBox.height / 20, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(observation.roll, 0.1)
            XCTAssertEqual(observation.yaw, 0.2)
            XCTAssertEqual(observation.confidence, 0.9)
            // The turn swaps the axes for a quarter turn, so a box that is
            // wider than tall upright is taller than wide on the sensor.
            XCTAssertEqual(observation.boundingBox.width * 40 > observation.boundingBox.height * 20,
                           !rotation.swapsAxes, "\(rotation)")
        }
    }

    /// The same maths RedEyeDetector's spots use, so the two agree on
    /// where an eye is.
    func testAgreesWithRedEyeSpot() {
        let sensorSize = CGSize(width: 400, height: 200)
        for rotation in ImageRotation.allCases {
            let centre = CGPoint(x: 30.5, y: 70.5)
            let face = UprightFace(boundingBox: .zero, roll: 0, yaw: 0, confidence: 1,
                                   faceContour: [], leftEye: [], rightEye: [], leftPupil: [centre], rightPupil: [],
                                   leftEyebrow: [], rightEyebrow: [], nose: [], outerLips: [], innerLips: [])
            let observation = FaceLandmarker.sensorObservation(face, rotation: rotation, sensorSize: sensorSize)
            let spot = RedEyeDetector.spot(for: .init(centre: centre, radius: 4), rotation: rotation,
                                           sensorImageSize: sensorSize)
            XCTAssertEqual(observation.leftPupil[0].x, spot.centre.x, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(observation.leftPupil[0].y, spot.centre.y, accuracy: 1e-6, "\(rotation)")
        }
    }

    /// A sensor-normalised seed grows by the margin about its centre and
    /// turns into upright pixels.
    func testSeedsAreEnlargedAndTurnedUpright() {
        let sensorSize = CGSize(width: 400, height: 200)
        let seed = CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.2)   // sensor (100, 100, 80, 40)
        let none = FaceLandmarker.uprightSeed(seed, margin: 0.2, rotation: .none, sensorSize: sensorSize,
                                              uprightSize: sensorSize)
        XCTAssertEqual(none, CGRect(x: 92, y: 96, width: 96, height: 48))
        // Turned a quarter clockwise the image is 200 x 400 and the box's
        // sensor corners (100, 100) and (180, 140) land at (100, 100) and
        // (60, 180): a 40 x 80 box at (60, 100), grown a fifth.
        let cw90 = FaceLandmarker.uprightSeed(seed, margin: 0.2, rotation: .cw90, sensorSize: sensorSize,
                                              uprightSize: CGSize(width: 200, height: 400))
        XCTAssertEqual(cw90, CGRect(x: 56, y: 92, width: 48, height: 96))
        let exact = FaceLandmarker.uprightSeed(seed, margin: 0, rotation: .cw90, sensorSize: sensorSize,
                                               uprightSize: CGSize(width: 200, height: 400))
        XCTAssertEqual(exact, CGRect(x: 60, y: 100, width: 40, height: 80))
        // Vision's frame of that: from the bottom of the 400 px image.
        let vision = FaceLandmarker.visionRect(exact, in: CGSize(width: 200, height: 400))
        XCTAssertEqual(vision.minX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(vision.minY, 1 - 180.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(vision.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(vision.height, 0.2, accuracy: 1e-9)
    }

    /// A seed at the frame's edge grows only inwards: Vision refuses a
    /// box outside the image.
    func testSeedsStayInsideTheImage() {
        let sensorSize = CGSize(width: 400, height: 200)
        let seed = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let grown = FaceLandmarker.uprightSeed(seed, margin: 0.2, rotation: .none, sensorSize: sensorSize,
                                               uprightSize: sensorSize)
        XCTAssertEqual(grown, CGRect(x: 0, y: 0, width: 220, height: 110))
    }

    /// No face in a synthetic scene: nothing found, and every seed comes
    /// back nil rather than dropped.
    func testNoFaceInASyntheticScene() {
        let image = RedEyeDetectorTests.eyes()
        XCTAssertTrue(FaceLandmarker.detect(in: image, rotation: .none).isEmpty)
        let seeds = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5), CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.5)]
        let refit = FaceLandmarker.refit(in: image, rotation: .cw90, seeds: seeds)
        XCTAssertEqual(refit.count, 2)
        XCTAssertTrue(refit.allSatisfy { $0 == nil })
        XCTAssertTrue(FaceLandmarker.refit(in: image, rotation: .none, seeds: []).isEmpty)
    }

    // MARK: - The portrait

    /// One face, both eyes and the inner lips, with a sensible box.
    func testPortraitHasOneFaceWithEyesAndLips() throws {
        let image = try PortraitFixture.image(longEdge: 1500)
        let faces = FaceLandmarker.detect(in: image, rotation: .none)
        XCTAssertEqual(faces.count, 1)
        let face = try XCTUnwrap(faces.first)
        XCTAssertGreaterThan(face.confidence, 0.5)
        XCTAssertGreaterThanOrEqual(face.leftEye.count, 3)
        XCTAssertGreaterThanOrEqual(face.rightEye.count, 3)
        XCTAssertEqual(face.leftPupil.count, 1)
        XCTAssertEqual(face.rightPupil.count, 1)
        XCTAssertGreaterThanOrEqual(face.innerLips.count, 3)
        XCTAssertGreaterThanOrEqual(face.outerLips.count, 3)
        XCTAssertGreaterThanOrEqual(face.faceContour.count, 5)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(face.boundingBox))
        // The eyes sit in the upper half of the box, one each side of its
        // middle, and the lips below them.
        let leftEye = Self.centre(face.leftEye), rightEye = Self.centre(face.rightEye)
        XCTAssertLessThan(min(leftEye.x, rightEye.x), Float(face.boundingBox.midX))
        XCTAssertGreaterThan(max(leftEye.x, rightEye.x), Float(face.boundingBox.midX))
        XCTAssertLessThan(leftEye.y, Float(face.boundingBox.midY))
        XCTAssertGreaterThan(Self.centre(face.innerLips).y, leftEye.y)
    }

    /// The sensor image turned each way, told the turn: the eyes land on
    /// the same upright spot within 0.005 of the frame.
    func testEyeCentresAgreeUnderEachRotation() throws {
        let upright = try PortraitFixture.image(longEdge: 1500)
        let uprightSize = CGSize(width: upright.width, height: upright.height)
        var reference: [SIMD2<Float>]?
        for rotation in ImageRotation.allCases {
            // The sensor image is the one that `rotation` turns upright.
            let inverse = ImageRotation(rawValue: (4 - rotation.rawValue) % 4)!
            let sensorImage = try XCTUnwrap(UprightImage.rotated(upright, by: inverse))
            let sensorSize = CGSize(width: sensorImage.width, height: sensorImage.height)
            let faces = FaceLandmarker.detect(in: sensorImage, rotation: rotation)
            XCTAssertEqual(faces.count, 1, "\(rotation)")
            guard let face = faces.first else { continue }
            let eyes = [face.leftEye, face.rightEye].map { points -> SIMD2<Float> in
                let sensor = Self.centre(points)
                let pixel = CGPoint(x: Double(sensor.x) * sensorSize.width, y: Double(sensor.y) * sensorSize.height)
                let image = rotation.imagePoint(fromSensorPoint: pixel, sensorSize: sensorSize)
                return SIMD2(Float(image.x / uprightSize.width), Float(image.y / uprightSize.height))
            }
            if let reference {
                for (eye, expected) in zip(eyes, reference) {
                    XCTAssertEqual(eye.x, expected.x, accuracy: 0.005, "\(rotation)")
                    XCTAssertEqual(eye.y, expected.y, accuracy: 0.005, "\(rotation)")
                }
            } else {
                reference = eyes
            }
        }
    }

    /// Refitting from the detected box gives the landmarks back within
    /// 0.01 of the frame: what regeneration relies on.
    func testRefitFromTheDetectedBoxReproducesTheLandmarks() throws {
        let image = try PortraitFixture.image(longEdge: 1500)
        let detected = try XCTUnwrap(FaceLandmarker.detect(in: image, rotation: .none).first)
        let refits = FaceLandmarker.refit(in: image, rotation: .none, seeds: [detected.boundingBox])
        XCTAssertEqual(refits.count, 1)
        let refit = try XCTUnwrap(refits.first ?? nil)
        for (name, a, b) in [("contour", detected.faceContour, refit.faceContour),
                             ("left eye", detected.leftEye, refit.leftEye),
                             ("right eye", detected.rightEye, refit.rightEye),
                             ("left pupil", detected.leftPupil, refit.leftPupil),
                             ("right pupil", detected.rightPupil, refit.rightPupil),
                             ("nose", detected.nose, refit.nose),
                             ("outer lips", detected.outerLips, refit.outerLips),
                             ("inner lips", detected.innerLips, refit.innerLips)] {
            XCTAssertEqual(a.count, b.count, name)
            let worst = zip(a, b).map { simd_length($0 - $1) }.max() ?? 0
            XCTAssertLessThan(worst, 0.01, name)
        }
    }

    /// The red-eye detector reads the same pass: on the portrait it finds
    /// two eyes (neither red).
    func testRedEyeDetectorSeesBothEyes() throws {
        let image = try PortraitFixture.image(longEdge: 1500)
        XCTAssertEqual(RedEyeDetector.eyeCandidates(in: image).count, 2)
        XCTAssertTrue(RedEyeDetector.detect(in: image, rotation: .none).isEmpty)
    }

    static func centre(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        points.reduce(SIMD2<Float>(0, 0), +) / Float(max(points.count, 1))
    }
}
