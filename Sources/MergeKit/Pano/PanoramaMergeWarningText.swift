import Foundation

// The words the panorama dialog and the command line both say, so a warning
// reads the same wherever it appears (docs/PhotoMerge.md section 4, "Output
// size: downsample instead of failing"). The engine never refuses a
// panorama for its size: it says this, and merges once the user agrees.

public extension PanoramaOutputSize {
    /// The downsampling sentence, in the dialog's words: what the panorama
    /// would have been, which limit applies, and what it will be. Empty
    /// when nothing is being reduced.
    ///
    ///     This panorama would be 29,195 × 7,664 px (224 MP). The largest
    ///     this Mac can edit is 16,384 px on a side, so the photos will be
    ///     reduced to 43% (12,482 × 3,276 px, 41 MP).
    var downsampleMessage: String {
        guard needsDownsampling else { return "" }
        let reason: String
        switch limit {
        case .textureSide:
            reason = "The largest this Mac can edit is \(PanoramaSizeText.count(max(width, height))) px on a side,"
        case .memory:
            reason = "The most this Mac can edit is \(PanoramaSizeText.megapixels(width: width, height: height)),"
        case .none:
            reason = "This Mac can't edit it at full size,"
        }
        return "This panorama would be \(PanoramaSizeText.size(width: fullWidth, height: fullHeight)) "
            + "(\(PanoramaSizeText.megapixels(width: fullWidth, height: fullHeight))). \(reason) so the photos "
            + "will be reduced to \(PanoramaSizeText.percent(scale)) "
            + "(\(PanoramaSizeText.size(width: width, height: height)), "
            + "\(PanoramaSizeText.megapixels(width: width, height: height)))."
    }

    /// "12,482 × 3,276 px (41 MP)".
    var sizeMessage: String {
        "\(PanoramaSizeText.size(width: width, height: height)) "
            + "(\(PanoramaSizeText.megapixels(width: width, height: height)))"
    }
}

public extension PanoramaMergeWarning {
    /// The warning in the dialog's words. `frames` is the analysis's, for
    /// the names of photos left out.
    func message(frames: [PanoramaMergeFrame] = []) -> String {
        switch self {
        case .framesLeftOut(let indices):
            let names = indices.map { index in
                frames.indices.contains(index) ? frames[index].url.lastPathComponent : "photo \(index + 1)"
            }
            let list = PanoramaSizeText.list(names)
            return indices.count == 1
                ? "\(list) doesn't overlap the others enough to be joined, so it is left out."
                : "\(list) don't overlap the others enough to be joined, so they are left out."
        case .downsampled(let size):
            return size.downsampleMessage
        case .unevenExposure(let stops):
            return String(format: "The photos still differ in brightness by %.1f stops after evening them out, "
                          + "so seams may show.", stops)
        case .largeParallax(let pixels):
            return String(format: "The camera moved as well as turned (the photos line up only to about %.0f px), "
                          + "so things close to the camera may look doubled.", pixels)
        }
    }
}

/// Numbers as the dialog writes them.
enum PanoramaSizeText {
    /// Latent's interface is English, and the dialog's words are tested
    /// against the plan's wording, so the grouping is fixed rather than the
    /// running Mac's.
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func count(_ value: Int) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func size(width: Int, height: Int) -> String { "\(count(width)) × \(count(height)) px" }

    static func megapixels(width: Int, height: Int) -> String {
        let mp = Double(width) * Double(height) / 1e6
        return mp >= 10 ? String(format: "%.0f MP", mp) : String(format: "%.1f MP", mp)
    }

    static func percent(_ scale: Double) -> String { String(format: "%.0f%%", scale * 100) }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
