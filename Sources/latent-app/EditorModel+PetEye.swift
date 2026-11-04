import CoreGraphics
import Foundation
import simd
import PixelEngine

// Pet Eye (docs/wiki/Develop.md, "Red-Eye and Pet Eye"): the red-eye tool
// in its second mode. The spot is the same circle on the raw grid; its
// kind tells the kernel to replace everything inside with a dark pupil,
// and a catchlight direction, fixed when it is made, points up and to the
// left on screen whatever the camera's orientation.
extension EditorModel {
    /// The spot a click with the tool armed makes, of the chosen kind.
    func newRedEyeSpot(centre p: SIMD2<Float>) -> RedEyeSpot {
        guard redEyeKind == .pet else { return RedEyeSpot(centre: p, radius: redEyeRadius) }
        return RedEyeSpot(centre: p, radius: redEyeRadius, kind: .pet,
                          catchlight: petEyeCatchlight ? catchlightDirection() : nil)
    }

    /// Red Eye or Pet Eye: the selected spot's kind, else the next one's.
    /// Setting it changes both.
    var activeRedEyeKind: RedEyeSpot.Kind {
        get { selectedRedEye.map { $0.kind ?? .human } ?? redEyeKind }
        set {
            redEyeKind = newValue
            guard let i = selectedRedEyeIndex, i < parameters.redEyes.count else { return }
            var spot = parameters.redEyes[i]
            spot.kind = newValue == .pet ? .pet : nil
            spot.catchlight = newValue == .pet && petEyeCatchlight ? catchlightDirection() : nil
            parameters.redEyes[i] = spot
        }
    }

    /// Add Catchlight: the selected Pet Eye spot's, else the next one's.
    var activePetEyeCatchlight: Bool {
        get {
            if let spot = selectedRedEye, spot.isPet { return spot.catchlight != nil }
            return petEyeCatchlight
        }
        set {
            petEyeCatchlight = newValue
            guard let i = selectedRedEyeIndex, i < parameters.redEyes.count, parameters.redEyes[i].isPet else { return }
            parameters.redEyes[i].catchlight = newValue ? catchlightDirection() : nil
        }
    }

    /// Up and to the left on screen, as a unit direction in sensor pixels:
    /// two points a little apart on screen taken back to the sensor, so
    /// rotation, flips and the crop's straighten are all accounted for.
    func catchlightDirection() -> SIMD2<Float> {
        let fallback = SIMD2<Float>(-1, -1) / Float(2).squareRoot()
        guard drawableSize.width > 0, drawableSize.height > 0, sensorSize.width > 0, sensorSize.height > 0 else {
            return fallback
        }
        let centre = CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2)
        let a = sensorNormalized(centre)
        let b = sensorNormalized(CGPoint(x: centre.x - 20, y: centre.y - 20))
        let v = (b - a) * SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let length = simd_length(v)
        guard length.isFinite, length > 1e-6 else { return fallback }
        return v / length
    }
}
