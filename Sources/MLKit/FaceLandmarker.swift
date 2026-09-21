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
/// `RedEyeDetector` reads.
struct UprightFace: Equatable {
    var boundingBox: CGRect
    var roll: Float
    var yaw: Float
    var confidence: Float
    var faceContour, leftEye, rightEye, leftPupil, rightPupil,
        leftEyebrow, rightEyebrow, nose, outerLips, innerLips: [CGPoint]
}

/// One Vision face-landmark pass shared by touch-up and red-eye
/// (docs/Retouch.md §2 B).
///
/// Vision wants faces the right way up and answers in a bottom-left
/// frame; the pipeline and the sidecar work on the unrotated sensor with
/// the origin at the top left. Everything here is about that seam: the
/// image is turned upright, the request runs, and the points come back
/// through `ImageRotation` to normalised sensor coordinates, so a face
/// found in a portrait shot lands where the render shows it whichever
/// way the camera was held.
public enum FaceLandmarker {
    public static let modelVersion = "vision.faceLandmarks.3"

    /// Vision fits landmarks into whatever box it is seeded with and
    /// reports how well they fit: the portrait's face refits at 0.91,
    /// a box of empty sky in the same image at 0.67 and a drawn pair of
    /// eyes at 0.72. Below this a refit is a face that is no longer
    /// there (cropped away, or the box came from another photo's edit).
    static let minimumRefitConfidence: Float = 0.8

    /// VNDetectFaceLandmarksRequest revision 3, 76 points, on
    /// `sensorImage` (an sRGB render of the whole sensor, unrotated) made
    /// upright by `rotation`; results sorted left to right in the upright
    /// image. Synchronous and tens of milliseconds: call it off the main
    /// thread.
    public static func detect(in sensorImage: CGImage, rotation: ImageRotation) -> [FaceObservation] {
        guard let image = UprightImage.rotated(sensorImage, by: rotation) else { return [] }
        let sensorSize = CGSize(width: sensorImage.width, height: sensorImage.height)
        return upright(in: image, seeds: nil).map { sensorObservation($0, rotation: rotation, sensorSize: sensorSize) }
    }

    /// Refits landmarks inside `seeds` (sensor-normalised, top-left
    /// origin), each enlarged by `seedMargin` and converted to Vision's
    /// upright bottom-left frame here (inputFaceObservations); nil per
    /// seed Vision could not refit, never a silent drop. The result is in
    /// seed order, so a caller can pair each stored face with its fit.
    public static func refit(in sensorImage: CGImage, rotation: ImageRotation, seeds: [CGRect],
                             seedMargin: CGFloat = 0.2) -> [FaceObservation?] {
        guard !seeds.isEmpty, let image = UprightImage.rotated(sensorImage, by: rotation) else {
            return seeds.map { _ in nil }
        }
        let sensorSize = CGSize(width: sensorImage.width, height: sensorImage.height)
        let uprightSize = CGSize(width: image.width, height: image.height)
        let uprightSeeds = seeds.map {
            uprightSeed($0, margin: seedMargin, rotation: rotation, sensorSize: sensorSize, uprightSize: uprightSize)
        }
        let faces = upright(in: image, seeds: uprightSeeds)
        // Vision answers one observation per input, but nothing promises
        // the order or that every input comes back with landmarks, so each
        // seed takes the face that overlaps it most, once.
        var taken = Set<Int>()
        return uprightSeeds.map { seed -> FaceObservation? in
            var best: (index: Int, overlap: CGFloat)?
            for (index, face) in faces.enumerated() where !taken.contains(index) {
                let overlap = intersectionOverUnion(seed, face.boundingBox)
                guard overlap > 0, overlap > (best?.overlap ?? 0) else { continue }
                best = (index, overlap)
            }
            guard let best else { return nil }
            taken.insert(best.index)
            return sensorObservation(faces[best.index], rotation: rotation, sensorSize: sensorSize)
        }
    }

