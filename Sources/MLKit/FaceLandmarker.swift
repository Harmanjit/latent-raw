import Foundation
import CoreGraphics
import Vision
import PixelEngine

/// One face Vision found, in normalised coordinates of the render's grid
/// (top-left origin), so the touch-up and red-eye code never sees Vision's
/// bottom-left frame or the upright image's turn.
public struct FaceObservation: Sendable, Equatable {
    /// Normalised coordinates of the render's grid, top-left origin: x, y, w, h.
    public var boundingBox: CGRect
    public var roll: Float
    public var yaw: Float
    public var confidence: Float
    public var faceContour, leftEye, rightEye, leftPupil, rightPupil,
               leftEyebrow, rightEyebrow, nose, outerLips, innerLips: [SIMD2<Float>]

    public init(boundingBox: CGRect, roll: Float = 0, yaw: Float = 0, confidence: Float = 0,
                faceContour: [SIMD2<Float>] = [], leftEye: [SIMD2<Float>] = [], rightEye: [SIMD2<Float>] = [],
                leftPupil: [SIMD2<Float>] = [], rightPupil: [SIMD2<Float>] = [],
                leftEyebrow: [SIMD2<Float>] = [], rightEyebrow: [SIMD2<Float>] = [], nose: [SIMD2<Float>] = [],
                outerLips: [SIMD2<Float>] = [], innerLips: [SIMD2<Float>] = []) {
        self.boundingBox = boundingBox
        self.roll = roll
        self.yaw = yaw
        self.confidence = confidence
        self.faceContour = faceContour
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
        self.leftEyebrow = leftEyebrow
        self.rightEyebrow = rightEyebrow
        self.nose = nose
        self.outerLips = outerLips
        self.innerLips = innerLips
    }
}

/// A face as the Vision pass reports it before the turn back to the
/// sensor: pixels of the upright image, top-left origin. What
/// `RedEyeDetector` reads once it becomes a consumer (Wave 1, W1-E).
struct UprightFace: Equatable {
    var boundingBox: CGRect
    var roll: Float
    var yaw: Float
    var confidence: Float
    var faceContour, leftEye, rightEye, leftPupil, rightPupil,
        leftEyebrow, rightEyebrow, nose, outerLips, innerLips: [CGPoint]
}

/// One Vision face-landmark pass shared by touch-up and red-eye
/// (docs/Retouch.md §2 B). Wave 1 (W1-E) fills the bodies in; until then
/// no face is ever found, which every caller treats as "no faces".
public enum FaceLandmarker {
    public static let modelVersion = "vision.faceLandmarks.3"

    /// VNDetectFaceLandmarksRequest revision 3, 76 points, on
    /// `sensorImage` (an sRGB render of the whole sensor, unrotated) made
    /// upright by `rotation`; results sorted left to right in the upright
    /// image.
    public static func detect(in sensorImage: CGImage, rotation: ImageRotation) -> [FaceObservation] {
        []
    }

    /// Refits landmarks inside `seeds` (sensor-normalised, top-left
    /// origin), each enlarged by `seedMargin` and converted to Vision's
    /// upright bottom-left frame here (inputFaceObservations); nil per
    /// seed Vision could not refit, never a silent drop.
    public static func refit(in sensorImage: CGImage, rotation: ImageRotation, seeds: [CGRect],
                             seedMargin: CGFloat = 0.2) -> [FaceObservation?] {
        seeds.map { _ in nil }
    }

    /// The Vision pass on an upright image, in upright pixels (top-left
    /// origin); RedEyeDetector's input.
    static func upright(in image: CGImage, seeds: [CGRect]?) -> [UprightFace] {
        []
    }
}
