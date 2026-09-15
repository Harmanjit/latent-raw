import Foundation

extension RawFile {
    /// A Bayer raw made in memory rather than read from a file: the metadata
    /// of `reference` (another raw's summary) at a new size, with photosites
    /// copied from `samples`.
    ///
    /// Photo Merge's HDR preview uses it: each frame of a bracket is reduced
    /// once to a small mosaic of the same Bayer order and levels, and every
    /// change of an option in the dialog merges those, through the same
    /// steps as the full-size merge, instead of reading the raw files again.
    ///
    /// - Parameters:
    ///   - samples: `width x height` photosites, row by row, in the units of
    ///     `reference` (its black and white levels still apply), with the
    ///     same Bayer order at (0, 0).
    ///   - dataMaximum: the largest value in `samples` worth reporting; the
    ///     caller knows it, and scanning for it here would cost a pass.
    /// - Returns: nil when `reference` isn't a Bayer raw, the sizes don't
    ///   agree, or the plane's memory can't be allocated.
    public static func bayerSource(width: Int, height: Int, like reference: RawSummary, cameraToXYZ: [Float]?,
                                   dataMaximum: Float, samples: UnsafeBufferPointer<UInt16>) -> RawFile? {
        guard case .bayer = reference.cfaPattern, width > 0, height > 0, samples.count == width * height,
              let plane = SensorPlane(copying: samples) else { return nil }
        let summary = RawSummary(
            activeArea: SensorActiveArea(left: 0, top: 0, width: width, height: height,
                                         fullWidth: width, fullHeight: height),
            cfaPattern: reference.cfaPattern,
            cameraMultipliers: reference.cameraMultipliers,
            blackLevel: reference.blackLevel, whiteLevel: reference.whiteLevel,
            channelBlackLevels: reference.channelBlackLevels, dataMaximum: dataMaximum,
            baselineExposure: reference.baselineExposure, mergeInfo: nil,
            cameraMake: reference.cameraMake, cameraModel: reference.cameraModel,
            lensModel: reference.lensModel, iso: reference.iso, shutter: reference.shutter,
            aperture: reference.aperture, focalLength: reference.focalLength,
            captureTime: reference.captureTime, orientation: reference.orientation, lens: reference.lens)
        return RawFile(summary: summary, cameraToXYZ: cameraToXYZ, sensorPlane: plane)
    }
}
