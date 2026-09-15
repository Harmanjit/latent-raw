import Foundation
import simd

// What the panorama geometry works from: each photo's metadata and a small
// lens-corrected copy of it. `PanoramaFramePrep` makes these from raw
// files; the tests make them from a synthetic scene.

/// What the geometry needs to know about one photo.
public struct PanoramaFrameMetadata: Sendable, Equatable {
    /// For reports: the file name.
    public var name: String
    public var captureTime: Date
    /// The upright photo's full-resolution size, in pixels.
    public var width: Int
    public var height: Int
    /// EXIF focal length.
    public var focalLengthMillimetres: Double
    /// The sensor's crop factor against 35 mm film (1 for full frame, 1.5
    /// for most APS-C); 0 when unknown.
    public var cropFactor: Double
    /// Shutter time in seconds, ISO and f-number, for the exposure.
    public var exposureTime: Double
    public var iso: Double
    public var aperture: Double

    public init(name: String, captureTime: Date, width: Int, height: Int, focalLengthMillimetres: Double,
                cropFactor: Double, exposureTime: Double, iso: Double, aperture: Double) {
        self.name = name; self.captureTime = captureTime; self.width = width; self.height = height
        self.focalLengthMillimetres = focalLengthMillimetres; self.cropFactor = cropFactor
        self.exposureTime = exposureTime; self.iso = iso; self.aperture = aperture
    }

    /// The diagonal of a 35 mm film frame (36 x 24 mm), which crop factors
    /// are measured against.
    public static let fullFrameDiagonalMillimetres = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()

    /// How much light the photo gathered, up to a constant: shutter time x
    /// ISO / f-number². Nil when EXIF lacks any of them.
    public var exposure: Double? {
        guard exposureTime > 0, iso > 0, aperture > 0 else { return nil }
        return exposureTime * iso / (aperture * aperture)
    }

    /// The focal length in full-resolution pixels, from EXIF.
    ///
    /// The sensor's diagonal in millimetres is the film diagonal over the
    /// crop factor; the photo's diagonal in pixels is known; their ratio is
    /// the pixel pitch, and the focal length divided by the pitch is the
    /// focal length in pixels. A 50 mm lens on a 24 MP full-frame sensor
    /// (6016 x 4016 px) gives 50 x 7233 / 43.27 = 8358 px. With no crop
    /// factor, full frame is assumed (the camera solve refines it anyway).
    /// Nil without a focal length.
    public var focalLengthPixels: Double? {
        guard focalLengthMillimetres > 0, width > 0, height > 0 else { return nil }
        let crop = cropFactor > 0 ? cropFactor : 1
        let diagonalPixels = (Double(width * width) + Double(height * height)).squareRoot()
        return focalLengthMillimetres * diagonalPixels / (Self.fullFrameDiagonalMillimetres / crop)
    }
}

/// A photo reduced for measuring: camera RGB at unit white balance, lens
/// corrected and upright (as the stitcher will use it), with coverage and
/// where it was clipped. Texel (i, j) covers the photo's full-resolution
/// pixels `[i·span, (i+1)·span) x [j·span, (j+1)·span)`.
public struct PanoramaThumbnail: Sendable {
    public let width: Int
    public let height: Int
    /// Full-resolution pixels per texel.
    public let span: Int
    /// Red, green, blue and coverage (alpha), four Float32 per texel.
    public let rgba: [Float]
    /// The share (0...1) of each texel that was clipped; 1 outside the photo.
    public let clippedShare: [Float]

    public init(width: Int, height: Int, span: Int, rgba: [Float], clippedShare: [Float]) {
        precondition(width > 0 && height > 0 && span > 0, "a thumbnail has a size")
        precondition(rgba.count == width * height * 4 && clippedShare.count == width * height,
                     "rgba and clippedShare must match the size")
        self.width = width; self.height = height; self.span = span
        self.rgba = rgba; self.clippedShare = clippedShare
    }

    /// (R + 2G + B) / 4 of every texel, the luminance alignment uses.
    public var luminance: [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for i in out.indices {
            out[i] = 0.25 * rgba[4 * i] + 0.5 * rgba[4 * i + 1] + 0.25 * rgba[4 * i + 2]
        }
        return out
    }

    /// Whether texel i is covered and unclipped: usable for measuring.
    @inline(__always)
    func isUsable(_ i: Int) -> Bool {
        rgba[4 * i + 3] >= 0.999 && clippedShare[i] <= 0.02
    }
}

/// One photo of a panorama, as the geometry solver takes it.
public struct PanoramaFrameInput: Sendable {
    public var metadata: PanoramaFrameMetadata
    public var thumbnail: PanoramaThumbnail

    public init(metadata: PanoramaFrameMetadata, thumbnail: PanoramaThumbnail) {
        self.metadata = metadata
        self.thumbnail = thumbnail
    }
}
