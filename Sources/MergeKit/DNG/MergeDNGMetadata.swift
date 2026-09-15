// What a merge's DNG says about the camera, its colour and the exposure,
// taken from the reference frame.

import Foundation
import RawCore

/// The camera, colour and EXIF metadata of a merge's DNG. Every field maps
/// to one DNG, TIFF or EXIF tag; the reference frame supplies them all.
///
/// **Colour** needs two tags, because the pixels are the camera's own RGB,
/// not a standard colour space:
/// - `colorMatrix1` maps CIE XYZ to camera RGB, so a raw converter can go
///   the other way. It is LibRaw's `cam_xyz` (Adobe's ColorMatrix values).
/// - `asShotNeutral` is the camera RGB of something grey under the shot's
///   light: the white balance, as the inverse of the camera's multipliers.
public struct MergeDNGMetadata: Sendable, Equatable {
    public var make: String
    public var model: String
    /// DNG's name for the camera model a colour profile is looked up by,
    /// conventionally "Make Model".
    public var uniqueCameraModel: String
    /// XYZ -> camera RGB, 3x3 row by row (DNG ColorMatrix1, for D65).
    public var colorMatrix1: [Double]
    /// Camera RGB of a neutral surface, green = 1 (DNG AsShotNeutral).
    public var asShotNeutral: [Double]
    /// Stops to brighten by default, *before* normalisation; the writer
    /// adds its shift (`ExposureNormalisation`).
    public var baselineExposure: Double
    /// TIFF orientation, 1 (upright) to 8. Applies to the stored pixels and
    /// both previews, which are all stored unrotated.
    public var orientation: UInt16
    /// "Latent 1.2". LibRaw refuses files whose Software starts with
    /// "Adobe", "dcraw" and a few others (it takes them for converted files
    /// it can't trust), so the writer checks.
    public var software: String
    /// When the merge was made (TIFF DateTime).
    public var modificationDate: Date
    /// When the reference frame was taken (EXIF DateTimeOriginal).
    public var captureDate: Date?
    /// The zone EXIF's zone-less date strings are written in. The default,
    /// the Mac's own, reproduces the camera's text for a capture time LibRaw
    /// read on this Mac, as the exporter does.
    public var timeZone: TimeZone
    /// Seconds.
    public var exposureTime: Double?
    public var fNumber: Double?
    public var iso: Double?
    /// Millimetres.
    public var focalLength: Double?
    public var lensMake: String?
    /// Leave nil when lens corrections are baked in (panoramas), so no
    /// reader corrects the lens a second time.
    public var lensModel: String?
    public var lensSpecification: LensSpecification?
    /// The part of the stored image to show (DNG DefaultCrop); nil is all of it.
    public var defaultCrop: PixelRegion?

    /// EXIF LensSpecification: the lens's focal range and widest aperture at each end.
    public struct LensSpecification: Sendable, Equatable {
        public var minFocalLength: Double
        public var maxFocalLength: Double
        public var maxApertureAtMinFocal: Double
        public var maxApertureAtMaxFocal: Double

        public init(minFocalLength: Double, maxFocalLength: Double,
                    maxApertureAtMinFocal: Double, maxApertureAtMaxFocal: Double) {
            self.minFocalLength = minFocalLength
            self.maxFocalLength = maxFocalLength
            self.maxApertureAtMinFocal = maxApertureAtMinFocal
            self.maxApertureAtMaxFocal = maxApertureAtMaxFocal
        }
    }

    public init(make: String, model: String, uniqueCameraModel: String? = nil,
                colorMatrix1: [Double], asShotNeutral: [Double], baselineExposure: Double = 0,
                orientation: UInt16 = 1, software: String, modificationDate: Date = Date(),
                captureDate: Date? = nil, timeZone: TimeZone = .current,
                exposureTime: Double? = nil, fNumber: Double? = nil, iso: Double? = nil,
                focalLength: Double? = nil, lensMake: String? = nil, lensModel: String? = nil,
                lensSpecification: LensSpecification? = nil, defaultCrop: PixelRegion? = nil) {
        self.make = make
        self.model = model
        self.uniqueCameraModel = uniqueCameraModel ?? Self.uniqueCameraModel(make: make, model: model)
        self.colorMatrix1 = colorMatrix1
        self.asShotNeutral = asShotNeutral
        self.baselineExposure = baselineExposure
        self.orientation = orientation
        self.software = software
        self.modificationDate = modificationDate
        self.captureDate = captureDate
        self.timeZone = timeZone
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.iso = iso
        self.focalLength = focalLength
        self.lensMake = lensMake
        self.lensModel = lensModel
        self.lensSpecification = lensSpecification
        self.defaultCrop = defaultCrop
    }

