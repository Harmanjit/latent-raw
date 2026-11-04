import Foundation

/// Match Total Exposures (Photo › Match Total Exposures, as in Lightroom):
/// gives every selected photo the same overall brightness as the lead one,
/// counting both how the camera exposed it and the Exposure slider.
///
/// The camera's part is the light the sensor gathered, in stops, from the
/// shutter time, aperture and ISO: log2(time) + log2(ISO / 100) −
/// 2 log2(f-number). A photo's total is that plus its Exposure slider, and
/// each photo's slider is set so its total equals the lead's. A bracket
/// shot at −2, 0 and +2 EV comes out at one brightness; a photo shot a stop
/// darker gets a stop more Exposure.
///
/// Photos without the three values (most JPEGs from apps, scans) can't be
/// matched and are left alone.
public enum ExposureMatching {
    /// The sensor's exposure in stops, nil when a value is missing or not
    /// positive.
    public static func cameraExposure(shutter: Double?, aperture: Double?, iso: Double?) -> Double? {
        guard let shutter, let aperture, let iso,
              shutter > 0, aperture > 0, iso > 0,
              shutter.isFinite, aperture.isFinite, iso.isFinite else { return nil }
        return log2(shutter) + log2(iso / 100) - 2 * log2(aperture)
    }

    /// The Exposure slider that gives a photo exposed at `camera` the
    /// total `target`, within the slider's −5…+5 and to a hundredth.
    public static func matchedExposure(target: Double, camera: Double) -> Float {
        let ev = Float(target - camera)
        guard ev.isFinite else { return 0 }
        return (min(max(ev, -5), 5) * 100).rounded() / 100
    }

    /// The Exposure slider in a stored edit (0 with none).
    public static func exposure(inEditJSON json: String?) throws -> Float {
        guard let json else { return 0 }
        return try EditStack.decode(json: json).parameters().exposureEV
    }

    /// The stored edit with only its Exposure changed; every other module
    /// is kept as it was. nil (no edit) becomes an edit holding just the
    /// exposure.
    public static func settingExposure(_ ev: Float, inEditJSON json: String?) throws -> String {
        var stack = try json.map { try EditStack.decode(json: $0) } ?? EditStack()
        stack.modules.exposure = EditStack.Exposure(ev: ev)
        return try stack.encodeJSON()
    }
}
