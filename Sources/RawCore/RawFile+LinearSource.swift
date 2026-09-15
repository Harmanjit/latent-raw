import Foundation

extension RawFile {
    /// A linear source made in memory rather than read from a file, with the
    /// camera, lens and exposure metadata of `reference` (another photo's
    /// summary) and pixels written by `fill`.
    ///
    /// Photo Merge renders its preview this way: the merged pixels, as the
    /// DNG will store them, go through the same `ImageSession` and render
    /// pipeline as the DNG will when it is opened, so the preview shows what
    /// Latent will show.
    ///
    /// - Parameters:
    ///   - fill: writes `width x height` pixels of four `Float16` each (red,
    ///     green, blue, alpha 1), following the `LinearPlane` contract:
    ///     camera RGB at unit white balance, white at 1.0, finite and not
    ///     negative. The plane isn't cleaned after `fill`, so the caller
    ///     keeps to the contract.
    ///   - baselineExposure: stops, as a DNG's BaselineExposure.
    ///   - mergeInfo: the merge's clip level and lens state, as its XMP would say.
    /// - Returns: nil when the plane's memory can't be allocated.
    public static func linearSource(width: Int, height: Int, like reference: RawSummary, cameraToXYZ: [Float]?,
                                    baselineExposure: Float, mergeInfo: LinearMergeInfo?,
                                    fill: (UnsafeMutableBufferPointer<Float16>) -> Void) -> RawFile? {
        guard let plane = LinearPlane(width: width, height: height, fill: fill) else { return nil }
        let summary = RawSummary(
            activeArea: SensorActiveArea(left: 0, top: 0, width: width, height: height,
                                         fullWidth: width, fullHeight: height),
            cfaPattern: .linearRGB,
            cameraMultipliers: reference.cameraMultipliers,
            blackLevel: 0, whiteLevel: 1, channelBlackLevels: .zero, dataMaximum: 0,
            baselineExposure: baselineExposure, mergeInfo: mergeInfo,
            cameraMake: reference.cameraMake, cameraModel: reference.cameraModel,
            lensModel: reference.lensModel, iso: reference.iso, shutter: reference.shutter,
            aperture: reference.aperture, focalLength: reference.focalLength,
            captureTime: reference.captureTime, orientation: reference.orientation, lens: reference.lens)
        return RawFile(summary: summary, cameraToXYZ: cameraToXYZ, linearPlane: plane)
    }
}
