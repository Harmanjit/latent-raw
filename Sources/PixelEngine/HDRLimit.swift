import Foundation

/// HDR Limit: the ceiling, in stops above SDR white, of a photo's HDR
/// rendition. It is part of the edit, like Lightroom's, because it is a
/// decision about this photo: a sunset may earn three stops of sparkle
/// where a portrait wants barely one. It changes nothing in an SDR file or
/// on an SDR screen; it caps the EDR viewport and sets the headroom of a
/// gain-map export, so what the file shows on an HDR screen matches what
/// the editor showed.
public enum HDRLimit {
    /// Two stops (4×), what Latent used before the limit could be set: the
    /// same as `DisplayHeadroom.renderCeiling` and `GainMap.exportHeadroom`.
    public static let defaultStops: Float = 2
    /// Half a stop is the least that still reads as HDR; past three stops
    /// (8×) a highlight reads as a searchlight on any screen that can show it.
    public static let range: ClosedRange<Float> = 0.5...3

    public static func clamped(_ stops: Float) -> Float {
        guard stops.isFinite else { return defaultStops }
        return min(max(stops, range.lowerBound), range.upperBound)
    }

    /// The linear headroom (a multiple of SDR white) for a limit in stops.
    public static func headroom(stops: Float) -> Float { exp2(clamped(stops)) }
}

extension EditParameters {
    /// The HDR rendition's ceiling as a multiple of SDR white.
    public var hdrHeadroom: Float { HDRLimit.headroom(stops: hdrLimitStops) }
}