    /// The Vision pass on an upright image, in upright pixels (top-left
    /// origin); RedEyeDetector's input. `seeds`, also in upright pixels,
    /// make it a refit of those boxes instead of a detection; only faces
    /// with landmarks (fitting at `minimumRefitConfidence` or better for
    /// a seed) are returned, sorted left to right.
    static func upright(in image: CGImage, seeds: [CGRect]?) -> [UprightFace] {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        request.constellation = .constellation76Points
        let size = CGSize(width: image.width, height: image.height)
        if let seeds {
            request.inputFaceObservations = seeds.map { VNFaceObservation(boundingBox: visionRect($0, in: size)) }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        var faces: [UprightFace] = []
        for observation in request.results ?? [] {
            guard let landmarks = observation.landmarks else { continue }
            if seeds != nil, landmarks.confidence < minimumRefitConfidence { continue }
            // Vision's points are in pixels with the origin at the bottom left.
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) }
            }
            faces.append(UprightFace(
                boundingBox: uprightRect(observation.boundingBox, in: size),
                roll: Float(truncating: observation.roll ?? 0),
                yaw: Float(truncating: observation.yaw ?? 0),
                confidence: observation.confidence,
                faceContour: points(landmarks.faceContour),
                leftEye: points(landmarks.leftEye), rightEye: points(landmarks.rightEye),
                leftPupil: points(landmarks.leftPupil), rightPupil: points(landmarks.rightPupil),
                leftEyebrow: points(landmarks.leftEyebrow), rightEyebrow: points(landmarks.rightEyebrow),
                nose: points(landmarks.nose),
                outerLips: points(landmarks.outerLips), innerLips: points(landmarks.innerLips)))
        }
        return faces.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
    }

    // MARK: - Frames

    /// A Vision rectangle (normalised, bottom-left origin) as upright
    /// pixels, top-left origin.
    static func uprightRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height,
               width: r.width * size.width, height: r.height * size.height)
    }

    /// The inverse: upright pixels, top-left origin, as Vision's frame.
    static func visionRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX / size.width, y: 1 - r.maxY / size.height,
               width: r.width / size.width, height: r.height / size.height)
    }

    /// A seed for the refit: a sensor-normalised box, enlarged by `margin`
    /// about its centre (a fifth gives Vision the hair and chin a stored
    /// box may cut) and turned into upright pixels, kept inside the image.
    static func uprightSeed(_ seed: CGRect, margin: CGFloat, rotation: ImageRotation,
                            sensorSize: CGSize, uprightSize: CGSize) -> CGRect {
        let sensorRect = CGRect(x: seed.minX * sensorSize.width, y: seed.minY * sensorSize.height,
                                width: seed.width * sensorSize.width, height: seed.height * sensorSize.height)
        let upright = rotation.imageRect(fromSensorRect: sensorRect, sensorSize: sensorSize)
        let grown = upright.insetBy(dx: -upright.width * margin / 2, dy: -upright.height * margin / 2)
        return grown.intersection(CGRect(origin: .zero, size: uprightSize))
    }

    /// An upright face turned back to normalised sensor coordinates.
    static func sensorObservation(_ face: UprightFace, rotation: ImageRotation, sensorSize s: CGSize) -> FaceObservation {
        func point(_ p: CGPoint) -> SIMD2<Float> {
            let sensor = rotation.sensorPoint(fromImagePoint: p, sensorSize: s)
            return SIMD2(Float(sensor.x / s.width), Float(sensor.y / s.height))
        }
        let box = rotation.sensorRect(fromImageRect: face.boundingBox, sensorSize: s)
        return FaceObservation(
            boundingBox: CGRect(x: box.minX / s.width, y: box.minY / s.height,
                                width: box.width / s.width, height: box.height / s.height),
            roll: face.roll, yaw: face.yaw, confidence: face.confidence,
            faceContour: face.faceContour.map(point),
            leftEye: face.leftEye.map(point), rightEye: face.rightEye.map(point),
            leftPupil: face.leftPupil.map(point), rightPupil: face.rightPupil.map(point),
            leftEyebrow: face.leftEyebrow.map(point), rightEyebrow: face.rightEyebrow.map(point),
            nose: face.nose.map(point),
            outerLips: face.outerLips.map(point), innerLips: face.innerLips.map(point))
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - shared.width * shared.height
        return union > 0 ? shared.width * shared.height / union : 0
    }
}
