import Foundation
import CoreGraphics
import PixelEngine

/// Finds red eyes for the red-eye tool's Auto button, on device.
///
/// Vision's face landmarks give each eye's outline and pupil; the circle
/// proposed is centred on the pupil and sized from the eye's width, and
/// only when the pupil area really is red by the measure the correction
/// uses (`RedEyeTuning`), so a brown or dark eye in a group photo is never
/// darkened just because it is an eye. Ported from minivu.
///
/// Works on a small render of the edit (about 1600 px): faces large enough
/// to show red eyes are found there, in tens of milliseconds.
public enum RedEyeDetector {
    /// The proposed circle's radius, as a fraction of the eye's width. An
    /// iris is about half an eye across, so this circle holds the whole
    /// pupil with a margin; the correction only touches red pixels inside.
    static let radiusPerEyeWidth = 0.28
    /// A pupil counts as red when this share of the pixels in the middle
    /// of its circle is red.
    static let redShare = 0.08

    /// A proposed circle, in pixels of the upright image, top-left origin.
    struct Candidate: Equatable {
        var centre: CGPoint
        var radius: Double
    }

    /// Spots for the red eyes in `sensorImage`, an sRGB render of the whole
    /// sensor unrotated (so its pixels are sensor positions), shown to the
    /// user turned by `rotation`. Faces are looked for upright, then the
    /// spots come back in normalized sensor coordinates. Synchronous and a
    /// few tens of milliseconds: call it off the main thread.
    public static func detect(in sensorImage: CGImage, rotation: ImageRotation) -> [RedEyeSpot] {
        guard let upright = rotated(sensorImage, by: rotation) else { return [] }
        let sensorImageSize = CGSize(width: sensorImage.width, height: sensorImage.height)
        return redCandidates(eyeCandidates(in: upright), in: upright).map {
            spot(for: $0, rotation: rotation, sensorImageSize: sensorImageSize)
        }
    }

    /// Every eye Vision finds, red or not, from the shared landmark pass.
    static func eyeCandidates(in image: CGImage) -> [Candidate] {
        var candidates: [Candidate] = []
        for face in FaceLandmarker.upright(in: image, seeds: nil) {
            for (outline, pupil) in [(face.leftEye, face.leftPupil), (face.rightEye, face.rightPupil)] {
                guard outline.count >= 2,
                      let minX = outline.map(\.x).min(), let maxX = outline.map(\.x).max(),
                      let minY = outline.map(\.y).min(), let maxY = outline.map(\.y).max() else { continue }
                let eyeWidth = Double(maxX - minX)
                guard eyeWidth > 2 else { continue }
                let centre = pupil.first ?? CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
                candidates.append(Candidate(centre: centre, radius: eyeWidth * radiusPerEyeWidth))
            }
        }
        return candidates
    }

    /// The candidates whose pupil area is red.
    static func redCandidates(_ candidates: [Candidate], in image: CGImage) -> [Candidate] {
        candidates.filter { redFraction(in: image, centre: $0.centre, radius: $0.radius * 0.6) >= redShare }
    }

    /// A candidate in the upright image as a spot in normalized sensor
    /// coordinates, its radius a fraction of the short side (the same
    /// whichever way up).
    static func spot(for candidate: Candidate, rotation: ImageRotation, sensorImageSize s: CGSize) -> RedEyeSpot {
        let sensor = rotation.sensorPoint(fromImagePoint: candidate.centre, sensorSize: s)
        return RedEyeSpot(centre: SIMD2(Float(sensor.x / s.width), Float(sensor.y / s.height)),
                          radius: Float(candidate.radius / Double(min(s.width, s.height))))
    }

    /// `image` turned as `rotation` turns the sensor into what the user
    /// sees, so faces are upright for Vision: `UprightImage.rotated`,
    /// under the name RedEyeDetectorTests know it by.
    static func rotated(_ image: CGImage, by rotation: ImageRotation) -> CGImage? {
        UprightImage.rotated(image, by: rotation)
    }

    /// The share of pixels within `radius` of `centre` (pixels, top-left
    /// origin) that are red by the correction's measure, in linear light.
    static func redFraction(in image: CGImage, centre: CGPoint, radius: Double) -> Double {
        let r = max(radius, 1)
        let box = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !box.isNull, box.width >= 1, box.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return 0 }
        let width = Int(box.width), height = Int(box.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                          bytesPerRow: width * 16, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.floatComponents.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            // Place the image so the box's top-left pixel lands at the context's top-left.
            context.draw(image, in: CGRect(x: -box.minX, y: box.maxY - CGFloat(image.height),
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return 0 }
        var red = 0, total = 0
        for y in 0..<height {
            for x in 0..<width {
                let dx = box.minX + Double(x) + 0.5 - centre.x, dy = box.minY + Double(y) + 0.5 - centre.y
                guard dx * dx + dy * dy <= r * r else { continue }
                total += 1
                let i = (y * width + x) * 4
                let alpha = max(pixels[i + 3], 1e-6)
                let c = SIMD3(pixels[i], pixels[i + 1], pixels[i + 2]) / alpha
                if RedEyeTuning.isPupilRed(c), c.x > 0.02 { red += 1 }
            }
        }
        return total > 0 ? Double(red) / Double(total) : 0
    }
}
