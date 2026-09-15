import Foundation

/// The export sheet's size estimate for a batch, from one image actually
/// rendered and encoded.
///
/// Rendering every image to find its size would take as long as the export
/// itself, so the first image is rendered and encoded at the export's real
/// settings, and its bytes per pixel are taken to hold for the rest, whose
/// pixel counts come from their catalog dimensions fitted to the export's
/// long edge. Detail, noise and crops vary from photo to photo, so this is
/// an estimate and the sheet says so; for one image it is exact, give or
/// take the metadata of a file read at export time.
public enum ExportSizeEstimate {
    /// Pixels in an export of a `width` x `height` image, fitted within
    /// `maxLongEdge` (never enlarged); nil when the size isn't known.
    public static func outputPixels(width: Int?, height: Int?, maxLongEdge: Int?) -> Int? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        guard let target = maxLongEdge, target > 0, max(width, height) > target else { return width * height }
        let scale = Double(target) / Double(max(width, height))
        return max(1, Int((Double(width) * scale).rounded())) * max(1, Int((Double(height) * scale).rounded()))
    }

    /// Estimated bytes for a batch whose first image encodes to
    /// `sampleBytes` at `samplePixels` (its real, cropped output size).
    /// `others` are the remaining images' catalog dimensions; one whose size
    /// isn't known counts as the sample's.
    public static func totalBytes(sampleBytes: Int, samplePixels: Int,
                                  others: [(width: Int?, height: Int?)], maxLongEdge: Int?) -> Int {
        guard samplePixels > 0 else { return sampleBytes }
        let bytesPerPixel = Double(sampleBytes) / Double(samplePixels)
        let rest = others.reduce(0.0) { sum, size in
            let pixels = outputPixels(width: size.width, height: size.height, maxLongEdge: maxLongEdge) ?? samplePixels
            return sum + Double(pixels) * bytesPerPixel
        }
        return sampleBytes + Int(rest.rounded())
    }

    /// `totalBytes` for catalog records, the first being the sample.
    public static func totalBytes(sampleBytes: Int, samplePixels: Int, records: [ImageRecord],
                                  maxLongEdge: Int?) -> Int {
        totalBytes(sampleBytes: sampleBytes, samplePixels: samplePixels,
                   others: records.dropFirst().map { ($0.width, $0.height) }, maxLongEdge: maxLongEdge)
    }
}