    /// The metadata of a merge whose reference frame is `summary`, with that
    /// file's `cameraToXYZ` matrix (`RawFile.cameraToXYZMatrixRaw`, which
    /// despite its name is XYZ -> camera). Throws when the file has no
    /// colour matrix or no as-shot white balance, without which the merge
    /// would open in the wrong colours.
    ///
    /// `softwareVersion` is the app's version ("1.2"). Zero or unknown
    /// exposure values are left out rather than written as 0.
    public init(summary: RawSummary, cameraToXYZ: [Float]?, softwareVersion: String,
                baselineExposure: Double = 0) throws {
        guard let cameraToXYZ else { throw MergeDNGError.invalidMetadata("the reference frame has no colour matrix") }
        let multipliers = [summary.cameraMultipliers.0, summary.cameraMultipliers.1, summary.cameraMultipliers.2]
        let lens = summary.lens
        let hasLensRange = lens.minFocal > 0 && lens.maxFocal >= lens.minFocal
            && lens.maxApertureAtMinFocal > 0 && lens.maxApertureAtMaxFocal > 0
        self.init(
            make: summary.cameraMake, model: summary.cameraModel,
            colorMatrix1: try Self.colorMatrix(fromCamXYZ: cameraToXYZ),
            asShotNeutral: try Self.asShotNeutral(fromCameraMultipliers: multipliers),
            baselineExposure: baselineExposure,
            orientation: Self.tiffOrientation(libRawFlip: summary.orientation),
            software: Self.software(version: softwareVersion),
            captureDate: summary.captureTime.timeIntervalSince1970 > 0 ? summary.captureTime : nil,
            exposureTime: summary.shutter > 0 ? summary.shutter : nil,
            fNumber: summary.aperture > 0 ? summary.aperture : nil,
            iso: summary.iso > 0 ? summary.iso : nil,
            focalLength: summary.focalLength > 0 ? summary.focalLength : nil,
            lensMake: lens.make.isEmpty ? nil : lens.make,
            lensModel: summary.lensModel.isEmpty ? nil : summary.lensModel,
            lensSpecification: hasLensRange
                ? LensSpecification(minFocalLength: lens.minFocal, maxFocalLength: lens.maxFocal,
                                    maxApertureAtMinFocal: lens.maxApertureAtMinFocal,
                                    maxApertureAtMaxFocal: lens.maxApertureAtMaxFocal)
                : nil)
    }

    // MARK: - Conversions

    /// "Make Model", without repeating a make the model already starts with
    /// ("Canon Canon EOS R5" -> "Canon EOS R5"). Never empty: DNG requires it.
    public static func uniqueCameraModel(make: String, model: String) -> String {
        let make = make.trimmingCharacters(in: .whitespaces), model = model.trimmingCharacters(in: .whitespaces)
        let name: String
        if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) {
            name = model
        } else {
            name = model.isEmpty ? make : "\(make) \(model)"
        }
        return name.isEmpty ? "Unknown camera" : name
    }

    /// The 3x3 ColorMatrix1 from LibRaw's `cam_xyz`, which has 3 or 4 rows
    /// of 3 (the 4th only matters for four-colour sensors and is dropped).
    public static func colorMatrix(fromCamXYZ camXYZ: [Float]) throws -> [Double] {
        guard camXYZ.count == 9 || camXYZ.count == 12 else {
            throw MergeDNGError.invalidMetadata("a colour matrix has 9 or 12 values, not \(camXYZ.count)")
        }
        let matrix = camXYZ.prefix(9).map(Double.init)
        guard matrix.allSatisfy(\.isFinite), matrix.contains(where: { $0 != 0 }) else {
            throw MergeDNGError.invalidMetadata("the colour matrix is empty or not finite")
        }
        return matrix
    }

    /// AsShotNeutral from the camera's white-balance multipliers.
    ///
    /// A multiplier says how much to amplify a channel so grey comes out
    /// grey; the neutral is what grey looked like *before* that, so each
    /// channel is the inverse, scaled so green is 1: neutral = m_green / m.
    public static func asShotNeutral(fromCameraMultipliers multipliers: [Float]) throws -> [Double] {
        guard multipliers.count >= 3, multipliers.prefix(3).allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw MergeDNGError.invalidMetadata("the reference frame has no as-shot white balance")
        }
        let green = Double(multipliers[1])
        return multipliers.prefix(3).map { green / Double($0) }
    }

    /// TIFF orientation (1...8) from LibRaw's `flip`. LibRaw reads the tag
    /// through the table "50132467" (TIFF value -> flip); this is its inverse.
    public static func tiffOrientation(libRawFlip flip: Int) -> UInt16 {
        switch flip {
        case 1: return 2
        case 2: return 4
        case 3: return 3
        case 4: return 5
        case 5: return 8
        case 6: return 6
        case 7: return 7
        default: return 1
        }
    }

    /// "Latent <version>".
    public static func software(version: String) -> String {
        let version = version.trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? "Latent" : "Latent \(version)"
    }

    /// Software values LibRaw treats as "not a camera raw" and refuses to decode.
    static let softwarePrefixesLibRawRejects = ["Adobe", "dcraw", "UFRaw", "Bibble", "Digital Photo Professional"]
}
